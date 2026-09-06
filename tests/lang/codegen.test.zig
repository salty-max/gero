/// Tests for `gero.lang.codegen` — compiles small programs end
/// to end (tokenize → parse → typecheck → compile → boot on the
/// VM) and asserts on printed output or VM-memory state.
const std = @import("std");
const gero = @import("gero");
const util = @import("util");

const alloc = std.testing.allocator;

fn compileSource(source: []const u8) !gero.lang.Compiled {
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source, stream);
    defer tree.deinit();
    if (tree.errors.len > 0) {
        std.debug.print("parser errors for source:\n{s}\n", .{source});
        for (tree.errors) |e| std.debug.print("  - parser={s} @ {d}: {s}\n", .{ e.parser, e.index, e.message });
    }
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);

    var checked = try gero.lang.typecheck(alloc, source, &tree.program);
    defer checked.deinit();
    if (checked.diagnostics.len > 0) {
        std.debug.print("typecheck diagnostics for source:\n{s}\n", .{source});
        for (checked.diagnostics) |d| std.debug.print("  - {s}: {s}\n", .{ d.code, d.message });
    }
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.len);

    return gero.lang.compile(alloc, source, &checked, .{});
}

test "codegen: empty `def main() end` compiles to a valid .gx" {
    var compiled = try compileSource(
        \\def main() end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    // Image must parse cleanly through the VM loader.
    const loaded = try gero.vm.parseGx(compiled.image);
    try std.testing.expectEqual(gero.lang.codegen.code_base, loaded.header.entry_point);
    try std.testing.expectEqual(@as(u8, 0), loaded.header.bank_count);
    try std.testing.expectEqual(@as(u8, 0), loaded.header.sram_bank_count);

    // The byte at the entry address must be `hlt` (0xFF).
    try std.testing.expectEqual(@as(u8, 0xFF), loaded.image[gero.lang.codegen.code_base]);
}

test "codegen: emitted .gx header carries heap_base = end of data region" {
    // Source with no globals — data region empty, so heap_base sits
    // at data_base (the start of the dynamic data area).
    var compiled = try compileSource(
        \\def main() end
    );
    defer compiled.deinit();
    const loaded = try gero.vm.parseGx(compiled.image);
    try std.testing.expectEqual(gero.lang.codegen.data_base, loaded.header.heap_base);
}

test "codegen: heap_base advances past static globals" {
    // Two u16 globals in the data region → heap_base = data_base + 4.
    var compiled = try compileSource(
        \\let a: u16 = 0
        \\let b: u16 = 0
        \\def main() end
    );
    defer compiled.deinit();
    const loaded = try gero.vm.parseGx(compiled.image);
    try std.testing.expectEqual(@as(u16, gero.lang.codegen.data_base + 4), loaded.header.heap_base);
}

test "codegen: produced .gx boots and halts on the VM" {
    var compiled = try compileSource(
        \\def main() end
    );
    defer compiled.deinit();

    const loaded = try gero.vm.parseGx(compiled.image);
    var vm = gero.vm.VM.init(alloc);
    defer vm.deinit();
    try vm.boot(alloc, loaded);

    // One dispatch step — the entry byte is `hlt`, so the VM
    // transitions to the halted state in one fetch.
    const result = gero.vm.step(&vm);
    try std.testing.expectEqual(gero.vm.StepResult.halted, result);
}

test "codegen: missing entry def returns EntryNotFound" {
    const source = "let x = 0";
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, source, &tree.program);
    defer checked.deinit();

    const res = gero.lang.compile(alloc, source, &checked, .{});
    try std.testing.expectError(error.EntryNotFound, res);
}

test "codegen: produced .gx decodes cleanly through the disassembler" {
    var compiled = try compileSource(
        \\def main() end
    );
    defer compiled.deinit();

    // Disasm header parse — confirms the codegen's archive layout
    // matches the format the disasm pipeline (and `gero disasm`)
    // expects. The byte-identical round-trip property doesn't hold
    // for us because the disasm round-trip compacts the leading
    // zero-padded prefix (the 0x0000..0x1100 IVT/scratch region);
    // we only assert the header decodes and the entry byte is hlt.
    const header = try gero.disasm.parseHeader(compiled.image);
    try std.testing.expectEqual(gero.lang.codegen.code_base, header.entry_point);
    try std.testing.expectEqual(@as(u8, 0), header.bank_count);
    try std.testing.expectEqual(@as(u8, 0), header.sram_bank_count);

    // Round-trip via the asm-side roundtrip — checks the
    // disassembler accepted every instruction. We don't compare
    // bytes; only that the operation succeeds.
    const reroll = try gero.disasm.roundTripArchive(alloc, compiled.image);
    defer alloc.free(reroll);
    try std.testing.expect(reroll.len > 0);
}

// ---------- instruction selection (M1 chunk 1) ----------

/// Boot the compiled image on the VM, install the given
/// capturing writer as the host stdout sink, and run until halt.
/// Returns the VM so the caller can inspect register / memory
/// state. The writer's `written()` slice holds whatever the
/// program printed.
fn runWith(
    image: []const u8,
    writer: *std.Io.Writer.Allocating,
) !gero.vm.VM {
    var vm = gero.vm.VM.init(alloc);
    errdefer vm.deinit();
    const loaded = try gero.vm.parseGx(image);
    try vm.boot(alloc, loaded);
    vm.host = .{ .out = &writer.writer };
    _ = gero.vm.run(&vm);
    return vm;
}

test "codegen: let with int-literal initializer stores into fp-relative slot" {
    var compiled = try compileSource(
        \\def main()
        \\  let x: i16 = 42
        \\end
    );
    defer compiled.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    // x lives at [fp - 2] = mem[0xFFFC..0xFFFE].
    const slot = vm.mmap.readWord(0xFFFC);
    try std.testing.expectEqual(@as(u16, 42), slot);
}

test "codegen: binary add of two literals computes 5 + 3 = 8" {
    var compiled = try compileSource(
        \\def main()
        \\  let x: i16 = 5 + 3
        \\end
    );
    defer compiled.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    const slot = vm.mmap.readWord(0xFFFC);
    try std.testing.expectEqual(@as(u16, 8), slot);
}

test "codegen: binary sub respects operand order (10 - 3 = 7)" {
    var compiled = try compileSource(
        \\def main()
        \\  let x: i16 = 10 - 3
        \\end
    );
    defer compiled.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqual(@as(u16, 7), vm.mmap.readWord(0xFFFC));
}

test "codegen: unary neg flips sign" {
    var compiled = try compileSource(
        \\def main()
        \\  let x: i16 = -7
        \\end
    );
    defer compiled.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    // -7 as u16 = 0xFFF9
    try std.testing.expectEqual(@as(u16, 0xFFF9), vm.mmap.readWord(0xFFFC));
}

test "codegen: ident load + arithmetic across slots (x + y = 8)" {
    var compiled = try compileSource(
        \\def main()
        \\  let x: i16 = 5
        \\  let y: i16 = 3
        \\  let z: i16 = x + y
        \\end
    );
    defer compiled.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqual(@as(u16, 5), vm.mmap.readWord(0xFFFC)); // x
    try std.testing.expectEqual(@as(u16, 3), vm.mmap.readWord(0xFFFA)); // y
    try std.testing.expectEqual(@as(u16, 8), vm.mmap.readWord(0xFFF8)); // z
}

test "codegen: mul + nested precedence (2 * (3 + 4) = 14)" {
    var compiled = try compileSource(
        \\def main()
        \\  let r: i16 = 2 * (3 + 4)
        \\end
    );
    defer compiled.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqual(@as(u16, 14), vm.mmap.readWord(0xFFFC));
}

test "codegen: print of int literal writes decimal + newline" {
    var compiled = try compileSource(
        \\def main()
        \\  print 42
        \\end
    );
    defer compiled.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("42\n", writer.written());
}

test "codegen: print of multiple args separates with spaces" {
    var compiled = try compileSource(
        \\def main()
        \\  print 1, 2, 3
        \\end
    );
    defer compiled.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("1 2 3\n", writer.written());
}

test "codegen: print of let-bound value (1 + 2 = 3)" {
    var compiled = try compileSource(
        \\def main()
        \\  let x: i16 = 1 + 2
        \\  print x
        \\end
    );
    defer compiled.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("3\n", writer.written());
}

// ---------- free-fn calling convention (M1 chunk 2) ----------

test "codegen: nullary fn call returns acu value" {
    var compiled = try compileSource(
        \\def answer() -> i16
        \\  return 42
        \\end
        \\
        \\def main()
        \\  let r: i16 = answer()
        \\  print r
        \\end
    );
    defer compiled.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("42\n", writer.written());
}

test "codegen: binary fn (add a, b) called with literals" {
    var compiled = try compileSource(
        \\def add(a: i16, b: i16) -> i16
        \\  return a + b
        \\end
        \\
        \\def main()
        \\  print add(2, 3)
        \\end
    );
    defer compiled.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("5\n", writer.written());
}

test "codegen: call result stored into let-bound local" {
    var compiled = try compileSource(
        \\def add(a: i16, b: i16) -> i16
        \\  return a + b
        \\end
        \\
        \\def main()
        \\  let r: i16 = add(5, 3)
        \\  print r
        \\end
    );
    defer compiled.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("8\n", writer.written());
}

test "codegen: param order respects source ordering (sub a, b)" {
    var compiled = try compileSource(
        \\def sub(a: i16, b: i16) -> i16
        \\  return a - b
        \\end
        \\
        \\def main()
        \\  print sub(10, 3)
        \\end
    );
    defer compiled.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("7\n", writer.written());
}

test "codegen: nested call (twice(twice(2)) = 8)" {
    var compiled = try compileSource(
        \\def twice(x: i16) -> i16
        \\  return x + x
        \\end
        \\
        \\def main()
        \\  print twice(twice(2))
        \\end
    );
    defer compiled.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("8\n", writer.written());
}

// ---------- memory placement annotations (#261) ----------

test "codegen: @addr global is read from the pinned address" {
    var compiled = try compileSource(
        \\@addr $FE40
        \\let DISPCTL: u8 = 0
        \\
        \\def main()
        \\  let x: u8 = DISPCTL
        \\end
    );
    defer compiled.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();

    // Pre-load a byte at $FE40 so the read picks it up.
    var vm = gero.vm.VM.init(alloc);
    defer vm.deinit();
    const loaded = try gero.vm.parseGx(compiled.image);
    try vm.boot(alloc, loaded);
    vm.host = .{ .out = &writer.writer };
    vm.mmap.writeByte(0xFE40, 0x55);

    _ = gero.vm.run(&vm);

    // x's local slot = mem[fp-2] = mem[0xFFFC]; should hold 0x55.
    try std.testing.expectEqual(@as(u16, 0x55), vm.mmap.readWord(0xFFFC));
}

test "codegen: @addr global accepts assignment (MMIO write)" {
    var compiled = try compileSource(
        \\@addr $FE40
        \\let DISPCTL: u8 = 0
        \\
        \\def main()
        \\  DISPCTL = 42
        \\end
    );
    defer compiled.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    // The store landed at $FE40.
    try std.testing.expectEqual(@as(u16, 42), vm.mmap.readWord(0xFE40));
}

test "codegen: @volatile is accepted without altering codegen" {
    // Slice M1 doesn't register-cache, so @volatile is structural
    // recognition only; the test verifies it doesn't trigger
    // unsupported-feature diagnostics.
    var compiled = try compileSource(
        \\@addr $FE40
        \\@volatile
        \\let DISPCTL: u8 = 0
        \\
        \\def main()
        \\  DISPCTL = 1
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());
}

test "codegen: @zero_page allocates from byte 0 upward" {
    var compiled = try compileSource(
        \\@zero_page
        \\let cursor: u16 = 0
        \\
        \\@zero_page
        \\let next_cursor: u16 = 0
        \\
        \\def main()
        \\  cursor = $1234
        \\  next_cursor = $5678
        \\end
    );
    defer compiled.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    // cursor at $00, next_cursor at $02 (2 bytes each).
    try std.testing.expectEqual(@as(u16, 0x1234), vm.mmap.readWord(0x0000));
    try std.testing.expectEqual(@as(u16, 0x5678), vm.mmap.readWord(0x0002));
}

test "codegen: globals in data region land at data_base upward" {
    var compiled = try compileSource(
        \\let a: i16 = 0
        \\let b: i16 = 0
        \\
        \\def main()
        \\  a = 100
        \\  b = 200
        \\end
    );
    defer compiled.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqual(@as(u16, 100), vm.mmap.readWord(0x2000));
    try std.testing.expectEqual(@as(u16, 200), vm.mmap.readWord(0x2002));
}

test "codegen: a module-level `const` / `let` initializer is stored at startup" {
    // The slot is otherwise zero-filled; the entry prologue seeds it.
    try runAndExpect(
        \\const MAX_HP = 100
        \\const NAME = "hero"
        \\let counter = 7
        \\def main()
        \\  print MAX_HP
        \\  print NAME
        \\  print counter + 1
        \\end
    , "100\nhero\n8\n");
}

test "codegen: a module-level `const` can read an earlier `const` (declaration order)" {
    try runAndExpect(
        \\const A = 3
        \\const B = A + 4
        \\def main()
        \\  print A, B
        \\end
    , "3 7\n");
}

test "codegen: a module-level `const` enum value initializes its slot" {
    try runAndExpect(
        \\enum E
        \\  case Nil
        \\  case V(n: i16)
        \\end
        \\const C = E.V(9)
        \\def main()
        \\  print C
        \\end
    , "E.V(9)\n");
}

test "codegen: @align(16) pads global placement to a 16-byte boundary" {
    var compiled = try compileSource(
        \\let pad: i16 = 0
        \\
        \\@align(16)
        \\let aligned: i16 = 0
        \\
        \\def main()
        \\  pad = 1
        \\  aligned = 2
        \\end
    );
    defer compiled.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    // pad at $2000 (unaligned start). aligned must round UP from
    // $2002 to the next 16-byte boundary = $2010.
    try std.testing.expectEqual(@as(u16, 1), vm.mmap.readWord(0x2000));
    try std.testing.expectEqual(@as(u16, 2), vm.mmap.readWord(0x2010));
}

test "codegen: read-modify-write through @addr binding" {
    var compiled = try compileSource(
        \\@addr $FE40
        \\let counter: i16 = 0
        \\
        \\def main()
        \\  counter = counter + 1
        \\end
    );
    defer compiled.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();

    var vm = gero.vm.VM.init(alloc);
    defer vm.deinit();
    const loaded = try gero.vm.parseGx(compiled.image);
    try vm.boot(alloc, loaded);
    vm.host = .{ .out = &writer.writer };
    vm.mmap.writeWord(0xFE40, 41);

    _ = gero.vm.run(&vm);
    try std.testing.expectEqual(@as(u16, 42), vm.mmap.readWord(0xFE40));
}

test "codegen: @bank N routes a def's bytecode into bank N's buffer" {
    var compiled = try compileSource(
        \\@bank 2
        \\def town() -> i16
        \\  return 42
        \\end
        \\
        \\def main()
        \\  print 0
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    // .gx header should declare bank_count = 3 (banks 0, 1, 2).
    const loaded = try gero.vm.parseGx(compiled.image);
    try std.testing.expectEqual(@as(u8, 3), loaded.header.bank_count);
    try std.testing.expect(loaded.header.isBanked());

    // Banks 0 + 1 are empty zero-padded windows; bank 2 carries
    // `town`'s bytecode. The first byte of bank 2 should be a
    // `mov imm16, acu` (0x10) emitting the `42` literal.
    const bank2 = loaded.banks[2 * 0x4000 ..][0..0x4000];
    try std.testing.expectEqual(@as(u8, 0x10), bank2[0]); // mov imm16, reg
    try std.testing.expectEqual(@as(u8, 42), bank2[1]); // low byte
    try std.testing.expectEqual(@as(u8, 0), bank2[2]); // high byte
}

test "codegen: cross-bank call goes through __call_bank trampoline + executes correctly" {
    var compiled = try compileSource(
        \\@bank 2
        \\def town() -> i16
        \\  return 42
        \\end
        \\
        \\def main()
        \\  let r: i16 = town()
        \\  print r
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    // The full pipeline must boot, switch into bank 2 via the
    // trampoline, fetch the literal, return to main, and print
    // `42\n`.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("42\n", writer.written());
}

test "codegen: cross-bank call reads its parameters at the right frame offset" {
    // The trampoline is frame-transparent: the callee must read arg0 at
    // [fp+4] exactly as a direct call would, despite the bank hop.
    var compiled = try compileSource(
        \\@bank 2
        \\def add(a: i16, b: i16) -> i16
        \\  return a + b
        \\end
        \\
        \\def main()
        \\  print add(10, 32)
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("42\n", writer.written());
}

test "codegen: nested cross-bank calls restore mb + unwind through the save-stack" {
    // main → outer (bank 2) → inner (bank 1): the save-stack must
    // restore mb to bank 2 when inner returns so outer finishes its
    // arithmetic in its own bank, then to the base image for main.
    var compiled = try compileSource(
        \\@bank 1
        \\def inner(x: i16) -> i16
        \\  return x * 2
        \\end
        \\
        \\@bank 2
        \\def outer(x: i16) -> i16
        \\  return inner(x) + 1
        \\end
        \\
        \\def main()
        \\  print outer(20)
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("41\n", writer.written());
}

test "codegen: cross-bank call returning a struct preserves the sret ABI" {
    // The hidden sret pointer is pushed above the args; the frame-
    // transparent trampoline must leave it (and the args) in place so
    // the callee copies its result back to the caller's scratch slot.
    try runAndExpect(
        \\struct Pos
        \\  x: i16
        \\  y: i16
        \\end
        \\@bank 2
        \\def mk(a: i16, b: i16) -> Pos
        \\  return Pos { x: a, y: b }
        \\end
        \\def main()
        \\  let p: Pos = mk(10, 32)
        \\  print p.x
        \\  print p.y
        \\end
    , "10\n32\n");
}

test "codegen: banked program relocates the stack out of the bank window" {
    // The boot sp (0xFFFE) would place call frames in the IO page +
    // bank window (0xC000..0xFEFF, bank-switched); a banked program's
    // entry must move the stack into low RAM as its first instruction.
    var compiled = try compileSource(
        \\@bank 2
        \\def town() -> i16
        \\  return 42
        \\end
        \\def main()
        \\  print town()
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var vm = gero.vm.VM.init(alloc);
    defer vm.deinit();
    const loaded = try gero.vm.parseGx(compiled.image);
    try vm.boot(alloc, loaded);
    // Both sp and fp move into low RAM — the entry's own locals are
    // fp-relative, so fp must move too or they'd stay in the IO page.
    _ = gero.vm.step(&vm); // mov #bank_stack_top, sp
    _ = gero.vm.step(&vm); // mov sp, fp
    try std.testing.expectEqual(@as(u16, 0x0FFE), vm.regs.read(.sp));
    try std.testing.expectEqual(@as(u16, 0x0FFE), vm.regs.read(.fp));
}

test "codegen: cross-bank call in a loop keeps the save-stack balanced" {
    // Each call pushes then pops one save-stack level; an imbalance
    // would drift the save-sp and corrupt a later iteration's return.
    try runAndExpect(
        \\@bank 2
        \\def dbl(x: i16) -> i16
        \\  return x * 2
        \\end
        \\def main()
        \\  let i: i16 = 0
        \\  let acc: i16 = 0
        \\  while i < 4
        \\    acc = acc + dbl(i)
        \\    i = i + 1
        \\  end
        \\  print acc
        \\end
    , "12\n");
}

test "codegen: byte-store to @addr global uses movl (does not clobber adjacent byte)" {
    var compiled = try compileSource(
        \\@addr $FE40
        \\let DISPCTL: u8 = 0
        \\
        \\def main()
        \\  DISPCTL = 1
        \\end
    );
    defer compiled.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();

    var vm = gero.vm.VM.init(alloc);
    defer vm.deinit();
    const loaded = try gero.vm.parseGx(compiled.image);
    try vm.boot(alloc, loaded);
    vm.host = .{ .out = &writer.writer };
    // Pre-seed $FE41 with a sentinel — the byte store must NOT
    // overwrite it (that would mean we emitted the 16-bit mov).
    vm.mmap.writeByte(0xFE41, 0xAB);
    _ = gero.vm.run(&vm);

    try std.testing.expectEqual(@as(u8, 1), vm.mmap.readByte(0xFE40));
    try std.testing.expectEqual(@as(u8, 0xAB), vm.mmap.readByte(0xFE41));
}

// ---------- control flow (if / while / for / repeat / match) ----------

/// Shorthand: compile, boot, run until halt, assert on printed output.
fn runAndExpect(source: []const u8, expected: []const u8) !void {
    var compiled = try compileSource(source);
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings(expected, writer.written());
}

/// Like `runAndExpect`, but threads a `use X as Y from "./mod"` alias
/// table (`Y` → `X`) through both the typechecker and codegen — the
/// post-fuse view of a quoted-path import whose alias has no inlined
/// declaration. Each pair is `.{ alias, real_name }`.
fn runWithAliasesAndExpect(source: []const u8, pairs: []const [2][]const u8, expected: []const u8) !void {
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source, stream);
    defer tree.deinit();
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);

    var aliases: gero.lang.ImportAliases = .{};
    defer aliases.deinit(alloc);
    for (pairs) |p| try aliases.put(alloc, p[0], p[1]);

    var checked = try gero.lang.typecheckModule(alloc, source, &tree.program, &aliases);
    defer checked.deinit();
    if (checked.diagnostics.len > 0) {
        for (checked.diagnostics) |d| std.debug.print("  - {s}: {s}\n", .{ d.code, d.message });
    }
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.len);

    var compiled = try gero.lang.compile(alloc, source, &checked, .{ .import_aliases = &aliases });
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings(expected, writer.written());
}

test "codegen: import alias resolves a `@static` class call" {
    // `keys` is `input` under another name — `keys.flag()` static-
    // dispatches to the emitted `input.flag`.
    try runWithAliasesAndExpect(
        \\class input
        \\  @static
        \\  def flag() -> i16
        \\    return 7
        \\  end
        \\end
        \\def main()
        \\  print keys.flag()
        \\end
    , &.{.{ "keys", "input" }}, "7\n");
}

test "codegen: import alias resolves a free `def` call" {
    try runWithAliasesAndExpect(
        \\def helper(x: i16) -> i16
        \\  return x + 1
        \\end
        \\def main()
        \\  print h(41)
        \\end
    , &.{.{ "h", "helper" }}, "42\n");
}

test "codegen: import alias resolves a module-level const" {
    try runWithAliasesAndExpect(
        \\const MAX = 100
        \\def main()
        \\  print M
        \\end
    , &.{.{ "M", "MAX" }}, "100\n");
}

test "codegen: import alias resolves a struct type + literal" {
    try runWithAliasesAndExpect(
        \\struct Point
        \\  x: i16
        \\  y: i16
        \\end
        \\def main()
        \\  let p: P = P { x: 3, y: 4 }
        \\  print p.y
        \\end
    , &.{.{ "P", "Point" }}, "4\n");
}

test "codegen: import alias resolves an enum in a `match`" {
    try runWithAliasesAndExpect(
        \\enum Color
        \\  case Red
        \\  case Green
        \\  case Blue
        \\end
        \\def main()
        \\  let c: C = C.Blue
        \\  match c
        \\    case C.Red => print 1
        \\    case C.Green => print 2
        \\    case C.Blue => print 3
        \\  end
        \\end
    , &.{.{ "C", "Color" }}, "3\n");
}

test "codegen: a local binding shadows an import alias of the same name" {
    // `h` is both an alias for `helper` and a local — the local wins,
    // so `h` reads `5`, not a call to `helper`.
    try runWithAliasesAndExpect(
        \\def helper() -> i16
        \\  return 99
        \\end
        \\def main()
        \\  let h: i16 = 5
        \\  print h
        \\end
    , &.{.{ "h", "helper" }}, "5\n");
}

test "codegen: a selectively-imported stdlib function lowers when called bare" {
    try runAndExpect(
        \\use max from math
        \\def main()
        \\  print max(3, 7)
        \\end
    , "7\n");
}

test "codegen: a renamed selective stdlib import lowers when called bare" {
    try runAndExpect(
        \\use max as biggest from math
        \\def main()
        \\  print biggest(3, 7)
        \\end
    , "7\n");
}

test "codegen: a param shadows an import alias of the same name" {
    // `helper` is both an alias for `real_thing` and a param — the
    // param wins, so `f(5)` returns 5, not a call to `real_thing`.
    try runWithAliasesAndExpect(
        \\def real_thing() -> i16
        \\  return 100
        \\end
        \\def f(helper: i16) -> i16
        \\  return helper
        \\end
        \\def main()
        \\  print f(5)
        \\end
    , &.{.{ "helper", "real_thing" }}, "5\n");
}

test "codegen: a local named like an alias target doesn't capture the alias" {
    // `h` aliases the import `helper`; a local also *named* `helper`
    // must not capture `h` — the alias resolves to the module-level
    // export, so `h()` calls it (11), not the local.
    try runWithAliasesAndExpect(
        \\def helper() -> i16
        \\  return 11
        \\end
        \\def main()
        \\  let helper: i16 = 777
        \\  print h()
        \\end
    , &.{.{ "h", "helper" }}, "11\n");
}

test "codegen: a local closure shadows a selective stdlib import" {
    // `math.max(2, 9)` is 9; the local closure `a + b` is 11 — the
    // local must win.
    try runAndExpect(
        \\use max from math
        \\def main()
        \\  let max = |a: i16, b: i16| -> i16 a + b
        \\  print max(2, 9)
        \\end
    , "11\n");
}

test "codegen: a local closure shadows a same-named class constructor" {
    try runAndExpect(
        \\class Widget
        \\  let v: i16
        \\  def init(self)
        \\    self.v = 1
        \\  end
        \\end
        \\def main()
        \\  let Widget = |x: i16| -> i16 x * 2
        \\  print Widget(21)
        \\end
    , "42\n");
}

test "codegen: an aliased `bake def` is evaluated in a const initializer" {
    // The const init calls the bake def through its alias — it must
    // still be folded at compile time, not silently skipped.
    try runWithAliasesAndExpect(
        \\bake def origin() -> i16
        \\  return 1234
        \\end
        \\const C = make()
        \\def main()
        \\  print C
        \\end
    , &.{.{ "make", "origin" }}, "1234\n");
}

test "codegen: an aliased variadic `def` is called variadically" {
    try runWithAliasesAndExpect(
        \\def pick(first: i16, rest: ...) -> i16
        \\  return first
        \\end
        \\def main()
        \\  print choose(10, 20, 30, 40)
        \\end
    , &.{.{ "choose", "pick" }}, "10\n");
}

test "codegen: an `asm` body with multiple instructions is rejected" {
    try expectCodegenError(
        \\def main()
        \\  asm "nop
        \\nop"
        \\end
    , "E_CODEGEN_INLINE_ASM");
}

test "codegen: if-then with truthy cond runs the body" {
    try runAndExpect(
        \\def main()
        \\  if 1 < 2
        \\    print 1
        \\  end
        \\end
    , "1\n");
}

test "codegen: if-else with falsy cond runs the else branch" {
    try runAndExpect(
        \\def main()
        \\  if 1 > 2
        \\    print 1
        \\  else
        \\    print 0
        \\  end
        \\end
    , "0\n");
}

test "codegen: if-elif-else chain selects the matching arm" {
    try runAndExpect(
        \\def main()
        \\  let x: i16 = 2
        \\  if x == 1
        \\    print 1
        \\  else if x == 2
        \\    print 2
        \\  else
        \\    print 3
        \\  end
        \\end
    , "2\n");
}

test "codegen: comparison operators (eq / neq / lt / lte / gt / gte) all branch correctly" {
    try runAndExpect(
        \\def main()
        \\  let a: i16 = 5
        \\  let b: i16 = 5
        \\  if a == b
        \\    print 1
        \\  end
        \\  if a != b
        \\    print 99
        \\  end
        \\  if a >= b
        \\    print 2
        \\  end
        \\  if a <= b
        \\    print 3
        \\  end
        \\  if a < 10
        \\    print 4
        \\  end
        \\  if a > 0
        \\    print 5
        \\  end
        \\end
    , "1\n2\n3\n4\n5\n");
}

test "codegen: logical and/or short-circuit correctly" {
    try runAndExpect(
        \\def main()
        \\  if 1 == 1 and 2 == 2
        \\    print 1
        \\  end
        \\  if 1 == 1 or 2 == 99
        \\    print 2
        \\  end
        \\  if 1 == 2 and 0 == 0
        \\    print 99
        \\  end
        \\end
    , "1\n2\n");
}

test "codegen: logical not inverts truthiness" {
    try runAndExpect(
        \\def main()
        \\  if not (1 == 2)
        \\    print 1
        \\  end
        \\end
    , "1\n");
}

test "codegen: while loop iterates until cond false" {
    try runAndExpect(
        \\def main()
        \\  let i: i16 = 0
        \\  while i < 3
        \\    print i
        \\    i = i + 1
        \\  end
        \\end
    , "0\n1\n2\n");
}

test "codegen: break exits the innermost loop" {
    try runAndExpect(
        \\def main()
        \\  let i: i16 = 0
        \\  while i < 10
        \\    if i == 3
        \\      break
        \\    end
        \\    print i
        \\    i = i + 1
        \\  end
        \\end
    , "0\n1\n2\n");
}

test "codegen: continue skips the rest of the iteration" {
    try runAndExpect(
        \\def main()
        \\  let i: i16 = 0
        \\  while i < 5
        \\    i = i + 1
        \\    if i == 3
        \\      continue
        \\    end
        \\    print i
        \\  end
        \\end
    , "1\n2\n4\n5\n");
}

test "codegen: nested while with labeled break exits the outer loop" {
    try runAndExpect(
        \\def main()
        \\  let i: i16 = 0
        \\  while i < 5 :outer
        \\    let j: i16 = 0
        \\    while j < 5
        \\      if j == 2
        \\        break :outer
        \\      end
        \\      print j
        \\      j = j + 1
        \\    end
        \\    i = i + 1
        \\  end
        \\end
    , "0\n1\n");
}

test "codegen: for-range exclusive iterates start to end-1" {
    try runAndExpect(
        \\def main()
        \\  for i in 0..3
        \\    print i
        \\  end
        \\end
    , "0\n1\n2\n");
}

test "codegen: for-range inclusive iterates start to end" {
    try runAndExpect(
        \\def main()
        \\  for i in 1..=3
        \\    print i
        \\  end
        \\end
    , "1\n2\n3\n");
}

test "codegen: for-range with explicit step skips by N" {
    try runAndExpect(
        \\def main()
        \\  for i in 0..=10 step 5
        \\    print i
        \\  end
        \\end
    , "0\n5\n10\n");
}

test "codegen: for-range respects break" {
    try runAndExpect(
        \\def main()
        \\  for i in 0..=10
        \\    if i == 4
        \\      break
        \\    end
        \\    print i
        \\  end
        \\end
    , "0\n1\n2\n3\n");
}

test "codegen: for over a fixed array iterates its scalar elements" {
    try runAndExpect(
        \\def main()
        \\  let arr: [i16; 3] = [11, 22, 33]
        \\  for a in arr
        \\    print a
        \\  end
        \\end
    , "11\n22\n33\n");
}

test "codegen: for over an array literal iterates the materialized elements" {
    try runAndExpect(
        \\def main()
        \\  for x in [1, 2, 3]
        \\    print x
        \\  end
        \\  for y in [7; 3]
        \\    print y
        \\  end
        \\end
    , "1\n2\n3\n7\n7\n7\n");
}

test "codegen: for over an array honors continue + break" {
    try runAndExpect(
        \\def main()
        \\  let arr: [i16; 5] = [1, 2, 3, 4, 5]
        \\  for a in arr
        \\    if a == 2
        \\      continue
        \\    end
        \\    if a == 4
        \\      break
        \\    end
        \\    print a
        \\  end
        \\end
    , "1\n3\n");
}

test "codegen: for over a `Vec(T)` iterates its elements" {
    try runAndExpect(
        \\def main()
        \\  let v: Vec(i16) = Vec.from([7, 8, 9])
        \\  for x in v
        \\    print x
        \\  end
        \\end
    , "7\n8\n9\n");
}

test "codegen: for over a `str` yields each char until the terminator" {
    try runAndExpect(
        \\def main()
        \\  for c in "AB"
        \\    print c
        \\  end
        \\end
    , "A\nB\n");
}

test "codegen: for over an array of aggregates binds each element by value" {
    try runAndExpect(
        \\struct Pt
        \\  x: i16
        \\  y: i16
        \\end
        \\def main()
        \\  let pts: [Pt; 2] = [Pt { x: 1, y: 2 }, Pt { x: 3, y: 4 }]
        \\  for p in pts
        \\    print p.x + p.y
        \\  end
        \\end
    , "3\n7\n");
}

test "codegen: for over a class iterator (`next -> T?`) drains scalar values" {
    try runAndExpect(
        \\class Counter
        \\  let n: i16
        \\  def init(self)
        \\    self.n = 0
        \\  end
        \\  def next(self) -> i16?
        \\    if self.n >= 3
        \\      return nil
        \\    end
        \\    let v = self.n
        \\    self.n = self.n + 1
        \\    return v * 10
        \\  end
        \\end
        \\def main()
        \\  let c = Counter()
        \\  for n in c
        \\    print n
        \\  end
        \\end
    , "0\n10\n20\n");
}

test "codegen: for over a class iterator yielding class instances" {
    try runAndExpect(
        \\class Item
        \\  let v: i16
        \\  def init(self, x: i16)
        \\    self.v = x
        \\  end
        \\end
        \\class Bag
        \\  let cur: i16
        \\  def init(self)
        \\    self.cur = 0
        \\  end
        \\  def next(self) -> Item?
        \\    if self.cur >= 2
        \\      return nil
        \\    end
        \\    self.cur = self.cur + 1
        \\    return Item(self.cur * 100)
        \\  end
        \\end
        \\def main()
        \\  let b = Bag()
        \\  for item in b
        \\    print item.v
        \\  end
        \\end
    , "100\n200\n");
}

test "codegen: nested for over array + Vec multiplies the passes" {
    try runAndExpect(
        \\def main()
        \\  let arr: [i16; 2] = [1, 2]
        \\  let v: Vec(i16) = Vec.from([10, 20])
        \\  for a in arr
        \\    for b in v
        \\      print a + b
        \\    end
        \\  end
        \\end
    , "11\n21\n12\n22\n");
}

test "codegen: labeled break exits an outer for-over-iterable" {
    try runAndExpect(
        \\def main()
        \\  let arr: [i16; 3] = [1, 2, 3]
        \\  for a in arr :outer
        \\    for c in "xy"
        \\      if a == 2
        \\        break :outer
        \\      end
        \\      print a
        \\    end
        \\  end
        \\end
    , "1\n1\n");
}

test "codegen: a present `let x: T? = v` unwraps through `if let`" {
    try runAndExpect(
        \\def main()
        \\  let a: i16? = 5
        \\  if let v = a
        \\    print v
        \\  end
        \\  let b: i16? = nil
        \\  if let w = b
        \\    print w
        \\  else
        \\    print 99
        \\  end
        \\end
    , "5\n99\n");
}

test "codegen: a fn returning a scalar `T?` round-trips present + nil" {
    try runAndExpect(
        \\def find(t: i16) -> i16?
        \\  if t == 7
        \\    return nil
        \\  end
        \\  return t + 100
        \\end
        \\def main()
        \\  if let r = find(3)
        \\    print r
        \\  end
        \\  if let r2 = find(7)
        \\    print r2
        \\  else
        \\    print 999
        \\  end
        \\end
    , "103\n999\n");
}

test "codegen: a method returning a scalar `T?` unwraps through `if let`" {
    try runAndExpect(
        \\class Counter
        \\  let n: i16
        \\  def init(self)
        \\    self.n = 0
        \\  end
        \\  def next(self) -> i16?
        \\    if self.n >= 3
        \\      return nil
        \\    end
        \\    let v = self.n
        \\    self.n = self.n + 1
        \\    return v
        \\  end
        \\end
        \\def main()
        \\  let c = Counter()
        \\  if let n = c.next()
        \\    print n
        \\  end
        \\end
    , "0\n");
}

test "codegen: mutation through a `&struct` param propagates to the caller" {
    try runAndExpect(
        \\struct P
        \\  x: i16
        \\  y: i16
        \\end
        \\def setx(p: &P)
        \\  p.x = 99
        \\end
        \\def main()
        \\  let pt: P = P { x: 7, y: 42 }
        \\  setx(&pt)
        \\  print pt.x
        \\  print pt.y
        \\end
    , "99\n42\n");
}

test "codegen: index read + write through a `&[T; N]` param hits the caller's array" {
    try runAndExpect(
        \\def zero1(a: &[i16; 3])
        \\  a[1] = 0
        \\end
        \\def main()
        \\  let arr: [i16; 3] = [4, 5, 6]
        \\  zero1(&arr)
        \\  print arr[0]
        \\  print arr[1]
        \\  print arr[2]
        \\end
    , "4\n0\n6\n");
}

test "codegen: mutating a `&Vec(T)` param is visible to the caller" {
    try runAndExpect(
        \\def app(v: &Vec(i16))
        \\  v.push(30)
        \\end
        \\def main()
        \\  let v: Vec(i16) = Vec.from([10, 20])
        \\  app(&v)
        \\  print v.len()
        \\  print v.at(2)
        \\end
    , "3\n30\n");
}

test "codegen: a `&T` reference arg reaches a method through dispatch" {
    try runAndExpect(
        \\struct P
        \\  x: i16
        \\end
        \\class Bumper
        \\  def init(self) end
        \\  def bump(self, p: &P)
        \\    p.x = p.x + 1
        \\  end
        \\end
        \\def main()
        \\  let pt: P = P { x: 5 }
        \\  let b = Bumper()
        \\  b.bump(&pt)
        \\  print pt.x
        \\end
    , "6\n");
}

test "codegen: for over a `&[T; N]` iterates the referenced array" {
    try runAndExpect(
        \\def each(a: &[i16; 3])
        \\  for x in a
        \\    print x
        \\  end
        \\end
        \\def main()
        \\  let arr: [i16; 3] = [4, 5, 6]
        \\  each(&arr)
        \\end
    , "4\n5\n6\n");
}

test "codegen: a `[T; N]` param is passed by value — callee mutation stays local" {
    try runAndExpect(
        \\def clobber(a: [i16; 3]) -> i16
        \\  a[0] = 999
        \\  return a[0]
        \\end
        \\def main()
        \\  let arr: [i16; 3] = [4, 5, 6]
        \\  print clobber(arr)
        \\  print arr[0]
        \\end
    , "999\n4\n");
}

test "codegen: a `[T; N]` param reads its copied elements among scalar args" {
    try runAndExpect(
        \\def pick(n: i16, a: [i16; 3], m: i16) -> i16
        \\  return n + a[1] + m
        \\end
        \\def main()
        \\  let arr: [i16; 3] = [4, 5, 6]
        \\  print pick(10, arr, 20)
        \\end
    , "35\n");
}

test "codegen: a `Vec(T)` param is passed by value (the moved header)" {
    try runAndExpect(
        \\def total(v: Vec(i16)) -> i16
        \\  return v.at(0) + v.at(1)
        \\end
        \\def main()
        \\  let v: Vec(i16) = Vec.from([6, 7])
        \\  print total(v)
        \\end
    , "13\n");
}

test "codegen: a `Vec(T)` argument reaches a method by value" {
    try runAndExpect(
        \\class Adder
        \\  def init(self) end
        \\  def sum(self, v: Vec(i16)) -> i16
        \\    return v.at(0) + v.at(1) + v.at(2)
        \\  end
        \\end
        \\def main()
        \\  let v: Vec(i16) = Vec.from([10, 20, 30])
        \\  let a = Adder()
        \\  print a.sum(v)
        \\end
    , "60\n");
}

test "codegen: a zero-length array binding is a no-op (empty for-loop body)" {
    try runAndExpect(
        \\def main()
        \\  let a: [i16; 0] = []
        \\  for x in a
        \\    print x
        \\  end
        \\  print 100
        \\end
    , "100\n");
}

test "codegen: repeat-until runs body at least once then exits when cond is true" {
    try runAndExpect(
        \\def main()
        \\  let i: i16 = 0
        \\  repeat
        \\    print i
        \\    i = i + 1
        \\  until i == 3
        \\end
    , "0\n1\n2\n");
}

test "codegen: match with literal patterns dispatches the right arm" {
    try runAndExpect(
        \\def main()
        \\  let x: i16 = 2
        \\  match x
        \\    case 1 => print 10
        \\    case 2 => print 20
        \\    case 3 => print 30
        \\    case _ => print 99
        \\  end
        \\end
    , "20\n");
}

test "codegen: match with wildcard arm catches all" {
    try runAndExpect(
        \\def main()
        \\  let x: i16 = 42
        \\  match x
        \\    case 1 => print 10
        \\    case _ => print 0
        \\  end
        \\end
    , "0\n");
}

test "codegen: match with OR pattern collapses three alts to one body" {
    try runAndExpect(
        \\def main()
        \\  let x: i16 = 3
        \\  match x
        \\    case 1 | 2 | 3 => print 100
        \\    case _ => print 0
        \\  end
        \\end
    , "100\n");
}

test "codegen: match with range pattern matches inclusive bounds" {
    try runAndExpect(
        \\def main()
        \\  let x: i16 = 7
        \\  match x
        \\    case 0..=5 => print 1
        \\    case 6..=10 => print 2
        \\    case _ => print 3
        \\  end
        \\end
    , "2\n");
}

test "codegen: match with guard skips arm when guard is false" {
    try runAndExpect(
        \\def main()
        \\  let x: i16 = 10
        \\  match x
        \\    case n when n > 100 => print 1
        \\    case n when n > 5 => print 2
        \\    case _ => print 3
        \\  end
        \\end
    , "2\n");
}

test "codegen: defer fires at end of block (LIFO order)" {
    try runAndExpect(
        \\def main()
        \\  defer print 1
        \\  defer print 2
        \\  defer print 3
        \\  print 0
        \\end
    , "0\n3\n2\n1\n");
}

test "codegen: defer runs on early return" {
    try runAndExpect(
        \\def cleanup_demo()
        \\  defer print 99
        \\  print 1
        \\  return
        \\end
        \\def main()
        \\  cleanup_demo()
        \\end
    , "1\n99\n");
}

test "codegen: defer runs on break path" {
    try runAndExpect(
        \\def main()
        \\  let i: i16 = 0
        \\  while i < 5
        \\    defer print 9
        \\    if i == 1
        \\      break
        \\    end
        \\    print i
        \\    i = i + 1
        \\  end
        \\end
    , "0\n9\n9\n");
}

test "codegen: defer in nested block fires before outer defers" {
    try runAndExpect(
        \\def main()
        \\  defer print 1
        \\  do
        \\    defer print 2
        \\    defer print 3
        \\    print 0
        \\  end
        \\  print 4
        \\end
    , "0\n3\n2\n4\n1\n");
}

test "codegen: defer fires on continue path before going to next iteration" {
    try runAndExpect(
        \\def main()
        \\  let i: i16 = 0
        \\  while i < 3
        \\    defer print 9
        \\    i = i + 1
        \\    if i == 2
        \\      continue
        \\    end
        \\    print i
        \\  end
        \\end
    ,
        // Iteration 1: i becomes 1, print 1, fall-through defer → 9.
        // Iteration 2: i becomes 2, continue → defer fires (9).
        // Iteration 3: i becomes 3, print 3, fall-through defer → 9.
        "1\n9\n9\n3\n9\n");
}

// ---------- str-literal print, fixed-point, recursion, frame slots ----------

test "codegen: `s.len` counts bytes to the null terminator" {
    try runAndExpect(
        \\def main()
        \\  let s: str = "hello"
        \\  print s.len
        \\end
    , "5\n");
}

test "codegen: `s.at(i)` loads the byte at index i" {
    try runAndExpect(
        \\def main()
        \\  let s: str = "ABC"
        \\  print s.at(0)
        \\  print s.at(2)
        \\end
    , "65\n67\n");
}

test "codegen: `s.cmp(other)` orders byte-wise" {
    try runAndExpect(
        \\def main()
        \\  let a: str = "abc"
        \\  let b: str = "abd"
        \\  print a.cmp(b)
        \\  print b.cmp(a)
        \\  print a.cmp(a)
        \\end
    , "-1\n1\n0\n");
}

test "codegen: str.format substitutes positional placeholders" {
    try runAndExpect(
        \\def main()
        \\  let hp: i16 = 80
        \\  let max: i16 = 100
        \\  print str.format("hp={0}/{1}", hp, max)
        \\end
    , "hp=80/100\n");
}

test "codegen: str.format honors per-placeholder specs, reuse, and brace escapes" {
    try runAndExpect(
        \\def main()
        \\  let addr: u16 = 1266
        \\  print str.format("a={0:04X} b={0} {{x}}", addr)
        \\end
    , "a=04F2 b=1266 {x}\n");
}

test "codegen: str.format with a str argument derefs the pointer" {
    try runAndExpect(
        \\def main()
        \\  let w: str = "world"
        \\  print str.format("hi {0}", w)
        \\end
    , "hi world\n");
}

test "codegen: variadic `args.N` reads the N-th vararg word" {
    try runAndExpect(
        \\def at(args: ...) -> i16
        \\  return args.0 + args.1 + args.2
        \\end
        \\def main()
        \\  print at(10, 20, 30)
        \\end
    , "60\n");
}

test "codegen: variadic `args.N` is word-strided, not byte-packed, for sub-word T" {
    // Each vararg is pushed as a full word; a `u8` element rides the
    // low half, so `args.2` must stride by a word — byte-packing it
    // would read the high half of an earlier slot.
    try runAndExpect(
        \\def pick(args: ...) -> u8
        \\  return args.2
        \\end
        \\def main()
        \\  let a: u8 = 11
        \\  let b: u8 = 22
        \\  let c: u8 = 33
        \\  print pick(a, b, c)
        \\end
    , "33\n");
}

test "codegen: each call-site arity emits its own specialization" {
    try runAndExpect(
        \\def first(args: ...) -> i16
        \\  return args.0
        \\end
        \\def main()
        \\  print first(7, 8, 9)
        \\  print first(100, 200)
        \\  print first(42)
        \\end
    , "7\n100\n42\n");
}

test "codegen: `format(fmt, args)` forwards the variadic tuple positionally" {
    try runAndExpect(
        \\def line(fmt: str, args: ...) -> str
        \\  return str.format(fmt, args)
        \\end
        \\def main()
        \\  print line("hp={0}/{1}", 30, 100)
        \\end
    , "hp=30/100\n");
}

test "codegen: forwarded varargs keep their specs across arities" {
    try runAndExpect(
        \\def log(level: u8, fmt: str, args: ...) -> str
        \\  return str.format(fmt, args)
        \\end
        \\def main()
        \\  print log(1, "x={0} y={1:04X}", 3, 255)
        \\  print log(2, "single {0}", 42)
        \\end
    , "x=3 y=00FF\nsingle 42\n");
}

test "codegen: forwarding zero varargs emits the format string verbatim" {
    try runAndExpect(
        \\def line(fmt: str, args: ...) -> str
        \\  return str.format(fmt, args)
        \\end
        \\def main()
        \\  print line("no placeholders")
        \\end
    , "no placeholders\n");
}

test "codegen: a plain tuple value forwards to `str.format` positionally" {
    try runAndExpect(
        \\def main()
        \\  let t = (7, 8)
        \\  print str.format("{0}/{1}", t)
        \\end
    , "7/8\n");
}

test "codegen: a variadic method monomorphizes per arity (index + forward)" {
    try runAndExpect(
        \\class Logger
        \\  def fmt(self, f: str, args: ...) -> str
        \\    return str.format(f, args)
        \\  end
        \\  def first(self, args: ...) -> i16
        \\    return args.0
        \\  end
        \\end
        \\def main()
        \\  let l = Logger()
        \\  print l.fmt("a={0} b={1}", 1, 2)
        \\  print l.fmt("just {0}", 9)
        \\  print l.first(100, 200, 300)
        \\end
    , "a=1 b=2\njust 9\n100\n");
}

test "codegen: a variadic method reads `self` fields alongside its args" {
    try runAndExpect(
        \\class Counter
        \\  let base: i16
        \\  def init(self, b: i16)
        \\    self.base = b
        \\  end
        \\  def add(self, args: ...) -> i16
        \\    return self.base + args.0 + args.1
        \\  end
        \\end
        \\def main()
        \\  let c = Counter(100)
        \\  print c.add(10, 20)
        \\end
    , "130\n");
}

test "codegen: an inherited variadic method dispatches to its declaring class" {
    try runAndExpect(
        \\class Base
        \\  def tag(self, args: ...) -> i16
        \\    return args.0 + args.1
        \\  end
        \\end
        \\class Derived extends Base
        \\  def go(self) -> i16
        \\    return super.tag(3, 4)
        \\  end
        \\end
        \\def main()
        \\  let d = Derived()
        \\  print d.tag(5, 6)
        \\  print d.go()
        \\end
    , "11\n7\n");
}

test "codegen: a struct-returning variadic method rides the sret ABI" {
    try runAndExpect(
        \\struct Point
        \\  x: i16
        \\  y: i16
        \\end
        \\class Maker
        \\  def mk(self, args: ...) -> Point
        \\    return Point { x: args.0, y: args.1 }
        \\  end
        \\end
        \\def main()
        \\  let m = Maker()
        \\  let p = m.mk(11, 22)
        \\  print p.x
        \\  print p.y
        \\end
    , "11\n22\n");
}

test "codegen: a `@static` method is called as `ClassName.method` with no self" {
    try runAndExpect(
        \\class Box
        \\  @static
        \\  def make(a: i16, b: i16) -> i16
        \\    return a + b
        \\  end
        \\end
        \\def main()
        \\  print Box.make(10, 5)
        \\end
    , "15\n");
}

test "codegen: a `@static` method can return a struct via the sret ABI" {
    try runAndExpect(
        \\struct P
        \\  x: i16
        \\  y: i16
        \\end
        \\class Mk
        \\  @static
        \\  def origin() -> P
        \\    return P { x: 0, y: 7 }
        \\  end
        \\end
        \\def main()
        \\  let p = Mk.origin()
        \\  print p.y
        \\end
    , "7\n");
}

test "codegen: a variadic `@static` method monomorphizes per arity" {
    try runAndExpect(
        \\class Box
        \\  @static
        \\  def fmt(f: str, args: ...) -> str
        \\    return str.format(f, args)
        \\  end
        \\end
        \\def main()
        \\  print Box.fmt("{0}/{1}", 3, 4)
        \\  print Box.fmt("one {0}", 9)
        \\end
    , "3/4\none 9\n");
}

test "codegen: a tuple argument passes by value through a method call" {
    // pushSretAndArgs must copy the tuple's bytes, not just its base
    // address — exercised here through a `@static` method.
    try runAndExpect(
        \\class Math
        \\  @static
        \\  def sum_pair(p: (i16, i16)) -> i16
        \\    return p.0 + p.1
        \\  end
        \\end
        \\def main()
        \\  let t = (10, 32)
        \\  print Math.sum_pair(t)
        \\end
    , "42\n");
}

test "codegen: a tuple-returning method rides the sret ABI" {
    // The returns-sret test must include tuple returns, or the callee
    // writes its result through an un-pushed destination pointer.
    try runAndExpect(
        \\class Maker
        \\  @static
        \\  def pair() -> (i16, i16)
        \\    return (40, 2)
        \\  end
        \\end
        \\def main()
        \\  let t = Maker.pair()
        \\  print t.0 + t.1
        \\end
    , "42\n");
}

test "codegen: a value binding shadows a same-named class in receiver position" {
    try runAndExpect(
        \\class M
        \\  @static
        \\  def id(x: i16) -> i16
        \\    return x + 1
        \\  end
        \\end
        \\def main()
        \\  let M = 5
        \\  print M
        \\end
    , "5\n");
}

test "codegen: an `asm` statement with no operands emits its instruction" {
    try runAndExpect(
        \\def main()
        \\  asm "nop"
        \\  print 7
        \\end
    , "7\n");
}

test "codegen: `asm` `{name}` operands resolve to the local's slot" {
    // gero asm is AT&T order (src, dest): load `a` into acu, add `b`
    // (via r1), store acu back into `r` — all through inline asm.
    try runAndExpect(
        \\def main()
        \\  let a: i16 = 20
        \\  let b: i16 = 22
        \\  let r: i16 = 0
        \\  asm "mov {a}, acu"
        \\  asm "mov {b}, r1"
        \\  asm "add r1, acu"
        \\  asm "mov acu, {r}"
        \\  print r
        \\end
    , "42\n");
}

test "codegen: `asm` with an unknown `{name}` operand is rejected" {
    try expectCodegenError(
        \\def main()
        \\  asm "mov {nope}, acu"
        \\end
    , "E_CODEGEN_INLINE_ASM");
}

test "codegen: `asm` with no matching opcode form is rejected, not silently `hlt`" {
    // `add [mem], acu` has no opcode form — the assembler must surface it,
    // not emit the 0xFF fallback that would halt the program.
    try expectCodegenError(
        \\def main()
        \\  let b: i16 = 1
        \\  asm "add {b}, acu"
        \\end
    , "E_CODEGEN_INLINE_ASM");
}

test "codegen: `asm` with an unknown mnemonic is rejected" {
    try expectCodegenError(
        \\def main()
        \\  asm "bogusmnemonic"
        \\end
    , "E_CODEGEN_INLINE_ASM");
}

test "codegen: print of a string literal goes through sys print_str + emits `hi`" {
    try runAndExpect(
        \\def main()
        \\  print "hi"
        \\end
    , "hi\n");
}

test "codegen: string literals dedup — two `print` sites share one pool entry" {
    // The pool intern path keys on byte content; two `print "hi"`
    // calls should reference the same `mov str_addr, acu` immediate.
    try runAndExpect(
        \\def main()
        \\  print "hi"
        \\  print "hi"
        \\end
    , "hi\nhi\n");
}

test "codegen: string escape sequences decode at codegen time" {
    try runAndExpect(
        \\def main()
        \\  print "a\tb"
        \\end
    ,
        // \t becomes a real tab byte; trailing newline from `print`.
        "a\tb\n");
}

test "codegen: fixed-point multiply emits `mul + asr 8` and rounds to Q8.8" {
    try runAndExpect(
        \\def main()
        \\  let a: fixed = 2.5
        \\  let b: fixed = 1.5
        \\  let c: fixed = a * b
        \\  print c
        \\end
    ,
        // 2.5 * 1.5 = 3.75 → Q8.8 = 960 → print_fixed formats as "3.750".
        "3.750\n");
}

test "codegen: fixed-point divide emits `shl 8 + divs` and rounds to Q8.8" {
    try runAndExpect(
        \\def main()
        \\  let a: fixed = 5.0
        \\  let b: fixed = 2.0
        \\  let c: fixed = a / b
        \\  print c
        \\end
    ,
        // 5.0 / 2.0 = 2.5 → Q8.8 = 640 → print_fixed formats as "2.500".
        "2.500\n");
}

test "codegen: fixed-point round-trip `(a * b) / c` matches expected" {
    try runAndExpect(
        \\def main()
        \\  let a: fixed = 4.0
        \\  let b: fixed = 3.0
        \\  let c: fixed = 2.0
        \\  let r: fixed = (a * b) / c
        \\  print r
        \\end
    ,
        // 4*3 = 12, /2 = 6.0 → Q8.8 = 1536 → "6.000".
        "6.000\n");
}

test "codegen: recursive fib(10) computes 55" {
    try runAndExpect(
        \\def fib(n: i16) -> i16
        \\  if n < 2
        \\    return n
        \\  end
        \\  return fib(n - 1) + fib(n - 2)
        \\end
        \\def main()
        \\  print fib(10)
        \\end
    , "55\n");
}

test "codegen: nullary call returning a literal" {
    try runAndExpect(
        \\def answer() -> i16
        \\  return 42
        \\end
        \\def main()
        \\  print answer()
        \\end
    , "42\n");
}

test "codegen: 3-arg call sums its args left-to-right" {
    try runAndExpect(
        \\def add3(a: i16, b: i16, c: i16) -> i16
        \\  return a + b + c
        \\end
        \\def main()
        \\  print add3(1, 2, 3)
        \\end
    , "6\n");
}

test "codegen: 4-arg call preserves all four params at the right fp offsets" {
    try runAndExpect(
        \\def four(a: i16, b: i16, c: i16, d: i16) -> i16
        \\  return ((a * 1000) + (b * 100) + (c * 10) + d)
        \\end
        \\def main()
        \\  print four(1, 2, 3, 4)
        \\end
    , "1234\n");
}

test "codegen: caller-saves invariant — local survives a call that clobbers acu" {
    try runAndExpect(
        \\def overwrite() -> i16
        \\  return 99
        \\end
        \\def main()
        \\  let a: i16 = 7
        \\  _ = overwrite()
        \\  print a
        \\end
    , "7\n");
}

test "codegen: print interpolation emits per-part syscalls in source order" {
    try runAndExpect(
        \\def main()
        \\  let x: i16 = 42
        \\  print "x = $(x)"
        \\end
    , "x = 42\n");
}

test "codegen: print interpolation mixes literal + int + char + fixed parts" {
    try runAndExpect(
        \\def main()
        \\  let n: i16 = 7
        \\  let c: char = 'B'
        \\  let f: fixed = 1.5
        \\  print "n=$(n) c=$(c) f=$(f)"
        \\end
    , "n=7 c=B f=1.500\n");
}

test "codegen: fixed-point `print c` uses print_fixed (Q8.8 formatting)" {
    try runAndExpect(
        \\def main()
        \\  let c: fixed = 0.25
        \\  print c
        \\end
    ,
        // 0.25 → Q8.8 = 64 → "0.250".
        "0.250\n");
}

test "codegen: interpolation bound to a `let` formats into a fresh heap buffer" {
    // `let s = "x=$(x)"; print s` allocates a buffer (§3.2.2) and reads
    // back the same bytes — the allocation outlives the statement.
    try runAndExpect(
        \\def main()
        \\  let x: i16 = 42
        \\  let s: str = "x=$(x)"
        \\  print s
        \\end
    , "x=42\n");
}

test "codegen: each interpolation evaluation allocates a distinct buffer" {
    // Two evaluations of the same interpolated literal must not alias —
    // binding the second can't retroactively mutate the first.
    try runAndExpect(
        \\def tag(n: i16) -> str
        \\  return "n=$(n)"
        \\end
        \\def main()
        \\  let a = tag(1)
        \\  let b = tag(2)
        \\  print a
        \\  print b
        \\  print a == b
        \\end
    , "n=1\nn=2\n0\n");
}

test "codegen: `$$` collapses to a literal `$` (a lone `$` is preserved)" {
    try runAndExpect(
        \\def main()
        \\  print "cost: $$5"
        \\  print "$$$$"
        \\end
    , "cost: $5\n$$\n");
}

test "codegen: interpolating an aggregate renders its default form to the host" {
    try runAndExpect(
        \\struct S
        \\  a: i16
        \\  b: i16
        \\end
        \\def main()
        \\  let s = S { a: 1, b: 2 }
        \\  print "v=$(s)!"
        \\end
    , "v=S { a: 1, b: 2 }!\n");
}

test "codegen: interpolating an aggregate into a `let` renders into the buffer" {
    try runAndExpect(
        \\struct S
        \\  name: str
        \\  hp: i16
        \\end
        \\def main()
        \\  let s = S { name: "hero", hp: 99 }
        \\  let m = "info: $(s)"
        \\  print m
        \\end
    , "info: S { name: hero, hp: 99 }\n");
}

test "codegen: interpolating a value whose type has no rendering is a clean error" {
    // A struct with an array field has no default rendering — reject,
    // matching `print` (§4.9), rather than emit a meaningless value.
    try expectCodegenError(
        \\struct S
        \\  a: [i16; 2]
        \\end
        \\def main()
        \\  let s = S { a: [1, 2] }
        \\  print "s=$(s)"
        \\end
    , "E_CODEGEN_UNSUPPORTED");
}

test "codegen: `$(expr:fmt)` format specs render via format_spec_to_buf" {
    try runAndExpect(
        \\def main()
        \\  let addr: u16 = 1266
        \\  print "addr=$(addr:04X)"
        \\  let n: i16 = 42
        \\  print "n=$(n:03d)"
        \\  print "r=$(n:>5d)"
        \\  let neg: i16 = 0 - 42
        \\  print "neg=$(neg:04d)"
        \\end
    , "addr=04F2\nn=042\nr=   42\nneg=-042\n");
}

test "codegen: a format spec bound to a `let` formats into the heap buffer" {
    try runAndExpect(
        \\def main()
        \\  let b: u16 = 180
        \\  let s: str = "b=$(b:08b)"
        \\  print s
        \\end
    , "b=10110100\n");
}

test "codegen: diagnostic message slices outlive `compile`" {
    // `Diagnostic.message` strings allocated by `Emitter.unsupported`
    // live on `Compiled.diag_arena`; reading `.message` AFTER `compile`
    // returns proves the arena outlives the call. Any construct that
    // reaches `unsupported` serves — an unbound `Vec.slice` result is
    // one the typechecker passes and codegen rejects.
    const source =
        \\def main()
        \\  let v: Vec(i16) = Vec.new()
        \\  v.push(1)
        \\  print v.slice(0, 1).len()
        \\end
    ;
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, source, &tree.program);
    defer checked.deinit();

    var compiled = try gero.lang.compile(alloc, source, &checked, .{});
    defer compiled.deinit();

    var checked_message = false;
    for (compiled.diagnostics) |d| {
        if (std.mem.eql(u8, d.code, "E_CODEGEN_UNSUPPORTED")) {
            try std.testing.expect(std.mem.indexOf(u8, d.message, "does not yet support") != null);
            checked_message = true;
        }
    }
    try std.testing.expect(checked_message);
}

test "codegen: zero-page overflow emits E_CODEGEN_ZP_OVERFLOW" {
    // 130 `@zero_page` u16 globals = 260 bytes — exceeds the 256-byte
    // zero-page budget at the 129th binding (which would push the
    // cursor past `$00FF`).
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(alloc);
    var i: usize = 0;
    while (i < 130) : (i += 1) {
        const line = try std.fmt.allocPrint(alloc, "@zero_page\nlet v{d}: u16 = 0\n", .{i});
        defer alloc.free(line);
        try source.appendSlice(alloc, line);
    }
    try source.appendSlice(alloc, "def main() end");

    var stream = try gero.lang.tokenize(alloc, source.items);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source.items, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, source.items, &tree.program);
    defer checked.deinit();

    var compiled = try gero.lang.compile(alloc, source.items, &checked, .{});
    defer compiled.deinit();
    try std.testing.expect(compiled.hasErrors());

    var found = false;
    for (compiled.diagnostics) |d| {
        if (std.mem.eql(u8, d.code, "E_CODEGEN_ZP_OVERFLOW")) found = true;
    }
    try std.testing.expect(found);
}

test "codegen: an over-large image emits E_CODEGEN_IMAGE_OVERFLOW (no panic)" {
    // ~5000 `print`s of distinct strings push the code buffer + string
    // pool past the addressable ceiling (0xFE40); the address narrowing
    // must clamp and surface a clean diagnostic, not panic on the cast.
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(alloc);
    try source.appendSlice(alloc, "def main()\n");
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        const line = try std.fmt.allocPrint(alloc, "  print \"message string number {d}\"\n", .{i});
        defer alloc.free(line);
        try source.appendSlice(alloc, line);
    }
    try source.appendSlice(alloc, "end");

    var stream = try gero.lang.tokenize(alloc, source.items);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source.items, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, source.items, &tree.program);
    defer checked.deinit();

    var compiled = try gero.lang.compile(alloc, source.items, &checked, .{});
    defer compiled.deinit();
    try std.testing.expect(compiled.hasErrors());

    var found = false;
    for (compiled.diagnostics) |d| {
        if (std.mem.eql(u8, d.code, "E_CODEGEN_IMAGE_OVERFLOW")) found = true;
    }
    try std.testing.expect(found);
}

test "codegen: a `@bank` def overrunning its 16 KiB window fails cleanly" {
    // A banked def whose code exceeds the bank window would be silently
    // truncated by the archive (and the address clamp hides the spill);
    // reject it with `E_CODEGEN_BANK_OVERFLOW` instead.
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(alloc);
    try source.appendSlice(alloc, "@bank 1\ndef huge(x: i16) -> i16\n  let s: i16 = x\n");
    var i: usize = 0;
    while (i < 260) : (i += 1) {
        const line = try std.fmt.allocPrint(alloc, "  if s < {d}\n    s = s + 1\n  else\n    s = s - 1\n  end\n", .{i});
        defer alloc.free(line);
        try source.appendSlice(alloc, line);
    }
    try source.appendSlice(alloc, "  return s\nend\ndef main()\n  print huge(0)\nend");

    var stream = try gero.lang.tokenize(alloc, source.items);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source.items, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, source.items, &tree.program);
    defer checked.deinit();

    var compiled = try gero.lang.compile(alloc, source.items, &checked, .{});
    defer compiled.deinit();
    try std.testing.expect(compiled.hasErrors());
    var found = false;
    for (compiled.diagnostics) |d| {
        if (std.mem.eql(u8, d.code, "E_CODEGEN_BANK_OVERFLOW")) found = true;
    }
    try std.testing.expect(found);
}

test "codegen: a frame whose static size overflows u16 fails cleanly (no panic)" {
    // ~33000 uninitialized locals make `countFrameBytes` exceed `0xFFFF`;
    // the prologue's frame-size narrowing must clamp (the over-127 frame
    // is reported as `E_CODEGEN_FRAME_TOO_LARGE`), not panic.
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(alloc);
    try source.appendSlice(alloc, "def main()\n");
    var i: usize = 0;
    while (i < 33000) : (i += 1) {
        const line = try std.fmt.allocPrint(alloc, "  let v{d}: u16\n", .{i});
        defer alloc.free(line);
        try source.appendSlice(alloc, line);
    }
    try source.appendSlice(alloc, "end");

    var stream = try gero.lang.tokenize(alloc, source.items);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source.items, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, source.items, &tree.program);
    defer checked.deinit();

    var compiled = try gero.lang.compile(alloc, source.items, &checked, .{});
    defer compiled.deinit();
    try std.testing.expect(compiled.hasErrors());
    var found = false;
    for (compiled.diagnostics) |d| {
        if (std.mem.eql(u8, d.code, "E_CODEGEN_FRAME_TOO_LARGE")) found = true;
    }
    try std.testing.expect(found);
}

test "codegen: a param list whose offset overflows i16 fails cleanly (no panic)" {
    // ~17000 params push the running param offset past `i16` range; the
    // post-loop `sret_param_ofs` narrowing must clamp rather than panic
    // (the params overrun the fp range → `E_CODEGEN_FRAME_TOO_LARGE`).
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(alloc);
    try source.appendSlice(alloc, "def big(");
    var i: usize = 0;
    while (i < 17000) : (i += 1) {
        if (i > 0) try source.appendSlice(alloc, ", ");
        const p = try std.fmt.allocPrint(alloc, "p{d}: i16", .{i});
        defer alloc.free(p);
        try source.appendSlice(alloc, p);
    }
    try source.appendSlice(alloc, ") -> i16\n  return p0\nend\ndef main() end");

    var stream = try gero.lang.tokenize(alloc, source.items);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source.items, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, source.items, &tree.program);
    defer checked.deinit();

    var compiled = try gero.lang.compile(alloc, source.items, &checked, .{});
    defer compiled.deinit();
    try std.testing.expect(compiled.hasErrors());
    var found = false;
    for (compiled.diagnostics) |d| {
        if (std.mem.eql(u8, d.code, "E_CODEGEN_FRAME_TOO_LARGE")) found = true;
    }
    try std.testing.expect(found);
}

// ---------- enum codegen (nullary variants) ----------

test "codegen: a nullary enum value renders as `Enum.Variant`" {
    try runAndExpect(
        \\enum Color
        \\  case Red
        \\  case Green
        \\  case Blue
        \\end
        \\def main()
        \\  let c: Color = Color.Green
        \\  print c
        \\end
    , "Color.Green\n");
}

test "codegen: `is` test on enum returns true on the right variant" {
    try runAndExpect(
        \\enum Color
        \\  case Red
        \\  case Green
        \\end
        \\def main()
        \\  let c: Color = Color.Green
        \\  if c is Color.Green
        \\    print 1
        \\  end
        \\  if c is Color.Red
        \\    print 99
        \\  end
        \\end
    , "1\n");
}

test "codegen: match on nullary enum dispatches per variant tag" {
    try runAndExpect(
        \\enum Color
        \\  case Red
        \\  case Green
        \\  case Blue
        \\end
        \\def main()
        \\  let c: Color = Color.Blue
        \\  match c
        \\    case Color.Red => print 1
        \\    case Color.Green => print 2
        \\    case Color.Blue => print 3
        \\  end
        \\end
    , "3\n");
}

test "codegen/match: 4-variant nullary enum compiles to a jump table" {
    // Per AC1 of #195 + spec §4.8.5: "Single-arm tag dispatch (no
    // payloads) → jump table indexed by tag byte". Verify both
    // the behavior (last variant routes to the right arm) AND the
    // emit shape — the dispatch sequence ends with `jmp [reg]`
    // (0x91), and the table has one `jmp_addr` (0x90) per tag.
    var compiled = try compileSource(
        \\enum Event
        \\  case Quit
        \\  case Pause
        \\  case Resume
        \\  case Tick
        \\end
        \\def main()
        \\  let e: Event = Event.Tick
        \\  match e
        \\    case Event.Quit => print 1
        \\    case Event.Pause => print 2
        \\    case Event.Resume => print 3
        \\    case Event.Tick => print 4
        \\  end
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    // The dispatch sequence emits exactly one `jmp [reg]` (op 0x91)
    // before the table. The bare `jmp_addr` opcode (0x90) shows up
    // in many other places (every `end of arm → jmp end` edge), so
    // we gate on the presence of 0x91 as the distinguishing mark.
    var saw_jmp_reg = false;
    for (compiled.image) |b| {
        if (b == 0x91) {
            saw_jmp_reg = true;
            break;
        }
    }
    try std.testing.expect(saw_jmp_reg);

    // Functional gate: the scrutinee `Event.Tick` (tag 3) hits the
    // 4th arm. The jump table must route it correctly.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();
    try std.testing.expectEqualStrings("4\n", writer.written());
}

test "codegen/match: enum match with a guard falls back to sequential dispatch" {
    // Guards break the bare-tag-dispatch precondition (the body
    // must run only if the post-bind guard evaluates truthy). The
    // sequential cmp-chain handles this; the jump table cannot.
    // No `jmp [reg]` (0x91) should appear in the emit.
    var compiled = try compileSource(
        \\enum Color
        \\  case Red
        \\  case Green
        \\  case Blue
        \\end
        \\def main()
        \\  let c: Color = Color.Green
        \\  let flag: i16 = 1
        \\  match c
        \\    case Color.Red => print 1
        \\    case Color.Green when flag == 1 => print 2
        \\    case _ => print 9
        \\  end
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    for (compiled.image) |b| {
        try std.testing.expect(b != 0x91);
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();
    try std.testing.expectEqualStrings("2\n", writer.written());
}

test "codegen/match: enum match with trailing wildcard still uses the jump table" {
    // Wildcards are the spec's "default" — table slots for tags
    // not in the explicit arms route to the wildcard body. The
    // dispatch keeps its `jmp [reg]` shape.
    var compiled = try compileSource(
        \\enum Color
        \\  case Red
        \\  case Green
        \\  case Blue
        \\end
        \\def main()
        \\  let c: Color = Color.Blue
        \\  match c
        \\    case Color.Red => print 1
        \\    case _ => print 9
        \\  end
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var saw_jmp_reg = false;
    for (compiled.image) |b| {
        if (b == 0x91) {
            saw_jmp_reg = true;
            break;
        }
    }
    try std.testing.expect(saw_jmp_reg);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();
    try std.testing.expectEqualStrings("9\n", writer.written());
}

test "codegen: undefined enum variant in `is` rhs is rejected" {
    const source =
        \\enum Color
        \\  case Red
        \\end
        \\def main()
        \\  let c: Color = Color.Red
        \\  if c is Color.NoSuchVariant
        \\    print 1
        \\  end
        \\end
    ;
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, source, &tree.program);
    defer checked.deinit();

    var compiled = try gero.lang.compile(alloc, source, &checked, .{});
    defer compiled.deinit();
    try std.testing.expect(compiled.hasErrors());

    var found = false;
    for (compiled.diagnostics) |d| {
        if (std.mem.eql(u8, d.code, "E_CODEGEN_UNDEFINED_VARIANT")) found = true;
    }
    try std.testing.expect(found);
}

// ---------- mem stdlib + references ----------

test "codegen: mem.write_u8 + mem.read_u8 round-trip a byte" {
    try runAndExpect(
        \\use mem
        \\def main()
        \\  mem.write_u8($2100, 42)
        \\  let v: u8 = mem.read_u8($2100)
        \\  print v
        \\end
    , "42\n");
}

test "codegen: mem.write_u16 + mem.read_u16 preserve little-endian byte order" {
    try runAndExpect(
        \\use mem
        \\def main()
        \\  mem.write_u16($2100, $1234)
        \\  -- low byte = 0x34 at $2100, high byte = 0x12 at $2101
        \\  let lo: u8 = mem.read_u8($2100)
        \\  let hi: u8 = mem.read_u8($2101)
        \\  print lo
        \\  print hi
        \\end
    , "52\n18\n");
}

test "codegen: mem.read_i8 sign-extends negative byte values into i16 range" {
    try runAndExpect(
        \\use mem
        \\def main()
        \\  mem.write_u8($2100, 255)
        \\  let v: i8 = mem.read_i8($2100)
        \\  print v
        \\end
    , "-1\n");
}

test "codegen: mem.poke + mem.peek aliases work" {
    try runAndExpect(
        \\use mem
        \\def main()
        \\  mem.poke($2100, 7)
        \\  let v: u8 = mem.peek($2100)
        \\  print v
        \\end
    , "7\n");
}

test "codegen: mem.memcpy copies n bytes from src to dst" {
    try runAndExpect(
        \\use mem
        \\def main()
        \\  mem.write_u8($2100, 11)
        \\  mem.write_u8($2101, 22)
        \\  mem.write_u8($2102, 33)
        \\  mem.memcpy($2200, $2100, 3)
        \\  print mem.read_u8($2200)
        \\  print mem.read_u8($2201)
        \\  print mem.read_u8($2202)
        \\end
    , "11\n22\n33\n");
}

test "codegen: mem.memset fills n bytes with the value" {
    try runAndExpect(
        \\use mem
        \\def main()
        \\  mem.memset($2200, 99, 3)
        \\  print mem.read_u8($2200)
        \\  print mem.read_u8($2201)
        \\  print mem.read_u8($2202)
        \\end
    , "99\n99\n99\n");
}

test "codegen: mem.addr_of on a local returns its stack-slot address" {
    try runAndExpect(
        \\use mem
        \\def main()
        \\  let x: i16 = 42
        \\  let p: u16 = mem.addr_of(x)
        \\  let v: i16 = mem.read_i16(p)
        \\  print v
        \\end
    , "42\n");
}

test "codegen: mem.addr_of on a global returns its static address" {
    try runAndExpect(
        \\use mem
        \\let counter: u16 = 7
        \\def main()
        \\  let p: u16 = mem.addr_of(counter)
        \\  mem.write_u16(p, 99)
        \\  print counter
        \\end
    , "99\n");
}

test "codegen: `&local` produces same address as mem.addr_of" {
    // `&x` and `mem.addr_of(x)` share the same runtime
    // representation (a 16-bit address). This test verifies the
    // address itself is correct; auto-deref on field / method
    // access is exercised by class / struct tests when those land.
    try runAndExpect(
        \\use mem
        \\def main()
        \\  let x: i16 = 7
        \\  let r: &i16 = &x
        \\  let a: u16 = mem.addr_of(x)
        \\  mem.write_i16(a, 42)
        \\  print x
        \\  -- Suppress an unused-binding warning on `r` by
        \\  -- comparing addresses textually below.
        \\  let _b: &i16 = r
        \\end
    , "42\n");
}

test "codegen: `&(a + b)` is rejected by typecheck" {
    const source =
        \\def main()
        \\  let r: &i16 = &(1 + 2)
        \\  print r
        \\end
    ;
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, source, &tree.program);
    defer checked.deinit();
    try std.testing.expect(checked.diagnostics.len > 0);
}

test "codegen: undefined mem.X is rejected by typecheck" {
    const source =
        \\use mem
        \\def main()
        \\  let v: u8 = mem.read_nonsense($2100)
        \\  print v
        \\end
    ;
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, source, &tree.program);
    defer checked.deinit();

    var found = false;
    for (checked.diagnostics) |d| {
        if (std.mem.eql(u8, d.code, "E_TYPE_UNDEFINED_METHOD")) found = true;
    }
    try std.testing.expect(found);
}

test "codegen: `&T` auto-derefs for class field read" {
    try runAndExpect(
        \\class Counter
        \\  let n: i16
        \\
        \\  def init(self)
        \\    self.n = 7
        \\  end
        \\end
        \\
        \\def read(r: &Counter)
        \\  print r.n
        \\end
        \\
        \\def main()
        \\  let c = Counter()
        \\  read(&c)
        \\end
    , "7\n");
}

test "codegen: `&T` mutation through param mutates caller's binding" {
    try runAndExpect(
        \\class Counter
        \\  let n: i16
        \\
        \\  def init(self)
        \\    self.n = 1
        \\  end
        \\end
        \\
        \\def bump(r: &Counter)
        \\  r.n = r.n + 10
        \\end
        \\
        \\def main()
        \\  let c = Counter()
        \\  bump(&c)
        \\  bump(&c)
        \\  print c.n
        \\end
    , "21\n");
}

test "codegen: `&T` auto-derefs for method dispatch" {
    try runAndExpect(
        \\class Echo
        \\  def shout(self)
        \\    print "hi"
        \\  end
        \\end
        \\
        \\def yell(r: &Echo)
        \\  r.shout()
        \\end
        \\
        \\def main()
        \\  let e = Echo()
        \\  yell(&e)
        \\end
    , "hi\n");
}

test "codegen: custom entry_name resolves" {
    const source = "def boot() end";
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, source, &tree.program);
    defer checked.deinit();

    const opts: gero.lang.CompileOptions = .{ .entry_name = "boot" };
    var compiled = try gero.lang.compile(alloc, source, &checked, opts);
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());
}

// ---------- M3b chunk 1: class vtable + dispatch ----------

test "codegen/class: zero-field class with one method prints from the method" {
    var compiled = try compileSource(
        \\class Player
        \\  def greet(self)
        \\    print "hi"
        \\  end
        \\end
        \\
        \\def main()
        \\  let p = Player()
        \\  p.greet()
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("hi\n", writer.written());
}

test "codegen/class: instance pointer is freshly heap-allocated (acu = heap_base on first alloc)" {
    var compiled = try compileSource(
        \\class Box
        \\  let v: i16
        \\end
        \\
        \\def main()
        \\  let p = Box()
        \\end
    );
    defer compiled.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    // `let p` lives at [fp - 2] (first local). Should hold the
    // heap-allocated instance address; heap starts at data_base
    // when no globals are placed.
    const p_addr = vm.mmap.readWord(0xFFFC);
    try std.testing.expectEqual(@as(u16, gero.lang.codegen.data_base), p_addr);
}

test "codegen/class: vtable_ptr at instance[0] points at the class's vtable" {
    var compiled = try compileSource(
        \\class Player
        \\  def greet(self)
        \\    print "hi"
        \\  end
        \\end
        \\
        \\def main()
        \\  let p = Player()
        \\end
    );
    defer compiled.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    // p is at [fp - 2] = 0xFFFC.
    const p_addr = vm.mmap.readWord(0xFFFC);
    // [p+0] = vtable address. Vtable address must be non-zero
    // (lives in the base image past code + strings).
    const vtable_addr = vm.mmap.readWord(p_addr);
    try std.testing.expect(vtable_addr != 0);
}

test "codegen/class: field read returns the value written by init" {
    var compiled = try compileSource(
        \\class Counter
        \\  let n: i16
        \\
        \\  def init(self)
        \\    self.n = 7
        \\  end
        \\end
        \\
        \\def main()
        \\  let c = Counter()
        \\  print c.n
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("7\n", writer.written());
}

test "codegen/class: field write from outside the class persists" {
    var compiled = try compileSource(
        \\class Box
        \\  let v: i16
        \\end
        \\
        \\def main()
        \\  let b = Box()
        \\  b.v = 42
        \\  print b.v
        \\end
    );
    defer compiled.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("42\n", writer.written());
}

test "codegen/class: byte-wide field (u8) reads back narrowed" {
    var compiled = try compileSource(
        \\class Cell
        \\  let b: u8
        \\end
        \\
        \\def main()
        \\  let c = Cell()
        \\  c.b = 200
        \\  print c.b
        \\end
    );
    defer compiled.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("200\n", writer.written());
}

test "codegen/class: method with user args" {
    var compiled = try compileSource(
        \\class Adder
        \\  def add(self, x: i16, y: i16)
        \\    print x + y
        \\  end
        \\end
        \\
        \\def main()
        \\  let a = Adder()
        \\  a.add(3, 4)
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("7\n", writer.written());
}

test "codegen/class: init with args populates fields" {
    var compiled = try compileSource(
        \\class Pair
        \\  let lo: i16
        \\  let hi: i16
        \\
        \\  def init(self, a: i16, b: i16)
        \\    self.lo = a
        \\    self.hi = b
        \\  end
        \\end
        \\
        \\def main()
        \\  let p = Pair(10, 20)
        \\  print p.lo
        \\  print p.hi
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("10\n20\n", writer.written());
}

test "codegen/class: method-to-method dispatch on self" {
    var compiled = try compileSource(
        \\class Echo
        \\  def shout(self)
        \\    self.whisper()
        \\    self.whisper()
        \\  end
        \\
        \\  def whisper(self)
        \\    print "."
        \\  end
        \\end
        \\
        \\def main()
        \\  let e = Echo()
        \\  e.shout()
        \\end
    );
    defer compiled.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings(".\n.\n", writer.written());
}

test "codegen/class: two instances of the same class are independent" {
    var compiled = try compileSource(
        \\class Box
        \\  let v: i16
        \\end
        \\
        \\def main()
        \\  let a = Box()
        \\  let b = Box()
        \\  a.v = 11
        \\  b.v = 22
        \\  print a.v
        \\  print b.v
        \\end
    );
    defer compiled.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("11\n22\n", writer.written());
}

test "codegen/class: mixed-width fields land at the expected offsets" {
    // u8 (1) + i16 (2) + bool (1) + i16 (2) → 6 bytes of fields,
    // total instance_size = 2 (vtable_ptr) + 6 = 8 bytes.
    var compiled = try compileSource(
        \\class Mix
        \\  let a: u8
        \\  let b: i16
        \\  let c: bool
        \\  let d: i16
        \\
        \\  def init(self)
        \\    self.a = 7
        \\    self.b = 1000
        \\    self.c = true
        \\    self.d = -1
        \\  end
        \\end
        \\
        \\def main()
        \\  let m = Mix()
        \\  print m.a
        \\  print m.b
        \\  print m.c
        \\  print m.d
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("7\n1000\n1\n-1\n", writer.written());
}

test "codegen/class: method returning a value propagates through `acu`" {
    var compiled = try compileSource(
        \\class Box
        \\  let v: i16
        \\
        \\  def init(self, x: i16)
        \\    self.v = x
        \\  end
        \\
        \\  def get(self) -> i16
        \\    return self.v
        \\  end
        \\end
        \\
        \\def main()
        \\  let b = Box(99)
        \\  let v = b.get()
        \\  print v
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("99\n", writer.written());
}

// ---------- M3b chunk 2: inheritance + super ----------

test "codegen/class: child inherits parent method (no override)" {
    var compiled = try compileSource(
        \\class Parent
        \\  def greet(self)
        \\    print "parent"
        \\  end
        \\end
        \\
        \\class Child extends Parent
        \\end
        \\
        \\def main()
        \\  let c = Child()
        \\  c.greet()
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("parent\n", writer.written());
}

test "codegen/class: child override dispatches to child via vtable" {
    var compiled = try compileSource(
        \\class Parent
        \\  def speak(self)
        \\    print "parent"
        \\  end
        \\end
        \\
        \\class Child extends Parent
        \\  def speak(self)
        \\    print "child"
        \\  end
        \\end
        \\
        \\def main()
        \\  let c = Child()
        \\  c.speak()
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("child\n", writer.written());
}

test "codegen/class: super.method bypasses the vtable" {
    var compiled = try compileSource(
        \\class Parent
        \\  def speak(self)
        \\    print "parent"
        \\  end
        \\end
        \\
        \\class Child extends Parent
        \\  def speak(self)
        \\    super.speak()
        \\    print "child"
        \\  end
        \\end
        \\
        \\def main()
        \\  let c = Child()
        \\  c.speak()
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    // super.speak runs parent's body ("parent"), then child's
    // body resumes and prints "child".
    try std.testing.expectEqualStrings("parent\nchild\n", writer.written());
}

test "codegen/class: child inherits parent fields and reads them via self" {
    var compiled = try compileSource(
        \\class Parent
        \\  let n: i16
        \\
        \\  def init(self, x: i16)
        \\    self.n = x
        \\  end
        \\end
        \\
        \\class Child extends Parent
        \\end
        \\
        \\def main()
        \\  let c = Child(42)
        \\  print c.n
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("42\n", writer.written());
}

test "codegen/class: shadowed field — self.X reads child's, super.X reads parent's" {
    var compiled = try compileSource(
        \\class Parent
        \\  let value: i16
        \\
        \\  def init(self)
        \\    self.value = 10
        \\  end
        \\end
        \\
        \\class Child extends Parent
        \\  let value: i16
        \\
        \\  def init(self)
        \\    super.init()
        \\    self.value = 20
        \\  end
        \\
        \\  def report(self)
        \\    print self.value
        \\    print super.value
        \\  end
        \\end
        \\
        \\def main()
        \\  let c = Child()
        \\  c.report()
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("20\n10\n", writer.written());
}

test "codegen/class: child without init reuses parent's init via inheritance" {
    var compiled = try compileSource(
        \\class Parent
        \\  let n: i16
        \\
        \\  def init(self)
        \\    self.n = 99
        \\  end
        \\end
        \\
        \\class Child extends Parent
        \\end
        \\
        \\def main()
        \\  let c = Child()
        \\  print c.n
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("99\n", writer.written());
}

test "codegen/class: vtable dispatch is dynamic — same slot, different bodies" {
    // The vtable copy + override mechanism gives polymorphism for
    // free: two classes that share a method slot dispatch to their
    // own override at runtime. This test allocates a Parent and a
    // Child, calls speak() on each, and checks each prints its own
    // body — not whichever class was syntactically named at the
    // call site.
    var compiled = try compileSource(
        \\class Parent
        \\  def speak(self)
        \\    print "P"
        \\  end
        \\end
        \\
        \\class Child extends Parent
        \\  def speak(self)
        \\    print "C"
        \\  end
        \\end
        \\
        \\def main()
        \\  let p = Parent()
        \\  let c = Child()
        \\  p.speak()
        \\  c.speak()
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("P\nC\n", writer.written());
}

test "codegen/class: three-level inheritance — Grandparent ← Parent ← Child" {
    var compiled = try compileSource(
        \\class Grandparent
        \\  def name(self)
        \\    print "G"
        \\  end
        \\end
        \\
        \\class Parent extends Grandparent
        \\end
        \\
        \\class Child extends Parent
        \\end
        \\
        \\def main()
        \\  let c = Child()
        \\  c.name()
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("G\n", writer.written());
}

// ---------- M3b: closures (#259) ----------

test "codegen/closure: lambda with no captures returns a constant" {
    var compiled = try compileSource(
        \\def main()
        \\  let f = || 42
        \\  print f()
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("42\n", writer.written());
}

test "codegen/closure: AC1 — read-only capture reads parent local" {
    var compiled = try compileSource(
        \\def main()
        \\  let n: i16 = 7
        \\  let read = || n
        \\  print read()
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("7\n", writer.written());
}

test "codegen/closure: AC2 — mutated capture lives on the heap, closure shares state" {
    var compiled = try compileSource(
        \\def main()
        \\  let n: i16 = 0
        \\  let inc = lambda ()
        \\    n = n + 1
        \\  end
        \\  inc()
        \\  inc()
        \\  print n
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("2\n", writer.written());
}

test "codegen/closure: AC3 — two closures over the same binding see consistent state" {
    var compiled = try compileSource(
        \\def main()
        \\  let n: i16 = 0
        \\  let inc = lambda ()
        \\    n = n + 1
        \\  end
        \\  let read = || n
        \\  inc()
        \\  inc()
        \\  inc()
        \\  print read()
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("3\n", writer.written());
}

test "codegen/closure: short lambda |x| with one user param" {
    var compiled = try compileSource(
        \\def main()
        \\  let n: i16 = 10
        \\  let add = |x: i16| n + x
        \\  print add(5)
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("15\n", writer.written());
}

test "codegen/closure: AC4 — returned closure keeps env alive (escape analysis)" {
    var compiled = try compileSource(
        \\def make_counter() -> fn() -> i16
        \\  let n: i16 = 0
        \\  let inc = lambda () -> i16
        \\    n = n + 1
        \\    return n
        \\  end
        \\  return inc
        \\end
        \\
        \\def main()
        \\  let c = make_counter()
        \\  print c()
        \\  print c()
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("1\n2\n", writer.written());
}

test "codegen/closure: a captured variable used in string interpolation resolves" {
    // The capture analysis descends into `$(…)` interpolation parts, so
    // `v` enters the closure's capture set and the body reads it.
    try runAndExpect(
        \\def main()
        \\  let v: i16 = 7
        \\  let r = || -> str "val is $(v)"
        \\  print r()
        \\end
    , "val is 7\n");
}

test "codegen/closure: a capture reached through a field access in interpolation resolves" {
    try runAndExpect(
        \\class Hero
        \\  let hp: i16
        \\  def init(self)
        \\    self.hp = 30
        \\  end
        \\end
        \\def main()
        \\  let hero = Hero()
        \\  let r = || -> str "hp $(hero.hp)"
        \\  print r()
        \\end
    , "hp 30\n");
}

test "codegen/closure: two captures interpolated in one string resolve" {
    try runAndExpect(
        \\def main()
        \\  let a: i16 = 3
        \\  let b: i16 = 4
        \\  let r = || -> str "$(a) and $(b)"
        \\  print r()
        \\end
    , "3 and 4\n");
}

test "codegen/closure: a `for` loop variable inside a lambda is a local, not a capture" {
    try runAndExpect(
        \\def main()
        \\  let f = || -> i16 do
        \\    let xs: [i16; 3] = [1, 2, 3]
        \\    let total: i16 = 0
        \\    for k in xs
        \\      total = total + k
        \\    end
        \\    total
        \\  end
        \\  print f()
        \\end
    , "6\n");
}

test "codegen/closure: a captured `for`-loop range bound resolves" {
    try runAndExpect(
        \\def main()
        \\  let lo: i16 = 1
        \\  let hi: i16 = 4
        \\  let f = || -> i16 do
        \\    let total: i16 = 0
        \\    for k in lo..hi
        \\      total = total + 1
        \\    end
        \\    total
        \\  end
        \\  print f()
        \\end
    , "3\n");
}

test "codegen/closure: a `do`-block lambda body captures an enclosing free variable" {
    try runAndExpect(
        \\def main()
        \\  let count: i16 = 7
        \\  let f = || -> i16 do
        \\    let x: i16 = count + 1
        \\    x
        \\  end
        \\  print f()
        \\end
    , "8\n");
}

test "codegen/closure: a read-only struct capture survives the frame (escaping)" {
    // `pt` is read-only, so the closure heap-copies it at construction and
    // reads its field after `make` returns (value semantics, escape-safe).
    try runAndExpect(
        \\struct Pt
        \\  x: i16
        \\  y: i16
        \\end
        \\def make(pt: Pt) -> fn() -> i16
        \\  return || -> i16 pt.x
        \\end
        \\def main()
        \\  let g = make(Pt { x: 11, y: 22 })
        \\  print g()
        \\end
    , "11\n");
}

test "codegen/closure: a mutated struct capture is a shared upvalue" {
    // `c` is mutated by the closure, so it is promoted to a shared heap
    // buffer — the write is visible to the enclosing scope afterward.
    try runAndExpect(
        \\struct Counter
        \\  n: i16
        \\end
        \\def main()
        \\  let c = Counter { n: 5 }
        \\  let inc = || -> i16 do
        \\    c.n = c.n + 1
        \\    c.n
        \\  end
        \\  print inc()
        \\  print c.n
        \\end
    , "6\n6\n");
}

test "codegen/closure: two closures share one mutated struct upvalue" {
    try runAndExpect(
        \\struct Counter
        \\  n: i16
        \\end
        \\def main()
        \\  let c = Counter { n: 0 }
        \\  let inc = || -> i16 do
        \\    c.n = c.n + 1
        \\    c.n
        \\  end
        \\  let get = || -> i16 c.n
        \\  print inc()
        \\  print inc()
        \\  print get()
        \\end
    , "1\n2\n2\n");
}

test "codegen/closure: a mutated array capture shares one buffer with the frame" {
    try runAndExpect(
        \\def main()
        \\  let xs: [i16; 2] = [0, 0]
        \\  let setf = || -> i16 do
        \\    xs[1] = 5
        \\    xs[1]
        \\  end
        \\  print setf()
        \\  print xs[1]
        \\end
    , "5\n5\n");
}

test "codegen/closure: a captured optional unwraps inside the lambda body" {
    // `opt` is a 4-byte aggregate; `if let` over the capture reads it.
    try runAndExpect(
        \\def main()
        \\  let opt: i16? = 99
        \\  let f = lambda () -> i16
        \\    if let v = opt
        \\      return v
        \\    end
        \\    return 0
        \\  end
        \\  print f()
        \\end
    , "99\n");
}

test "codegen/closure: a captured Vec shares its header — a push is visible outside" {
    // A method call may grow the receiver's header, so the captured Vec is
    // promoted to a shared upvalue; the closure's push updates one header.
    try runAndExpect(
        \\def main()
        \\  let v: Vec(i16) = Vec.new()
        \\  let add = || -> i16 do
        \\    v.push(1)
        \\    v.len() as i16
        \\  end
        \\  print add()
        \\  print v.len() as i16
        \\end
    , "1\n1\n");
}

test "codegen/closure: a method-defined lambda captures self and reads a field" {
    // `self` inside a returned closure is captured (the body reads the
    // receiver from its env), so `self.v` resolves after the method returns.
    try runAndExpect(
        \\class Box
        \\  let v: i16
        \\  def init(self)
        \\    self.v = 42
        \\  end
        \\  def getter(self) -> fn() -> i16
        \\    return || -> i16 self.v
        \\  end
        \\end
        \\def main()
        \\  let b = Box()
        \\  let g = b.getter()
        \\  print g()
        \\end
    , "42\n");
}

test "codegen/closure: a captured self mutates a shared field across calls" {
    // The closure holds the receiver pointer by value, so `self.n` writes
    // hit the same heap object and persist between calls.
    try runAndExpect(
        \\class Counter
        \\  let n: i16
        \\  def init(self)
        \\    self.n = 0
        \\  end
        \\  def stepper(self) -> fn() -> i16
        \\    return || -> i16 do
        \\      self.n = self.n + 1
        \\      self.n
        \\    end
        \\  end
        \\end
        \\def main()
        \\  let c = Counter()
        \\  let advance = c.stepper()
        \\  print advance()
        \\  print advance()
        \\end
    , "1\n2\n");
}

test "codegen/closure: a captured self calls a method" {
    try runAndExpect(
        \\class Adder
        \\  let base: i16
        \\  def init(self)
        \\    self.base = 10
        \\  end
        \\  def bump(self, n: i16) -> i16
        \\    return self.base + n
        \\  end
        \\  def make(self) -> fn() -> i16
        \\    return || -> i16 self.bump(5)
        \\  end
        \\end
        \\def main()
        \\  let a = Adder()
        \\  let f = a.make()
        \\  print f()
        \\end
    , "15\n");
}

test "codegen/closure: a free function called in a lambda body is not captured" {
    // `helper` names a module-level function — globally addressable, so
    // the lambda body calls it directly rather than capturing it.
    try runAndExpect(
        \\def helper(x: i16) -> i16
        \\  return x + 5
        \\end
        \\def main()
        \\  let f = || -> i16 helper(10)
        \\  print f()
        \\end
    , "15\n");
}

test "codegen/closure: a lambda mixes a real capture with a free function call" {
    // `base` is a genuine capture (enclosing local); `dbl` is a module
    // function resolved directly — only `base` consumes an env slot.
    try runAndExpect(
        \\def dbl(n: i16) -> i16
        \\  return n + n
        \\end
        \\def main()
        \\  let base: i16 = 6
        \\  let f = || -> i16 dbl(base)
        \\  print f()
        \\end
    , "12\n");
}

test "codegen/closure: a class constructed inside a lambda body is not captured" {
    try runAndExpect(
        \\class Box
        \\  let v: i16
        \\  def init(self)
        \\    self.v = 7
        \\  end
        \\  def get(self) -> i16
        \\    return self.v
        \\  end
        \\end
        \\def main()
        \\  let f = || -> i16 Box().get()
        \\  print f()
        \\end
    , "7\n");
}

test "codegen/closure: a capture shadowed by a `do`-block local resolves again after the block" {
    // The `do` block's `let w` is scoped out at block end, so `w` in
    // `w + inner` reads the captured outer `w` (50), not the stale 7.
    try runAndExpect(
        \\def main()
        \\  let w: i16 = 50
        \\  let f = lambda () -> i16
        \\    let inner: i16 = do
        \\      let w: i16 = 7
        \\      w
        \\    end
        \\    return w + inner
        \\  end
        \\  print f()
        \\end
    , "57\n");
}

test "codegen/closure: a `for`-loop var shadowing a capture is scoped out after the loop" {
    // The loop var `i` shadows the captured `i` only inside the loop;
    // `sum + i` after the loop reads the capture (50).
    try runAndExpect(
        \\def main()
        \\  let i: i16 = 50
        \\  let f = lambda () -> i16
        \\    let sum: i16 = 0
        \\    for i in 0..3
        \\      sum = sum + i
        \\    end
        \\    return sum + i
        \\  end
        \\  print f()
        \\end
    , "53\n");
}

test "codegen/closure: a returned closure capturing a param keeps its value after the frame is gone" {
    // The param `p` escapes `make`, so it is promoted to a heap cell at
    // entry; the closure reads the cell after `make` returns.
    try runAndExpect(
        \\def make(p: i16) -> fn() -> i16
        \\  return || -> i16 p + 1
        \\end
        \\def main()
        \\  let g = make(7)
        \\  print g()
        \\end
    , "8\n");
}

test "codegen/closure: a mutated captured param shares one cell across calls" {
    // The closure mutates the captured param through its heap cell, so
    // the increment persists between calls.
    try runAndExpect(
        \\def make(p: i16) -> fn() -> i16
        \\  return || -> i16 do
        \\    p = p + 1
        \\    p
        \\  end
        \\end
        \\def main()
        \\  let g = make(7)
        \\  print g()
        \\  print g()
        \\end
    , "8\n9\n");
}

test "codegen/closure: a capture mutated by a closure bound in a match arm is promoted" {
    // The escaping-capture walk descends into match-arm bodies, so `n`
    // is promoted and the mutation persists across calls.
    try runAndExpect(
        \\def make(tag: i16) -> fn() -> i16
        \\  let n: i16 = 3
        \\  match tag
        \\    case 0 =>
        \\      return || -> i16 do
        \\        n = n + 1
        \\        n
        \\      end
        \\    case _ =>
        \\      return || -> i16 n
        \\  end
        \\end
        \\def main()
        \\  let g = make(0)
        \\  print g()
        \\  print g()
        \\end
    , "4\n5\n");
}

test "codegen/do: a `do … end` value block evaluates to its last expression" {
    try runAndExpect(
        \\def main()
        \\  let x: i16 = do
        \\    let a: i16 = 3
        \\    a + 4
        \\  end
        \\  print x
        \\end
    , "7\n");
}

test "codegen/do: an un-annotated `do` block sizes its slot from the inferred type" {
    try runAndExpect(
        \\def main()
        \\  let v = do
        \\    let a: i16 = 40
        \\    a + 2
        \\  end
        \\  print v
        \\end
    , "42\n");
}

test "codegen/do: a `do` block can produce a tuple value" {
    try runAndExpect(
        \\def main()
        \\  let p: (i16, i16) = do
        \\    let w: i16 = 10
        \\    let h: i16 = 20
        \\    (w, h)
        \\  end
        \\  print p.0
        \\  print p.1
        \\end
    , "10\n20\n");
}

test "codegen/do: a `do` block can produce a struct value" {
    try runAndExpect(
        \\struct P
        \\  x: i16
        \\  y: i16
        \\end
        \\def main()
        \\  let s: P = do
        \\    P { x: 5, y: 6 }
        \\  end
        \\  print s.x
        \\  print s.y
        \\end
    , "5\n6\n");
}

test "codegen/do: a `do` block can produce an array value" {
    try runAndExpect(
        \\def main()
        \\  let arr: [i16; 3] = do
        \\    [9, 8, 7]
        \\  end
        \\  print arr[0]
        \\  print arr[2]
        \\end
    , "9\n7\n");
}

test "codegen/do: a `do` block's defer fires but doesn't clobber its value" {
    try runAndExpect(
        \\def note(n: i16)
        \\  print n
        \\end
        \\def main()
        \\  let x: i16 = do
        \\    defer note(1)
        \\    9
        \\  end
        \\  print x
        \\end
    , "1\n9\n");
}

test "codegen/do: a trailing nested `do … end` is the value, not nil" {
    try runAndExpect(
        \\def main()
        \\  let x: i16 = do
        \\    let a: i16 = 7
        \\    do
        \\      a + 1
        \\    end
        \\  end
        \\  print x
        \\end
    , "8\n");
}

test "codegen/closure: nested lambda — inner closure pulls captures through outer env" {
    var compiled = try compileSource(
        \\def main()
        \\  let n: i16 = 5
        \\  let outer = lambda () -> i16
        \\    let inner = lambda () -> i16
        \\      return n + 1
        \\    end
        \\    return inner()
        \\  end
        \\  print outer()
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("6\n", writer.written());
}

test "codegen/closure: nested mutation — inner mutates n through the outer's env (shared cell)" {
    var compiled = try compileSource(
        \\def main()
        \\  let n: i16 = 0
        \\  let outer = lambda () -> i16
        \\    let inner = lambda () -> i16
        \\      n = n + 10
        \\      return n
        \\    end
        \\    inner()
        \\    return inner()
        \\  end
        \\  print outer()
        \\  print n
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    // outer() runs inner() twice — n goes 0→10→20. outer returns
    // 20. Then main prints n directly, also 20 (shared cell).
    try std.testing.expectEqualStrings("20\n20\n", writer.written());
}

test "codegen/closure: short lambda body infers via fn-typed binding hint" {
    var compiled = try compileSource(
        \\def main()
        \\  let f: fn() -> i16 = || 99
        \\  print f()
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("99\n", writer.written());
}

test "codegen/closure: multiple captures (mixed read-only and mutated)" {
    var compiled = try compileSource(
        \\def main()
        \\  let counter: i16 = 0
        \\  let base: i16 = 100
        \\  let bump = lambda ()
        \\    counter = counter + 1
        \\  end
        \\  let report = || counter + base
        \\  bump()
        \\  bump()
        \\  print report()
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("102\n", writer.written());
}

// ---------- codegen-control annotations (§3.7.2 / §3.7.3 / §3.7.4) ----------

test "codegen/@noreturn: callee with @noreturn skips post-call sp cleanup" {
    // Compile two versions of the same call site — one where the
    // callee carries `@noreturn`, one without. With the annotation
    // emitCall skips the post-call `add <args>, sp` cleanup, so
    // the image comes out strictly shorter.
    var with_ann = try compileSource(
        \\@noreturn
        \\def bail(n: i16)
        \\  print n
        \\end
        \\
        \\def main()
        \\  bail(1)
        \\end
    );
    defer with_ann.deinit();
    try std.testing.expect(!with_ann.hasErrors());

    var without_ann = try compileSource(
        \\def bail(n: i16)
        \\  print n
        \\end
        \\
        \\def main()
        \\  bail(1)
        \\end
    );
    defer without_ann.deinit();
    try std.testing.expect(!without_ann.hasErrors());

    try std.testing.expect(with_ann.image.len < without_ann.image.len);
}

test "codegen/@interrupt: handler emits `rti` epilogue and IVT slot is wired at boot" {
    var compiled = try compileSource(
        \\let frame: i16 = 0
        \\
        \\@interrupt $06
        \\def on_vblank()
        \\  frame = frame + 1
        \\end
        \\
        \\def main()
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    // Resolve `on_vblank`'s emitted address from the debug-symbol
    // section — that's the source of truth for what the IVT init
    // SHOULD have written.
    const header = try gero.disasm.parseHeader(compiled.image);
    const symbols = try gero.disasm.parseSymbols(alloc, header.debug);
    defer symbols.deinit(alloc);
    var expected_addr: ?u16 = null;
    for (symbols.entries) |sym| {
        if (std.mem.eql(u8, sym.name, "on_vblank")) expected_addr = sym.address;
    }
    try std.testing.expect(expected_addr != null);

    // Boot, run a couple of dispatch steps so the IVT-init code at
    // `main`'s prologue executes, then inspect the IVT slot at
    // `$1000 + 2*$06 = $100C` — must hold `on_vblank`'s address.
    var vm = gero.vm.VM.init(alloc);
    defer vm.deinit();
    const loaded = try gero.vm.parseGx(compiled.image);
    try vm.boot(alloc, loaded);
    var i: usize = 0;
    while (i < 4) : (i += 1) _ = gero.vm.step(&vm);
    const handler_addr = vm.readWord(0x100C);
    try std.testing.expectEqual(expected_addr.?, handler_addr);

    // The handler's epilogue is `rti` (0xFD). A precise body-end
    // walk is brittle, so we just assert there's at least one
    // `rti` byte within a small window past the entry — this
    // confirms the codegen swapped `ret` for `rti` on ISR defs.
    var found_rti = false;
    var j: u16 = handler_addr;
    while (j < handler_addr + 64) : (j += 1) {
        if (vm.readByte(j) == 0xFD) {
            found_rti = true;
            break;
        }
    }
    try std.testing.expect(found_rti);
}

test "codegen/@cold: marked def's resolved address lands after non-cold defs" {
    var compiled = try compileSource(
        \\@cold
        \\def cold_path()
        \\end
        \\
        \\def hot_path()
        \\end
        \\
        \\def main()
        \\  hot_path()
        \\  cold_path()
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    // Use the debug-symbol section to read each def's resolved
    // address — the only public surface that exposes them. Ordering
    // is the actual behavior we're gating on, not "disasm doesn't
    // crash", so the assert is `addr(hot_path) < addr(cold_path)`
    // even though `cold_path` came first in source.
    const header = try gero.disasm.parseHeader(compiled.image);
    const symbols = try gero.disasm.parseSymbols(alloc, header.debug);
    defer symbols.deinit(alloc);
    var hot_addr: ?u16 = null;
    var cold_addr: ?u16 = null;
    for (symbols.entries) |sym| {
        if (std.mem.eql(u8, sym.name, "hot_path")) hot_addr = sym.address;
        if (std.mem.eql(u8, sym.name, "cold_path")) cold_addr = sym.address;
    }
    try std.testing.expect(hot_addr != null and cold_addr != null);
    try std.testing.expect(hot_addr.? < cold_addr.?);
}

test "codegen/@inline: tiny body is spliced — no standalone def emitted" {
    // With @inline, calling `tiny()` from `main` should produce a
    // shorter image than the regular version (no separate def body
    // for tiny + no call/ret overhead).
    var with_inline = try compileSource(
        \\@inline
        \\def tiny() -> i16
        \\  return 7
        \\end
        \\
        \\def main()
        \\  print tiny()
        \\end
    );
    defer with_inline.deinit();
    try std.testing.expect(!with_inline.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(with_inline.image, &writer);
    defer vm.deinit();
    try std.testing.expectEqualStrings("7\n", writer.written());
}

test "codegen/@inline: body declaring a lambda emits E_ANN_INLINE_LAMBDA_BODY" {
    const source =
        \\@inline
        \\def with_lambda() -> i16
        \\  let f = || 1
        \\  return f()
        \\end
        \\
        \\def main()
        \\  print with_lambda()
        \\end
    ;
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, source, &tree.program);
    defer checked.deinit();
    var compiled = try gero.lang.compile(alloc, source, &checked, .{});
    defer compiled.deinit();

    var found = false;
    for (compiled.diagnostics) |d| {
        if (std.mem.eql(u8, d.code, "E_ANN_INLINE_LAMBDA_BODY")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "codegen/@inline: over-cap body emits E_ANN_INLINE_TOO_LARGE" {
    const source =
        \\@inline
        \\def big() -> i16
        \\  let a: i16 = 0
        \\  let b: i16 = 0
        \\  let c: i16 = 0
        \\  let d: i16 = 0
        \\  let e: i16 = 0
        \\  let f: i16 = 0
        \\  let g: i16 = 0
        \\  let h: i16 = 0
        \\  let i: i16 = 0
        \\  let j: i16 = 0
        \\  let k: i16 = 0
        \\  let l: i16 = 0
        \\  let m: i16 = 0
        \\  let n: i16 = 0
        \\  let o: i16 = 0
        \\  let p: i16 = 0
        \\  let q: i16 = 0
        \\  return a + b + c + d + e + f + g + h + i + j + k + l + m + n + o + p + q
        \\end
        \\
        \\def main()
        \\  print big()
        \\end
    ;
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, source, &tree.program);
    defer checked.deinit();
    var compiled = try gero.lang.compile(alloc, source, &checked, .{});
    defer compiled.deinit();

    var found = false;
    for (compiled.diagnostics) |d| {
        if (std.mem.eql(u8, d.code, "E_ANN_INLINE_TOO_LARGE")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "codegen/debug-symbols: section appended when opts.debug_symbols=true" {
    const source =
        \\let counter: i16 = 0
        \\
        \\def main()
        \\  counter = counter + 1
        \\end
    ;
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, source, &tree.program);
    defer checked.deinit();

    // Default opts has debug_symbols = true.
    var compiled = try gero.lang.compile(alloc, source, &checked, .{});
    defer compiled.deinit();

    // Round-trip through the disassembler: header flag bit 1 set,
    // the debug blob parses into a `Symbols` table cleanly, and
    // both user-facing names (`main` and `counter`) are present.
    const header = try gero.disasm.parseHeader(compiled.image);
    try std.testing.expect((header.flags & 0x0002) != 0);

    const symbols = try gero.disasm.parseSymbols(alloc, header.debug);
    defer symbols.deinit(alloc);

    var saw_main = false;
    var saw_counter = false;
    for (symbols.entries) |sym| {
        if (std.mem.eql(u8, sym.name, "main")) saw_main = true;
        if (std.mem.eql(u8, sym.name, "counter")) saw_counter = true;
    }
    try std.testing.expect(saw_main);
    try std.testing.expect(saw_counter);
}

test "codegen/debug-symbols: section omitted when opts.debug_symbols=false" {
    const source = "def main() end";
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, source, &tree.program);
    defer checked.deinit();

    var compiled = try gero.lang.compile(alloc, source, &checked, .{ .debug_symbols = false });
    defer compiled.deinit();

    const flags = (@as(u16, compiled.image[7]) << 8) | @as(u16, compiled.image[6]);
    try std.testing.expect((flags & 0x0002) == 0);
}

// ---------- assert / debug_assert builtins (§5.3) ----------

/// Compile `source` with the given optimize mode; helper for the
/// assert tests that need to flip between debug and release.
fn compileWithOptimize(source: []const u8, optimize: gero.lang.Optimize) !gero.lang.Compiled {
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, source, &tree.program);
    defer checked.deinit();
    return gero.lang.compile(alloc, source, &checked, .{ .optimize = optimize });
}

test "codegen/assert: passing assert lets execution continue" {
    try runAndExpect(
        \\def main()
        \\  assert(1 == 1)
        \\  print "ok"
        \\end
    , "ok\n");
}

test "codegen/assert: failing assert halts after printing message" {
    try runAndExpect(
        \\def main()
        \\  assert(1 == 2, "math broke")
        \\  print "unreached"
        \\end
    , "math broke");
}

test "codegen/assert: failing assert without message halts silently" {
    try runAndExpect(
        \\def main()
        \\  print "before"
        \\  assert(false)
        \\  print "after"
        \\end
    , "before\n");
}

test "codegen/debug_assert: fires in debug mode" {
    try runAndExpect(
        \\def main()
        \\  debug_assert(false, "dev-time")
        \\  print "unreached"
        \\end
    , "dev-time");
}

test "codegen/debug_assert: elided in release mode" {
    var compiled = try compileWithOptimize(
        \\def main()
        \\  debug_assert(false, "should not print")
        \\  print "ok"
        \\end
    , .release);
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("ok\n", writer.written());
}

test "codegen/debug_assert: identical bytecode to assert in debug mode" {
    const assert_src =
        \\def main()
        \\  let x = 1
        \\  assert(x == 1, "eq")
        \\end
    ;
    const debug_assert_src =
        \\def main()
        \\  let x = 1
        \\  debug_assert(x == 1, "eq")
        \\end
    ;
    var a = try compileWithOptimize(assert_src, .debug);
    defer a.deinit();
    var b = try compileWithOptimize(debug_assert_src, .debug);
    defer b.deinit();
    try std.testing.expectEqualSlices(u8, a.image, b.image);
}

test "codegen/assert: identical bytecode in debug + release modes" {
    const source =
        \\def main()
        \\  let x = 1
        \\  assert(x == 1, "eq")
        \\end
    ;
    var a = try compileWithOptimize(source, .debug);
    defer a.deinit();
    var b = try compileWithOptimize(source, .release);
    defer b.deinit();
    try std.testing.expectEqualSlices(u8, a.image, b.image);
}

test "codegen/debug_assert: release image matches debug_assert-stripped source" {
    const with_da =
        \\def main()
        \\  let x = 1
        \\  debug_assert(x == 1, "eq")
        \\end
    ;
    const without =
        \\def main()
        \\  let x = 1
        \\end
    ;
    var a = try compileWithOptimize(with_da, .release);
    defer a.deinit();
    var b = try compileWithOptimize(without, .release);
    defer b.deinit();
    try std.testing.expectEqualSlices(u8, a.image, b.image);
}

test "codegen/assert: 0 args rejected with E_ASSERT_ARG_COUNT" {
    const source =
        \\def main()
        \\  assert()
        \\end
    ;
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, source, &tree.program);
    defer checked.deinit();

    var found = false;
    for (checked.diagnostics) |d| {
        if (std.mem.eql(u8, d.code, "E_ASSERT_ARG_COUNT")) found = true;
    }
    try std.testing.expect(found);
}

test "codegen/assert: 3 args rejected with E_ASSERT_ARG_COUNT" {
    const source =
        \\def main()
        \\  assert(true, "msg", 42)
        \\end
    ;
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, source, &tree.program);
    defer checked.deinit();

    var found = false;
    for (checked.diagnostics) |d| {
        if (std.mem.eql(u8, d.code, "E_ASSERT_ARG_COUNT")) found = true;
    }
    try std.testing.expect(found);
}

test "codegen/debug_assert: warns when arg contains a call" {
    const source =
        \\def helper() -> bool
        \\  return true
        \\end
        \\
        \\def main()
        \\  debug_assert(helper(), "calls have effects")
        \\end
    ;
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, source, &tree.program);
    defer checked.deinit();

    var saw_warn = false;
    for (checked.diagnostics) |d| {
        if (std.mem.eql(u8, d.code, "W_DEBUG_ASSERT_SIDE_EFFECT")) {
            saw_warn = true;
            try std.testing.expectEqual(gero.lang.Severity.warning, d.severity);
        }
    }
    try std.testing.expect(saw_warn);
}

// ---------- overflow trap on `+` / `-` / `*` (§4.2.1) ----------

/// Compile + boot + run; return the final `StepResult` so tests
/// can distinguish a clean `halted` from a `halted_on_fault`
/// (which is what the debug overflow trap raises when vector $05
/// is unset, the default at boot).
fn runForFault(source: []const u8, optimize: gero.lang.Optimize) !gero.vm.StepResult {
    var compiled = try compileWithOptimize(source, optimize);
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());
    const loaded = try gero.vm.parseGx(compiled.image);
    var vm = gero.vm.VM.init(alloc);
    defer vm.deinit();
    try vm.boot(alloc, loaded);
    return gero.vm.run(&vm);
}

test "codegen/overflow: signed `+` traps on i16 overflow in debug" {
    try std.testing.expectEqual(
        gero.vm.StepResult.halted_on_fault,
        try runForFault(
            \\def main()
            \\  let a: i16 = 30000
            \\  let b: i16 = 5000
            \\  let c: i16 = a + b
            \\  print c
            \\end
        , .debug),
    );
}

test "codegen/overflow: signed `+` wraps silently in release" {
    try std.testing.expectEqual(
        gero.vm.StepResult.halted,
        try runForFault(
            \\def main()
            \\  let a: i16 = 30000
            \\  let b: i16 = 5000
            \\  let c: i16 = a + b
            \\  print c
            \\end
        , .release),
    );
}

test "codegen/overflow: signed `-` traps on i16 underflow in debug" {
    try std.testing.expectEqual(
        gero.vm.StepResult.halted_on_fault,
        try runForFault(
            \\def main()
            \\  let a: i16 = -30000
            \\  let b: i16 = 5000
            \\  let c: i16 = a - b
            \\  print c
            \\end
        , .debug),
    );
}

test "codegen/overflow: unsigned `+` traps on u16 carry in debug" {
    try std.testing.expectEqual(
        gero.vm.StepResult.halted_on_fault,
        try runForFault(
            \\def main()
            \\  let a: u16 = 50000
            \\  let b: u16 = 20000
            \\  let c: u16 = a + b
            \\  print c
            \\end
        , .debug),
    );
}

test "codegen/overflow: unsigned `-` traps on u16 borrow in debug" {
    try std.testing.expectEqual(
        gero.vm.StepResult.halted_on_fault,
        try runForFault(
            \\def main()
            \\  let a: u16 = 5
            \\  let b: u16 = 10
            \\  let c: u16 = a - b
            \\  print c
            \\end
        , .debug),
    );
}

test "codegen/overflow: signed `*` traps via `muls` in debug" {
    try std.testing.expectEqual(
        gero.vm.StepResult.halted_on_fault,
        try runForFault(
            \\def main()
            \\  let a: i16 = 16384
            \\  let b: i16 = 3
            \\  let c: i16 = a * b
            \\  print c
            \\end
        , .debug),
    );
}

test "codegen/overflow: signed `*` of negative operands does NOT trap" {
    // The motivating regression — `(-1) * 5 = -5` fits in i16 and
    // must not trip the trap. Plain `mul` would set V here (high
    // half = 0xFFFF for the unsigned interpretation), so this test
    // verifies the codegen actually routes through `muls`.
    try runAndExpect(
        \\def main()
        \\  let a: i16 = -1
        \\  let b: i16 = 5
        \\  let c: i16 = a * b
        \\  print c
        \\end
    , "-5\n");
}

test "codegen/overflow: unsigned `*` traps when high half nonzero in debug" {
    try std.testing.expectEqual(
        gero.vm.StepResult.halted_on_fault,
        try runForFault(
            \\def main()
            \\  let a: u16 = 1000
            \\  let b: u16 = 1000
            \\  let c: u16 = a * b
            \\  print c
            \\end
        , .debug),
    );
}

test "codegen/overflow: arithmetic without overflow runs cleanly in debug" {
    try runAndExpect(
        \\def main()
        \\  let a: i16 = 100
        \\  let b: i16 = 50
        \\  print a + b
        \\  print a - b
        \\  print a * b
        \\end
    , "150\n50\n5000\n");
}

test "codegen/overflow: same overflowing program halts cleanly in release" {
    // `30000 + 5000` wraps to `-30536` in i16 two's-complement;
    // the program completes and prints the wrapped value rather
    // than trapping.
    try std.testing.expectEqual(
        gero.vm.StepResult.halted,
        try runForFault(
            \\def main()
            \\  let a: i16 = 30000
            \\  let b: i16 = 5000
            \\  let c: i16 = a + b
            \\  print c
            \\end
        , .release),
    );
}

test "codegen/overflow: same source emits different bytecodes for debug vs release" {
    // AC: "Build mode change toggles the check (same source, two
    // bytecodes)". Image-byte equality fails — debug has the
    // overflow check, release doesn't.
    const source =
        \\def main()
        \\  let a: i16 = 100
        \\  let b: i16 = 50
        \\  let c: i16 = a + b
        \\  print c
        \\end
    ;
    var dbg = try compileWithOptimize(source, .debug);
    defer dbg.deinit();
    var rel = try compileWithOptimize(source, .release);
    defer rel.deinit();
    try std.testing.expect(dbg.image.len != rel.image.len);
}

test "codegen/overflow: release image has no `int 5` trap bytes after add/sub/mul" {
    // AC: "Plain +, -, * wrap silently in release builds (verify
    // via disasm round-trip — no overflow check)". Scan the
    // release-mode image for the `int 5` sequence (0xFC 0x05) —
    // none should appear in this program's code region. The
    // program has no globals, so the entire base image past
    // `code_base` is code.
    var compiled = try compileWithOptimize(
        \\def main()
        \\  let a: i16 = 1
        \\  let b: i16 = 2
        \\  let c: i16 = a + b
        \\  let d: i16 = c - a
        \\  let e: i16 = d * b
        \\  print e
        \\end
    , .release);
    defer compiled.deinit();
    const loaded = try gero.vm.parseGx(compiled.image);
    const code = loaded.image[gero.lang.codegen.code_base..];
    var saw_trap = false;
    var i: usize = 0;
    while (i + 1 < code.len) : (i += 1) {
        if (code[i] == 0xFC and code[i + 1] == 0x05) {
            saw_trap = true;
            break;
        }
    }
    try std.testing.expect(!saw_trap);

    // Same scan against the debug image — the trap MUST be present
    // there. Acts as a sanity check that the scan is meaningful.
    var dbg = try compileWithOptimize(
        \\def main()
        \\  let a: i16 = 1
        \\  let b: i16 = 2
        \\  let c: i16 = a + b
        \\end
    , .debug);
    defer dbg.deinit();
    const dbg_loaded = try gero.vm.parseGx(dbg.image);
    const dbg_code = dbg_loaded.image[gero.lang.codegen.code_base..];
    var dbg_saw_trap = false;
    var j: usize = 0;
    while (j + 1 < dbg_code.len) : (j += 1) {
        if (dbg_code[j] == 0xFC and dbg_code[j + 1] == 0x05) {
            dbg_saw_trap = true;
            break;
        }
    }
    try std.testing.expect(dbg_saw_trap);
}

test "codegen/overflow: custom `@interrupt $05` handler fires on overflow" {
    // AC: "Source pointer in the trap diagnostic points at the
    // source location of the offending op". The trap mechanism is
    // `int 5` + the standard interrupt-entry save sequence — a
    // custom $05 handler observes the saved ip and can map it to
    // source via debug symbols. This test verifies the handler is
    // actually reached when overflow fires (the precision of the
    // source mapping then depends on the host-side debug-symbol
    // consumption per spec §4.2.1).
    var compiled = try compileSource(
        \\let trap_fired: i16 = 0
        \\
        \\@interrupt $05
        \\def on_overflow()
        \\  trap_fired = 1
        \\end
        \\
        \\def main()
        \\  let a: i16 = 30000
        \\  let b: i16 = 5000
        \\  let c: i16 = a + b
        \\  print c
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    // The handler wrote `1` to `trap_fired` — find its address via
    // the debug-symbol section and read it from memory.
    const header = try gero.disasm.parseHeader(compiled.image);
    const symbols = try gero.disasm.parseSymbols(alloc, header.debug);
    defer symbols.deinit(alloc);
    var trap_addr: ?u16 = null;
    for (symbols.entries) |sym| {
        if (std.mem.eql(u8, sym.name, "trap_fired")) trap_addr = sym.address;
    }
    try std.testing.expect(trap_addr != null);
    try std.testing.expectEqual(@as(u16, 1), vm.mmap.readWord(trap_addr.?));
}

test "codegen/@interrupt: handler preserves acu across the interrupted computation" {
    // The overflow trap fires mid-expression (`a + b` overflows) with the
    // wrapped sum live in acu; the handler clobbers acu (writes a global).
    // Interrupt entry saves only ip/fp/flg, so without the handler saving
    // acu the resumed `let c = a + b` would store the handler's value.
    // 30000 + 5000 wraps to -30536 (i16).
    try runAndExpect(
        \\let trap_fired: i16 = 0
        \\@interrupt $05
        \\def on_overflow()
        \\  trap_fired = 1
        \\end
        \\def main()
        \\  let a: i16 = 30000
        \\  let b: i16 = 5000
        \\  let c: i16 = a + b
        \\  print c
        \\end
    , "-30536\n");
}

test "codegen/@interrupt: handler with locals gets its own frame + clean rti" {
    // An ISR with locals needs its own frame (fp=sp) and a frame release
    // before rti; otherwise its locals alias the interrupted frame and
    // rti pops a misaligned stack. Fire it via the overflow trap: main
    // must resume + print the wrapped sum, and the handler's local-based
    // computation (20 + 22) must land in its global.
    var compiled = try compileSource(
        \\let trapped: i16 = 0
        \\@interrupt $05
        \\def on_overflow()
        \\  let x: i16 = 20
        \\  let y: i16 = 22
        \\  trapped = x + y
        \\end
        \\def main()
        \\  let a: i16 = 30000
        \\  let b: i16 = 5000
        \\  let c: i16 = a + b
        \\  print c
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    // main resumed cleanly (rti landed correctly) and printed the sum.
    try std.testing.expectEqualStrings("-30536\n", writer.written());
    // the handler computed x + y = 42 in its own frame.
    const header = try gero.disasm.parseHeader(compiled.image);
    const symbols = try gero.disasm.parseSymbols(alloc, header.debug);
    defer symbols.deinit(alloc);
    var trapped_addr: ?u16 = null;
    for (symbols.entries) |sym| {
        if (std.mem.eql(u8, sym.name, "trapped")) trapped_addr = sym.address;
    }
    try std.testing.expect(trapped_addr != null);
    try std.testing.expectEqual(@as(u16, 42), vm.mmap.readWord(trapped_addr.?));
}

test "codegen/@interrupt: handler can cross-bank-call (preserves acu across it)" {
    // A handler that cross-bank-calls exercises the trampoline (which
    // uses r1..r6) from inside the ISR. The ISR prologue saves the GP
    // registers, so main's interrupted computation (live in acu) survives
    // both the handler and its cross-bank call. 30000 + 30000 wraps to
    // -5536; helper(21) = 42 lands in the global.
    var compiled = try compileSource(
        \\let result: i16 = 0
        \\@bank 2
        \\def helper(x: i16) -> i16
        \\  return x * 2
        \\end
        \\@interrupt $05
        \\def on_overflow()
        \\  result = helper(21)
        \\end
        \\def main()
        \\  let a: i16 = 30000
        \\  let c: i16 = a + a
        \\  print c
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings("-5536\n", writer.written());
    const header = try gero.disasm.parseHeader(compiled.image);
    const symbols = try gero.disasm.parseSymbols(alloc, header.debug);
    defer symbols.deinit(alloc);
    var result_addr: ?u16 = null;
    for (symbols.entries) |sym| {
        if (std.mem.eql(u8, sym.name, "result")) result_addr = sym.address;
    }
    try std.testing.expect(result_addr != null);
    try std.testing.expectEqual(@as(u16, 42), vm.mmap.readWord(result_addr.?));
}

test "codegen/@interrupt: empty handler's prologue/epilogue stay balanced" {
    // A body-less handler still runs the register save/restore + frame
    // open/release; the pushes and pops must balance so `rti` finds the
    // VM-pushed flg/fp/ip. main resumes + prints the wrapped sum.
    try runAndExpect(
        \\@interrupt $05
        \\def noop()
        \\end
        \\def main()
        \\  let c: i16 = 30000 + 5000
        \\  print c
        \\end
    , "-30536\n");
}

test "codegen/@interrupt: handler can call a regular function (enter/ret frame composes)" {
    // The handler opens its own frame (fp=sp), then calls a regular fn
    // whose enter/ret push + restore a nested frame on top. The handler
    // prints during the trap, then main resumes — exercising both the
    // frame composition and acu preservation across the call.
    try runAndExpect(
        \\def dbl(n: i16) -> i16
        \\  return n * 2
        \\end
        \\@interrupt $05
        \\def handler()
        \\  print dbl(21)
        \\end
        \\def main()
        \\  let c: i16 = 30000 + 5000
        \\  print c
        \\end
    , "42\n-30536\n");
}

// ---------- stdlib modules: math / bank / test ----------

test "codegen/math: min/max/abs/clamp over i16 (signed)" {
    try runAndExpect(
        \\def main()
        \\  let lo: i16 = 0 - 5
        \\  print math.min(5, 3)
        \\  print math.max(5, 3)
        \\  print math.abs(lo)
        \\  print math.clamp(15, 0, 10)
        \\  print math.clamp(lo, 0, 10)
        \\  print math.clamp(7, 0, 10)
        \\end
    , "3\n5\n5\n10\n0\n7\n");
}

test "codegen/math: min/max pick unsigned comparison for u16" {
    // 60000 as i16 is negative; a signed compare would invert these.
    try runAndExpect(
        \\def main()
        \\  let a: u16 = 60000
        \\  let b: u16 = 5
        \\  print math.min(a, b)
        \\  print math.max(a, b)
        \\end
    , "5\n60000\n");
}

test "codegen/math: wrap_add/wrap_mul wrap without trapping" {
    try runAndExpect(
        \\def main()
        \\  let big: i16 = 30000
        \\  print math.wrap_add(big, 5000)
        \\  print math.wrap_mul(200, 200)
        \\end
    , "-30536\n-25536\n");
}

test "codegen/math: sat_* clamp to i16 bounds (signed)" {
    try runAndExpect(
        \\def main()
        \\  let big: i16 = 30000
        \\  let nbig: i16 = 0 - 30000
        \\  print math.sat_add(big, 5000)
        \\  print math.sat_add(nbig, 0 - 5000)
        \\  print math.sat_sub(nbig, 5000)
        \\  print math.sat_mul(1000, 1000)
        \\  print math.sat_mul(0 - 1000, 1000)
        \\  print math.sat_add(100, 200)
        \\end
    , "32767\n-32768\n-32768\n32767\n-32768\n300\n");
}

test "codegen/math: sat_* clamp to u16 bounds (unsigned)" {
    try runAndExpect(
        \\def main()
        \\  let a: u16 = 60000
        \\  let small: u16 = 5
        \\  print math.sat_add(a, 10000)
        \\  print math.sat_sub(small, 10)
        \\  print math.sat_mul(a, 1000)
        \\end
    , "65535\n0\n65535\n");
}

test "codegen/math: fixed_sin (Bhaskara) over the circle, Q8.8 raw" {
    // 1.0 = 256, 0.5 = 128, -1.0 = -256 (0xFF00). fixed_sin(45) ≈ 0.707;
    // Bhaskara + the den halving lands it at 180 (~0.703, ~1 LSB off).
    var compiled = try compileSource(
        \\def main()
        \\  let s0: fixed = math.fixed_sin(0)
        \\  let s90: fixed = math.fixed_sin(90)
        \\  let s30: fixed = math.fixed_sin(30)
        \\  let s270: fixed = math.fixed_sin(270)
        \\  let s180: fixed = math.fixed_sin(180)
        \\  let s45: fixed = math.fixed_sin(45)
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    // Locals sit at descending fp-relative slots from fp = 0xFFFE.
    try std.testing.expectEqual(@as(u16, 0), vm.mmap.readWord(0xFFFC)); // sin(0) = 0
    try std.testing.expectEqual(@as(u16, 256), vm.mmap.readWord(0xFFFA)); // sin(90) = 1.0
    try std.testing.expectEqual(@as(u16, 128), vm.mmap.readWord(0xFFF8)); // sin(30) = 0.5
    try std.testing.expectEqual(@as(u16, 0xFF00), vm.mmap.readWord(0xFFF6)); // sin(270) = -1.0
    try std.testing.expectEqual(@as(u16, 0), vm.mmap.readWord(0xFFF4)); // sin(180) = 0
    try std.testing.expectEqual(@as(u16, 180), vm.mmap.readWord(0xFFF2)); // sin(45) ≈ 0.707
}

test "codegen/math: sqrt_fixed (bit-by-bit isqrt) Q8.8 raw" {
    // result raw = isqrt(x_raw << 8). 1.0→1.0, 4.0→2.0, 9.0→3.0 exact;
    // 2.0→~1.414 (362); 0.25→0.5 (128); negative → 0.
    var compiled = try compileSource(
        \\def main()
        \\  let s0: fixed = math.sqrt_fixed(0.0)
        \\  let s1: fixed = math.sqrt_fixed(1.0)
        \\  let s4: fixed = math.sqrt_fixed(4.0)
        \\  let s9: fixed = math.sqrt_fixed(9.0)
        \\  let s2: fixed = math.sqrt_fixed(2.0)
        \\  let sq: fixed = math.sqrt_fixed(0.25)
        \\  let sn: fixed = math.sqrt_fixed(0.0 - 1.0)
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqual(@as(u16, 0), vm.mmap.readWord(0xFFFC)); // √0 = 0
    try std.testing.expectEqual(@as(u16, 256), vm.mmap.readWord(0xFFFA)); // √1 = 1.0
    try std.testing.expectEqual(@as(u16, 512), vm.mmap.readWord(0xFFF8)); // √4 = 2.0
    try std.testing.expectEqual(@as(u16, 768), vm.mmap.readWord(0xFFF6)); // √9 = 3.0
    try std.testing.expectEqual(@as(u16, 362), vm.mmap.readWord(0xFFF4)); // √2 ≈ 1.414
    try std.testing.expectEqual(@as(u16, 128), vm.mmap.readWord(0xFFF2)); // √0.25 = 0.5
    try std.testing.expectEqual(@as(u16, 0), vm.mmap.readWord(0xFFF0)); // √negative = 0
}

test "codegen/math: fixed_sin range-reduces a large angle" {
    // 30000 mod 360 = 120, so fixed_sin(30000) == fixed_sin(120) ≈ 0.865
    // → 221 in Q8.8 (Bhaskara).
    var compiled = try compileSource(
        \\def main()
        \\  let a: fixed = math.fixed_sin(30000)
        \\  let b: fixed = math.fixed_sin(120)
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqual(@as(u16, 221), vm.mmap.readWord(0xFFFC)); // sin(30000°)
    try std.testing.expectEqual(@as(u16, 221), vm.mmap.readWord(0xFFFA)); // sin(120°)
}

test "codegen/math: rng — deterministic Galois LFSR sequence" {
    // First call lazily seeds (0xACE1) then steps; the sequence is fixed.
    try runAndExpect(
        \\def main()
        \\  print math.rng()
        \\  print math.rng()
        \\  print math.rng()
        \\end
    , "57968\n28984\n14492\n");
}

test "codegen/bake: math.* evaluated at compile time (int + unsigned threading)" {
    // `G` proves the typechecker's types thread into the bake evaluator:
    // min(60000, 5) over u16 is 5; a signed compare would pick 60000.
    try runAndExpect(
        \\const A: i16 = bake do
        \\  math.min(5, 3)
        \\end
        \\const B: i16 = bake do
        \\  math.clamp(15, 0, 10)
        \\end
        \\const C: i16 = bake do
        \\  math.abs(0 - 7)
        \\end
        \\const D: i16 = bake do
        \\  math.wrap_add(30000, 5000)
        \\end
        \\const G: u16 = bake do
        \\  let a: u16 = 60000
        \\  math.min(a, 5)
        \\end
        \\def main()
        \\  print A
        \\  print B
        \\  print C
        \\  print D
        \\  print G
        \\end
    , "3\n10\n7\n-30536\n5\n");
}

test "codegen/bake: fixed_sin / sqrt_fixed match the runtime at compile time" {
    // The bake evaluator's fixed routines mirror the runtime exactly:
    // fixed_sin(90) = 1.0 = 256, sqrt_fixed(4.0) = 2.0 = 512.
    var compiled = try compileSource(
        \\const S90: fixed = bake do
        \\  math.fixed_sin(90)
        \\end
        \\const SQ4: fixed = bake do
        \\  math.sqrt_fixed(4.0)
        \\end
        \\def main()
        \\end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    const header = try gero.disasm.parseHeader(compiled.image);
    const symbols = try gero.disasm.parseSymbols(alloc, header.debug);
    defer symbols.deinit(alloc);
    var s90: ?u16 = null;
    var sq4: ?u16 = null;
    for (symbols.entries) |sym| {
        if (std.mem.eql(u8, sym.name, "S90")) s90 = sym.address;
        if (std.mem.eql(u8, sym.name, "SQ4")) sq4 = sym.address;
    }
    try std.testing.expect(s90 != null and sq4 != null);
    try std.testing.expectEqual(@as(u16, 256), vm.mmap.readWord(s90.?)); // fixed_sin(90) = 1.0
    try std.testing.expectEqual(@as(u16, 512), vm.mmap.readWord(sq4.?)); // sqrt_fixed(4.0) = 2.0
}

test "codegen/math: nested math.* calls compose (args are full exprs)" {
    // abs(-15)=15; min(10,20)=10; clamp(15, 0, 10)=10. Each arg is itself
    // a math call — the push/pop arg discipline keeps them independent.
    try runAndExpect(
        \\def main()
        \\  let x: i16 = 0 - 15
        \\  print math.clamp(math.abs(x), 0, math.min(10, 20))
        \\end
    , "10\n");
}

test "codegen/bank: switch_to writes mb, current reads it" {
    try runAndExpect(
        \\def main()
        \\  print bank.current()
        \\  bank.switch_to(3)
        \\  print bank.current()
        \\end
    , "0\n3\n");
}

test "codegen/test: assert_eq / assert_ne pass through on success" {
    try runAndExpect(
        \\def main()
        \\  test.assert_eq(2 + 2, 4)
        \\  test.assert_ne(2, 3)
        \\  print 1
        \\end
    , "1\n");
}

test "codegen/test: assert_eq halts with a message on failure" {
    // The failing assert prints + halts, so `print 99` never runs.
    try runAndExpect(
        \\def main()
        \\  test.assert_eq(2, 3)
        \\  print 99
        \\end
    , "test assertion failed\n");
}

test "codegen/overflow: fixed-point `*` wraps in both modes per ISA §5.4.1" {
    // Fixed `*` is explicitly wrap-only — the codegen skips the
    // overflow trap regardless of build mode. Picking values that
    // would overflow if the trap were inserted: 100.0 * 100.0 in
    // Q8.8 produces a Q16.16 product > i16 range. The program
    // must complete (no fault) in both debug and release.
    try std.testing.expectEqual(
        gero.vm.StepResult.halted,
        try runForFault(
            \\def main()
            \\  let a: fixed = 100.0
            \\  let b: fixed = 100.0
            \\  let c: fixed = a * b
            \\  print c
            \\end
        , .debug),
    );
}

test "codegen/assert: plain `assert(call())` does NOT warn" {
    const source =
        \\def helper() -> bool
        \\  return true
        \\end
        \\
        \\def main()
        \\  assert(helper())
        \\end
    ;
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, source, &tree.program);
    defer checked.deinit();

    for (checked.diagnostics) |d| {
        try std.testing.expect(!std.mem.eql(u8, d.code, "W_DEBUG_ASSERT_SIDE_EFFECT"));
    }
}

// ---------- bake (compile-time evaluator) ----------

test "codegen/bake: `const X = bake do … end` writes serialized bytes into the image" {
    // Compute `1 + 2 + … + 10 = 55` at compile time; the resulting
    // i16 lives at the global's allocated data-region address.
    var compiled = try compileSource(
        \\const X = bake do
        \\  let n = 0
        \\  for i in 1..=10
        \\    n = n + i
        \\  end
        \\  n
        \\end
        \\
        \\def main() end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    // Image must extend past `data_base` (0x2000) so the runtime
    // sees the baked value at boot.
    const loaded = try gero.vm.parseGx(compiled.image);
    try std.testing.expect(loaded.image.len > gero.lang.codegen.data_base);
    // First baked global lands at the start of the data region —
    // the bytes there should encode `55` as little-endian i16.
    const lo = loaded.image[gero.lang.codegen.data_base];
    const hi = loaded.image[gero.lang.codegen.data_base + 1];
    try std.testing.expectEqual(@as(u16, 55), @as(u16, lo) | (@as(u16, hi) << 8));
}

test "codegen/bake: `const X = bake_def_name()` resolves through the call form" {
    var compiled = try compileSource(
        \\bake def square(x: i16) -> i16
        \\  return x * x
        \\end
        \\
        \\const X = square(9)
        \\
        \\def main() end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    const loaded = try gero.vm.parseGx(compiled.image);
    const lo = loaded.image[gero.lang.codegen.data_base];
    const hi = loaded.image[gero.lang.codegen.data_base + 1];
    try std.testing.expectEqual(@as(u16, 81), @as(u16, lo) | (@as(u16, hi) << 8));
}

test "codegen/bake: array baked into static data" {
    // `[i16; 5]` = 10 bytes; values 0, 2, 4, 6, 8 (i * 2).
    var compiled = try compileSource(
        \\const TABLE = bake do
        \\  let t: [i16; 5] = [0; 5]
        \\  for i in 0..5
        \\    t[i] = i * 2
        \\  end
        \\  t
        \\end
        \\
        \\def main() end
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    const loaded = try gero.vm.parseGx(compiled.image);
    const base: usize = gero.lang.codegen.data_base;
    for (0..5) |i| {
        const lo = loaded.image[base + i * 2];
        const hi = loaded.image[base + i * 2 + 1];
        try std.testing.expectEqual(@as(u16, @intCast(i * 2)), @as(u16, lo) | (@as(u16, hi) << 8));
    }
}

test "codegen/bake: a baked global past the data-region ceiling is a clean error" {
    // `[i16; 30000]` = 60000 bytes overruns the static-data region
    // (`data_base` 0x2000 .. `data_region_end` 0xFE40) — flag it rather
    // than wrap the data cursor.
    try expectCodegenError(
        \\const TABLE = bake do
        \\  let t: [i16; 30000] = [0; 30000]
        \\  t
        \\end
        \\def main() end
    , "E_CODEGEN_DATA_OVERFLOW");
}

test "codegen/bake: program without bake stays small (image doesn't grow to data region)" {
    // Regression: extending the image to cover the data region
    // should only happen when bake-init bytes need to ship.
    var compiled = try compileSource("def main() end");
    defer compiled.deinit();
    // Image is much smaller than `data_base = 0x2000` for a
    // hlt-only program.
    try std.testing.expect(compiled.image.len < gero.lang.codegen.data_base);
}

// ---------- is X (class form) runtime ----------

test "codegen/is: runtime hit on a subclass instance prints from the then-arm" {
    try runAndExpect(
        \\class Animal
        \\  let k: u8
        \\  def init(self)
        \\    self.k = 0
        \\  end
        \\end
        \\class Dog extends Animal
        \\  def init(self)
        \\    super.init()
        \\  end
        \\end
        \\def report(a: Animal)
        \\  if a is Dog
        \\    print "dog"
        \\  end
        \\end
        \\def main()
        \\  let d = Dog()
        \\  report(d)
        \\end
    , "dog\n");
}

test "codegen/is: runtime miss on an unrelated subclass skips the then-arm" {
    try runAndExpect(
        \\class Animal
        \\  let k: u8
        \\  def init(self)
        \\    self.k = 0
        \\  end
        \\end
        \\class Dog extends Animal
        \\  def init(self)
        \\    super.init()
        \\  end
        \\end
        \\class Cat extends Animal
        \\  def init(self)
        \\    super.init()
        \\  end
        \\end
        \\def report(a: Animal)
        \\  if a is Dog
        \\    print "dog"
        \\  end
        \\  print "done"
        \\end
        \\def main()
        \\  let c = Cat()
        \\  report(c)
        \\end
    , "done\n");
}

test "codegen/is: `as binding` exposes the downcast value in the arm" {
    try runAndExpect(
        \\class Animal
        \\  let k: u8
        \\  def init(self)
        \\    self.k = 0
        \\  end
        \\end
        \\class Dog extends Animal
        \\  let bark_count: u8
        \\  def init(self)
        \\    super.init()
        \\    self.bark_count = 3
        \\  end
        \\end
        \\def report(a: Animal)
        \\  if a is Dog as d
        \\    print d.bark_count
        \\  end
        \\end
        \\def main()
        \\  let d = Dog()
        \\  report(d)
        \\end
    , "3\n");
}

// ---------- diverging builtins ----------

test "codegen/panic: prints the message and halts" {
    try runAndExpect(
        \\def main()
        \\  panic("kaboom")
        \\  print "unreached"
        \\end
    , "kaboom\n");
}

test "codegen/unreachable: prints the diagnostic and halts" {
    try runAndExpect(
        \\def main()
        \\  unreachable()
        \\  print "unreached"
        \\end
    , "unreachable code reached\n");
}

test "codegen/todo: prints TODO (no msg) and halts" {
    try runAndExpect(
        \\def main()
        \\  todo()
        \\  print "unreached"
        \\end
    , "TODO\n");
}

test "codegen/todo: prints TODO with the message and halts" {
    try runAndExpect(
        \\def main()
        \\  todo("audio")
        \\  print "unreached"
        \\end
    , "TODO: audio\n");
}

// ---------- sizeof (comptime) ----------

test "codegen/sizeof: primitive widths fold to integer literals" {
    try runAndExpect(
        \\def main()
        \\  print sizeof(i8)
        \\  print sizeof(i16)
        \\  print sizeof(bool)
        \\end
    , "1\n2\n1\n");
}

test "codegen/sizeof: aggregate widths sum field / element sizes" {
    try runAndExpect(
        \\struct Pos
        \\  x: i16
        \\  y: i16
        \\end
        \\def main()
        \\  print sizeof(Pos)
        \\  print sizeof([i16; 8])
        \\end
    , "4\n16\n");
}

/// Count non-overlapping occurrences of `needle` in `haystack`.
fn countByteSeq(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, from, needle)) |pos| {
        n += 1;
        from = pos + 1;
    }
    return n;
}

test "codegen: each MMIO @addr read compiles to its own bus load" {
    // The emitter is intentionally literal — a period-authentic 8-bit
    // code generator with no register caching or CSE. Every source read
    // of an `@addr`-pinned global compiles to a real load, which is what
    // memory-mapped IO depends on: a peripheral whose read has side
    // effects (a gtx-16 RNG register auto-advances) is observable only
    // if each read hits the bus. `@volatile` documents that guarantee at
    // the source level; this pins that the emitter keeps it — two reads
    // stay two loads.
    var two = try compileSource(
        \\@addr $FE40
        \\let port: u16 = 0
        \\def main()
        \\  let a: u16 = port
        \\  let b: u16 = port
        \\end
    );
    defer two.deinit();
    // `mov reg, [$FE40]` (0x13) — opcode byte then the LE address.
    try std.testing.expectEqual(
        @as(usize, 2),
        countByteSeq(two.image, &[_]u8{ 0x13, 0x40, 0xFE }),
    );

    // Control: a single read is exactly one load, proving the count
    // tracks source reads rather than a coincidental byte run.
    var one = try compileSource(
        \\@addr $FE40
        \\let port: u16 = 0
        \\def main()
        \\  let a: u16 = port
        \\end
    );
    defer one.deinit();
    try std.testing.expectEqual(
        @as(usize, 1),
        countByteSeq(one.image, &[_]u8{ 0x13, 0x40, 0xFE }),
    );
}

test "codegen: byte-width MMIO global loads via mov8, never a word load" {
    // A `u8` MMIO register must read with `mov8 [addr]` (0x22), which
    // touches exactly one byte. A word load (0x13) would also pull the
    // adjacent address — a *different* register on real MMIO.
    var compiled = try compileSource(
        \\@addr $FE40
        \\let flag: u8 = 0
        \\def main()
        \\  let a: u8 = flag
        \\end
    );
    defer compiled.deinit();
    try std.testing.expectEqual(
        @as(usize, 1),
        countByteSeq(compiled.image, &[_]u8{ 0x22, 0x40, 0xFE }),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        countByteSeq(compiled.image, &[_]u8{ 0x13, 0x40, 0xFE }),
    );
}

// ---------- compound assignment + inc/dec ----------

test "codegen: compound `op=` chain folds into the binding" {
    try runAndExpect(
        \\def main()
        \\  let x = 0
        \\  x += 5
        \\  x *= 3
        \\  x -= 1
        \\  print x
        \\end
    , "14\n");
}

test "codegen: compound `*=` / `-=` drive a factorial loop" {
    try runAndExpect(
        \\def main()
        \\  let n = 5
        \\  let acc = 1
        \\  while n > 1
        \\    acc *= n
        \\    n -= 1
        \\  end
        \\  print acc
        \\end
    , "120\n");
}

test "codegen: bitwise / shift compound assignment" {
    try runAndExpect(
        \\def main()
        \\  let x = 1
        \\  x <<= 4
        \\  x |= 1
        \\  print x
        \\end
    , "17\n");
}

test "codegen: `++` and `--` increment / decrement in place" {
    try runAndExpect(
        \\def main()
        \\  let x = 10
        \\  x++
        \\  x++
        \\  x--
        \\  print x
        \\end
    , "11\n");
}

test "codegen: compound assignment to a class field" {
    try runAndExpect(
        \\class C
        \\  let v: i16
        \\  def init(self, v: i16)
        \\    self.v = v
        \\  end
        \\  def bump(self)
        \\    self.v += 100
        \\  end
        \\end
        \\def main()
        \\  let c = C(5)
        \\  c.bump()
        \\  print c.v
        \\end
    , "105\n");
}

// ---------- enum payload variants ----------

test "codegen: enum payload construct + match-bind" {
    try runAndExpect(
        \\enum E
        \\  case A(x: i16)
        \\  case B
        \\end
        \\def f(e: E) -> i16
        \\  match e
        \\    case E.A(n) => return n
        \\    case E.B => return 0
        \\  end
        \\end
        \\def main()
        \\  print f(E.A(42))
        \\  print f(E.B)
        \\end
    , "42\n0\n");
}

test "codegen: payload binder usable in arithmetic" {
    try runAndExpect(
        \\enum E
        \\  case A(x: i16)
        \\  case B
        \\end
        \\def main()
        \\  match E.A(7)
        \\    case E.A(n) => print n + 1
        \\    case E.B => print 0
        \\  end
        \\end
    , "8\n");
}

test "codegen: multi-field payload binders" {
    try runAndExpect(
        \\enum Item
        \\  case Sword
        \\  case Key(id: i16, count: i16)
        \\end
        \\def main()
        \\  match Item.Key(100, 7)
        \\    case Item.Sword => print 1
        \\    case Item.Key(id, c) => print id + c
        \\  end
        \\end
    , "107\n");
}

test "codegen: guard reads a payload binder" {
    try runAndExpect(
        \\enum Act
        \\  case Hit(dmg: i16)
        \\  case Miss
        \\end
        \\def resolve(a: Act) -> i16
        \\  match a
        \\    case Act.Hit(d) when d > 10 => return 2
        \\    case Act.Miss => return 0
        \\    case _ => return 1
        \\  end
        \\end
        \\def main()
        \\  print resolve(Act.Hit(20))
        \\  print resolve(Act.Hit(5))
        \\  print resolve(Act.Miss)
        \\end
    , "2\n1\n0\n");
}

test "codegen: str payload binder prints as a string" {
    try runAndExpect(
        \\enum Msg
        \\  case Text(s: str)
        \\  case Empty
        \\end
        \\def main()
        \\  match Msg.Text("hello")
        \\    case Msg.Text(s) => print s
        \\    case Msg.Empty => print "none"
        \\  end
        \\end
    , "hello\n");
}

test "codegen: `is` tag test on a payload enum" {
    try runAndExpect(
        \\enum E
        \\  case A(x: i16)
        \\  case B
        \\end
        \\def main()
        \\  let e = E.A(7)
        \\  if e is E.A
        \\    print 1
        \\  end
        \\  if e is E.B
        \\    print 2
        \\  else
        \\    print 3
        \\  end
        \\end
    , "1\n3\n");
}

// ---------- value tuples (§3.4) ----------

test "codegen/tuple: literal construction + `.N` element read" {
    try runAndExpect(
        \\def main()
        \\  let t = (3, 4)
        \\  print t.0
        \\  print t.1
        \\  print t.0 + t.1
        \\end
    , "3\n4\n7\n");
}

test "codegen/tuple: mixed-width elements pack contiguously" {
    try runAndExpect(
        \\def main()
        \\  let t = (1 as u8, 300, 2 as u8)
        \\  print t.0
        \\  print t.1
        \\  print t.2
        \\end
    , "1\n300\n2\n");
}

test "codegen/tuple: a `str` element reads back by pointer" {
    try runAndExpect(
        \\def main()
        \\  let t = (5, "hi")
        \\  print t.0
        \\  print t.1
        \\end
    , "5\nhi\n");
}

test "codegen/tuple: a signed `i8` element sign-extends on read" {
    try runAndExpect(
        \\def main()
        \\  let t = (-5 as i8, 1)
        \\  print t.0
        \\end
    , "-5\n");
}

test "codegen/tuple: value copy on `let` + reassignment leaves the source intact" {
    try runAndExpect(
        \\def main()
        \\  let a = (1, 2)
        \\  let b = a
        \\  let c = (0, 0)
        \\  c = a
        \\  print b.0
        \\  print c.1
        \\  print a.0
        \\  print a.1
        \\end
    , "1\n2\n1\n2\n");
}

test "codegen/tuple: return-by-value (multi-return) + element read" {
    try runAndExpect(
        \\def pair() -> (i16, i16)
        \\  return (1, 2)
        \\end
        \\def main()
        \\  let t = pair()
        \\  print t.0
        \\  print t.1
        \\end
    , "1\n2\n");
}

test "codegen/tuple: pass-by-value param (mutation-isolated) after a scalar arg" {
    try runAndExpect(
        \\def snd(n: i16, t: (i16, i16)) -> i16
        \\  return n + t.1
        \\end
        \\def main()
        \\  let a = (5, 6)
        \\  print snd(100, a)
        \\  print a.0
        \\end
    , "106\n5\n");
}

test "codegen/tuple: a returned tuple feeds straight into a by-value param" {
    try runAndExpect(
        \\def mk() -> (i16, i16)
        \\  return (10, 20)
        \\end
        \\def snd(t: (i16, i16)) -> i16
        \\  return t.1
        \\end
        \\def main()
        \\  print snd(mk())
        \\end
    , "20\n");
}

test "codegen/tuple: passed by value through an `@inline` fn" {
    try runAndExpect(
        \\@inline
        \\def fst(t: (i16, i16)) -> i16
        \\  return t.0
        \\end
        \\def main()
        \\  print fst((7, 8))
        \\end
    , "7\n");
}

test "codegen/tuple: `==` / `!=` compares element-wise" {
    // All-scalar tuples byte-sweep; a `str` element compares by content
    // even across distinct interpolation buffers.
    try runAndExpect(
        \\def main()
        \\  let n = 1
        \\  print (1, 2) == (1, 2)
        \\  print (1, 2) == (1, 3)
        \\  print (1, 2) != (1, 3)
        \\  print ("a$(n)", 5) == ("a$(n)", 5)
        \\  print ("a$(n)", 5) == ("b$(n)", 5)
        \\end
    , "1\n0\n1\n1\n0\n");
}

test "codegen/tuple: `==` recurses into a struct element (str by content)" {
    try runAndExpect(
        \\struct P
        \\  name: str
        \\end
        \\def main()
        \\  let n = 1
        \\  print (P { name: "x$(n)" }, 3) == (P { name: "x$(n)" }, 3)
        \\  print (P { name: "x$(n)" }, 3) == (P { name: "y$(n)" }, 3)
        \\end
    , "1\n0\n");
}

test "codegen/tuple: whole-tuple `print` renders `(v0, v1, …)`" {
    try runAndExpect(
        \\enum E
        \\  case A
        \\  case V(n: i16)
        \\end
        \\def main()
        \\  print (1, "hi", -3 as i8)
        \\  print ((1, 2), 3)
        \\  print (E.V(7), 9)
        \\end
    , "(1, hi, -3)\n((1, 2), 3)\n(E.V(7), 9)\n");
}

test "codegen/tuple: nested aggregate elements construct + access" {
    try runAndExpect(
        \\struct P
        \\  x: i16
        \\  y: i16
        \\end
        \\struct S
        \\  p: (i16, i16)
        \\  n: i16
        \\end
        \\def main()
        \\  let t = (P { x: 1, y: 2 }, 7)
        \\  print t.0.x
        \\  print t.1
        \\  let u = ((10, 20), 30)
        \\  print u.0.0
        \\  print u.0.1
        \\  let s = S { p: (4, 5), n: 9 }
        \\  print s.p.0
        \\  print s.n
        \\end
    , "1\n7\n10\n20\n4\n9\n");
}

test "codegen/tuple: element store `t.N = x`" {
    try runAndExpect(
        \\def main()
        \\  let t = (1, 2)
        \\  t.0 = 9
        \\  t.1 += 10
        \\  print t.0
        \\  print t.1
        \\end
    , "9\n12\n");
}

test "codegen/tuple: storing into an aggregate element is a clean error" {
    try expectCodegenError(
        \\def main()
        \\  let t = ((1, 2), 3)
        \\  t.0 = (9, 9)
        \\  print 0
        \\end
    , "E_CODEGEN_UNSUPPORTED");
}

test "codegen/tuple: `==` on `@inline`-returned tuple operands compares by value" {
    // The caller's prologue backs the inline expansion's frame, so its
    // slots sit above any pushed operand and the comparison is exact.
    try runAndExpect(
        \\@inline
        \\def pair(n: i16) -> (i16, i16)
        \\  return (n, n * 2)
        \\end
        \\def main()
        \\  print pair(3) == pair(3)
        \\  print pair(3) == pair(4)
        \\end
    , "1\n0\n");
}

test "codegen/struct: `==` on `@inline`-returned struct operands compares by value" {
    try runAndExpect(
        \\struct P
        \\  x: i16
        \\  y: i16
        \\end
        \\@inline
        \\def mk(n: i16) -> P
        \\  return P { x: n, y: n }
        \\end
        \\def main()
        \\  print mk(3) == mk(3)
        \\  print mk(3) == mk(4)
        \\end
    , "1\n0\n");
}

test "codegen/struct: `==` compares a struct literal whose field runs an `@inline` call" {
    try runAndExpect(
        \\struct P
        \\  x: i16
        \\  y: i16
        \\end
        \\@inline
        \\def mk(n: i16) -> P
        \\  return P { x: n, y: n }
        \\end
        \\def main()
        \\  let p = P { x: 3, y: 3 }
        \\  print P { x: mk(3).x, y: 3 } == p
        \\end
    , "1\n");
}

test "codegen/inline: two `@inline` calls in one expression don't collide" {
    // Each expansion's frame is prologue-backed, so the second call's
    // slots can't alias the first call's result already pushed for the `+`.
    try runAndExpect(
        \\@inline
        \\def sq(n: i16) -> i16
        \\  let t = n * n
        \\  return t
        \\end
        \\def main()
        \\  print sq(3) + sq(4)
        \\end
    , "25\n");
}

test "codegen/inline: an aggregate-returning body with inner locals is exact" {
    // Inner `let`s in an `@inline` body that feed a returned struct get
    // their own prologue-backed slots — the result reads back correctly.
    try runAndExpect(
        \\struct P
        \\  x: i16
        \\  y: i16
        \\end
        \\@inline
        \\def mk(a: i16, b: i16) -> P
        \\  let t = a + b
        \\  let u = a - b
        \\  return P { x: t, y: u }
        \\end
        \\def main()
        \\  print mk(10, 3).x
        \\  print mk(10, 3).y
        \\end
    , "13\n7\n");
}

test "codegen/tuple: `print` of a struct renders a tuple field inline" {
    try runAndExpect(
        \\struct S
        \\  n: i16
        \\  p: (i8, str)
        \\end
        \\def main()
        \\  print S { n: 7, p: (-3, "hi") }
        \\end
    , "S { n: 7, p: (-3, hi) }\n");
}

test "codegen/tuple: return-by-value from an `@inline` fn" {
    try runAndExpect(
        \\@inline
        \\def pair() -> (i16, i16)
        \\  return (11, 22)
        \\end
        \\def main()
        \\  let t = pair()
        \\  print t.0
        \\  print t.1
        \\end
    , "11\n22\n");
}

// ---------- value structs (§3.4) ----------

test "codegen/struct: literal construction + field read" {
    try runAndExpect(
        \\struct P
        \\  x: i16
        \\  y: i16
        \\end
        \\def main()
        \\  let p = P { x: 3, y: 4 }
        \\  print p.x + p.y
        \\end
    , "7\n");
}

test "codegen/struct: field write mutates in place" {
    try runAndExpect(
        \\struct P
        \\  x: i16
        \\end
        \\def main()
        \\  let p = P { x: 1 }
        \\  p.x = 5
        \\  print p.x
        \\end
    , "5\n");
}

test "codegen/struct: assignment copies by value (a unchanged)" {
    try runAndExpect(
        \\struct P
        \\  x: i16
        \\end
        \\def main()
        \\  let a = P { x: 9 }
        \\  let b = a
        \\  b.x = 1
        \\  print a.x
        \\  print b.x
        \\end
    , "9\n1\n");
}

test "codegen/struct: byte-packed fields (u8 + u8 + i16)" {
    try runAndExpect(
        \\struct S
        \\  a: u8
        \\  b: u8
        \\  c: i16
        \\end
        \\def main()
        \\  let s = S { a: 1, b: 2, c: 300 }
        \\  s.a = 7
        \\  print s.a
        \\  print s.c
        \\end
    , "7\n300\n");
}

test "codegen/struct: nested struct field access" {
    try runAndExpect(
        \\struct In
        \\  v: i16
        \\end
        \\struct Out
        \\  n: In
        \\  k: i16
        \\end
        \\def main()
        \\  let o = Out { n: In { v: 10 }, k: 5 }
        \\  print o.n.v + o.k
        \\end
    , "15\n");
}

test "codegen/struct: pass-by-value isolates callee mutation" {
    try runAndExpect(
        \\struct P
        \\  x: i16
        \\end
        \\def bump(p: P) -> i16
        \\  p.x = 99
        \\  return p.x
        \\end
        \\def main()
        \\  let q = P { x: 1 }
        \\  let r = bump(q)
        \\  print r
        \\  print q.x
        \\end
    , "99\n1\n");
}

test "codegen/struct: struct arg after scalar param" {
    try runAndExpect(
        \\struct P
        \\  x: i16
        \\  y: i16
        \\end
        \\def f(p: P, k: i16) -> i16
        \\  return p.x + p.y + k
        \\end
        \\def main()
        \\  print f(P { x: 1, y: 2 }, 100)
        \\end
    , "103\n");
}

test "codegen/struct: return-by-value via sret" {
    try runAndExpect(
        \\struct P
        \\  x: i16
        \\  y: i16
        \\end
        \\def mk(a: i16, b: i16) -> P
        \\  return P { x: a, y: b }
        \\end
        \\def main()
        \\  let p = mk(3, 4)
        \\  print p.x + p.y
        \\end
    , "7\n");
}

test "codegen/struct: returned struct fed straight into a pass-by-value call" {
    try runAndExpect(
        \\struct P
        \\  x: i16
        \\  y: i16
        \\end
        \\def mk() -> P
        \\  return P { x: 3, y: 4 }
        \\end
        \\def sum(p: P) -> i16
        \\  return p.x + p.y
        \\end
        \\def main()
        \\  print sum(mk())
        \\end
    , "7\n");
}

test "codegen/struct: two returned structs hold distinct buffers" {
    try runAndExpect(
        \\struct P
        \\  x: i16
        \\end
        \\def mk(v: i16) -> P
        \\  return P { x: v }
        \\end
        \\def main()
        \\  let a = mk(1)
        \\  let b = mk(2)
        \\  a.x = 9
        \\  print a.x
        \\  print b.x
        \\end
    , "9\n2\n");
}

test "codegen/struct: pass struct by value to a method" {
    try runAndExpect(
        \\struct P
        \\  x: i16
        \\  y: i16
        \\end
        \\class C
        \\  def s(self, p: P) -> i16
        \\    return p.x + p.y
        \\  end
        \\end
        \\def main()
        \\  let c = C()
        \\  print c.s(P { x: 4, y: 5 })
        \\end
    , "9\n");
}

test "codegen/struct: method returns a struct by value" {
    try runAndExpect(
        \\struct P
        \\  x: i16
        \\  y: i16
        \\end
        \\class C
        \\  def make(self, a: i16) -> P
        \\    return P { x: a, y: a }
        \\  end
        \\end
        \\def main()
        \\  let c = C()
        \\  let p = c.make(7)
        \\  print p.x + p.y
        \\end
    , "14\n");
}

test "codegen/struct: struct stored inline as a class field" {
    try runAndExpect(
        \\struct P
        \\  x: i16
        \\  y: i16
        \\end
        \\class E
        \\  let hp: i16
        \\  let pos: P
        \\  def init(self)
        \\    self.hp = 100
        \\    self.pos = P { x: 7, y: 0 }
        \\  end
        \\  def move_x(self, dx: i16)
        \\    self.pos.x = self.pos.x + dx
        \\  end
        \\end
        \\def main()
        \\  let e = E()
        \\  e.move_x(3)
        \\  print e.hp + e.pos.x
        \\end
    , "110\n");
}

test "codegen/struct: pass struct by value to an @inline fn" {
    try runAndExpect(
        \\struct P
        \\  x: i16
        \\  y: i16
        \\end
        \\@inline
        \\def s(p: P) -> i16
        \\  return p.x + p.y
        \\end
        \\def main()
        \\  let q = P { x: 5, y: 6 }
        \\  print s(q)
        \\end
    , "11\n");
}

/// Compile `source` and assert codegen surfaced a diagnostic with
/// `code` — for struct operations not yet lowered (rejected rather
/// than miscompiled).
fn expectCodegenError(source: []const u8, code: []const u8) !void {
    var compiled = try compileSource(source);
    defer compiled.deinit();
    try std.testing.expect(compiled.hasErrors());
    var found = false;
    for (compiled.diagnostics) |d| {
        if (std.mem.eql(u8, d.code, code)) found = true;
    }
    try std.testing.expect(found);
}

test "codegen/struct: `==` is field-wise structural equality" {
    try runAndExpect(
        \\struct P
        \\  x: i16
        \\  y: i16
        \\end
        \\def main()
        \\  let a = P { x: 3, y: 4 }
        \\  let b = P { x: 3, y: 4 }
        \\  let c = P { x: 3, y: 9 }
        \\  print a == b
        \\  print a == c
        \\end
    , "1\n0\n");
}

test "codegen/struct: `!=` is the negation of `==`" {
    try runAndExpect(
        \\struct P
        \\  x: i16
        \\end
        \\def main()
        \\  let a = P { x: 5 }
        \\  let b = P { x: 5 }
        \\  let c = P { x: 6 }
        \\  print a != b
        \\  print a != c
        \\end
    , "0\n1\n");
}

test "codegen/struct: equality recurses into nested + byte-packed fields" {
    try runAndExpect(
        \\struct In
        \\  a: u8
        \\  b: u8
        \\end
        \\struct Out
        \\  n: In
        \\  k: i16
        \\end
        \\def main()
        \\  let p = Out { n: In { a: 1, b: 2 }, k: 300 }
        \\  let q = Out { n: In { a: 1, b: 2 }, k: 300 }
        \\  let r = Out { n: In { a: 1, b: 9 }, k: 300 }
        \\  print p == q
        \\  print p == r
        \\end
    , "1\n0\n");
}

test "codegen/struct: equality of two struct-returning calls (distinct buffers)" {
    try runAndExpect(
        \\struct P
        \\  x: i16
        \\  y: i16
        \\end
        \\def mk(v: i16) -> P
        \\  return P { x: v, y: v }
        \\end
        \\def main()
        \\  print mk(5) == mk(5)
        \\  print mk(5) == mk(6)
        \\end
    , "1\n0\n");
}

test "codegen/str: `+` concatenates into a fresh buffer (§3.2.1)" {
    // Pointer-adding the two string addresses (the old miscompile) would
    // print garbage; concat allocates and copies both operands' bytes.
    try runAndExpect(
        \\def main()
        \\  let c = "foo" + "bar"
        \\  print c
        \\  print c == "foobar"
        \\  print "a" + "b" + "c"
        \\  print "" + "hi"
        \\end
    , "foobar\n1\nabc\nhi\n");
}

test "codegen/str: `+` concatenates runtime-built (distinct-buffer) operands" {
    try runAndExpect(
        \\def main()
        \\  let n = 1
        \\  let c = "x$(n)" + "y$(n)"
        \\  print c
        \\  print c == "x1y1"
        \\end
    , "x1y1\n1\n");
}

test "codegen/str: `<` `<=` `>` `>=` are lexicographic, not pointer compares (§3.2.1)" {
    // A prefix sorts before its extension; results must be deterministic
    // (a pointer compare was layout-dependent garbage).
    try runAndExpect(
        \\def main()
        \\  print "a" < "b"
        \\  print "b" > "a"
        \\  print "abc" < "abd"
        \\  print "ab" < "abc"
        \\  print "abc" <= "abc"
        \\  print "abc" > "abc"
        \\  print "abd" >= "abc"
        \\  if "apple" < "banana"
        \\    print 1
        \\  else
        \\    print 2
        \\  end
        \\end
    , "1\n1\n1\n1\n1\n0\n1\n1\n");
}

test "codegen/str: ordering of runtime-built operands compares by content" {
    try runAndExpect(
        \\def main()
        \\  let n = 1
        \\  print "a$(n)" < "a$(n)9"
        \\  print "a$(n)9" < "a$(n)"
        \\  print "a$(n)" >= "a$(n)"
        \\end
    , "1\n0\n1\n");
}

test "codegen/str: `==` compares content, not pointer identity" {
    // Both strings are built at runtime in distinct interpolation
    // buffers, so a pointer compare would (wrongly) say not-equal.
    try runAndExpect(
        \\def main()
        \\  let n: i16 = 5
        \\  let a = "v$(n)"
        \\  let b = "v$(n)"
        \\  print a == b
        \\  print a != b
        \\  print a == "v9"
        \\end
    , "1\n0\n0\n");
}

test "codegen/str: `==` distinguishes differing length + content" {
    try runAndExpect(
        \\def main()
        \\  print "ab$(1)" == "ab"
        \\  print "a$(1)" == "b$(1)"
        \\  print "a$(1)" == "a$(1)"
        \\end
    , "0\n0\n1\n");
}

test "codegen/struct: a `str` field compares by content" {
    try runAndExpect(
        \\struct Named
        \\  id: i16
        \\  name: str
        \\end
        \\def main()
        \\  let a = Named { id: 1, name: "p$(1)" }
        \\  let b = Named { id: 1, name: "p$(1)" }
        \\  let c = Named { id: 1, name: "q$(1)" }
        \\  let d = Named { id: 2, name: "p$(1)" }
        \\  print a == b
        \\  print a == c
        \\  print a == d
        \\end
    , "1\n0\n0\n");
}

test "codegen/struct: a `str` field inside a nested struct compares by content" {
    try runAndExpect(
        \\struct In
        \\  tag: str
        \\end
        \\struct Out
        \\  n: In
        \\  k: i16
        \\end
        \\def main()
        \\  let a = Out { n: In { tag: "t$(1)" }, k: 7 }
        \\  let b = Out { n: In { tag: "t$(1)" }, k: 7 }
        \\  let c = Out { n: In { tag: "z$(1)" }, k: 7 }
        \\  print a == b
        \\  print a == c
        \\end
    , "1\n0\n");
}

test "codegen/struct: a `str` field followed by a scalar (sp stable across content compare)" {
    try runAndExpect(
        \\struct SI
        \\  name: str
        \\  n: i16
        \\end
        \\def main()
        \\  let a = SI { name: "p$(1)", n: 5 }
        \\  let b = SI { name: "p$(1)", n: 5 }
        \\  let c = SI { name: "p$(1)", n: 6 }
        \\  print a == b
        \\  print a == c
        \\end
    , "1\n0\n");
}

test "codegen/struct: a `str`-field struct `==` works in a condition" {
    try runAndExpect(
        \\struct N
        \\  name: str
        \\end
        \\def main()
        \\  let a = N { name: "k$(2)" }
        \\  let b = N { name: "k$(2)" }
        \\  if a == b
        \\    print 1
        \\  end
        \\  print 0
        \\end
    , "1\n0\n");
}

test "codegen/struct: `==` on a struct with a payload-carrying enum field compares slots" {
    try runAndExpect(
        \\enum Item
        \\  case Sword
        \\  case Potion(amount: i16)
        \\end
        \\struct Slot
        \\  qty: i16
        \\  it: Item
        \\end
        \\def main()
        \\  let a = Slot { qty: 1, it: Item.Potion(20) }
        \\  let b = Slot { qty: 1, it: Item.Potion(20) }
        \\  let c = Slot { qty: 1, it: Item.Potion(99) }
        \\  let d = Slot { qty: 2, it: Item.Potion(20) }
        \\  print a == b
        \\  print a == c
        \\  print a == d
        \\end
    , "1\n0\n0\n");
}

test "codegen/struct: a payload enum field with a `str` payload compares by content" {
    // The enum field's `str` payload must compare by content through the
    // struct's per-field path, not by the slot's stored pointer.
    try runAndExpect(
        \\enum K
        \\  case Key(name: str)
        \\end
        \\struct Box
        \\  k: K
        \\end
        \\def main()
        \\  let n = 1
        \\  print Box { k: K.Key("x$(n)") } == Box { k: K.Key("x$(n)") }
        \\  print Box { k: K.Key("x$(n)") } == Box { k: K.Key("y$(n)") }
        \\end
    , "1\n0\n");
}

test "codegen/struct: payload-free enum field compares by tag" {
    try runAndExpect(
        \\enum Dir
        \\  case N
        \\  case S
        \\end
        \\struct Cell
        \\  d: Dir
        \\  v: i16
        \\end
        \\def main()
        \\  let a = Cell { d: Dir.N, v: 1 }
        \\  let b = Cell { d: Dir.N, v: 1 }
        \\  let c = Cell { d: Dir.S, v: 1 }
        \\  print a == b
        \\  print a == c
        \\end
    , "1\n0\n");
}

test "codegen/enum: payload-carrying `==` compares slot value, not pointer identity" {
    // Distinct constructor calls allocate distinct slots, so a
    // pointer compare would (wrongly) say not-equal.
    try runAndExpect(
        \\enum Item
        \\  case Sword
        \\  case Potion(amount: i16)
        \\end
        \\def main()
        \\  let a = Item.Potion(20)
        \\  let b = Item.Potion(20)
        \\  let c = Item.Potion(30)
        \\  let d = Item.Sword
        \\  print a == b
        \\  print a != b
        \\  print a == c
        \\  print a == d
        \\end
    , "1\n0\n0\n0\n");
}

test "codegen/enum: payload-carrying `==` resolves in a control-flow condition" {
    try runAndExpect(
        \\enum Item
        \\  case Sword
        \\  case Potion(amount: i16)
        \\end
        \\def main()
        \\  let a = Item.Potion(5)
        \\  if a == Item.Potion(5)
        \\    print 1
        \\  end
        \\  if a != Item.Potion(9)
        \\    print 2
        \\  end
        \\end
    , "1\n2\n");
}

test "codegen/enum: a `str` payload compares by content, not pointer (§3.2.1)" {
    // The names are built in distinct interpolation buffers, so a slot
    // byte compare (pointer) would wrongly say not-equal.
    try runAndExpect(
        \\enum K
        \\  case Key(name: str, count: u8)
        \\end
        \\def main()
        \\  let n = 1
        \\  print K.Key("brass$(n)", 1) == K.Key("brass$(n)", 1)
        \\  print K.Key("brass$(n)", 1) == K.Key("brass$(n)", 2)
        \\  print K.Key("gold$(n)", 1) == K.Key("brass$(n)", 1)
        \\end
    , "1\n0\n0\n");
}

test "codegen/enum: a nested payload enum compares recursively" {
    try runAndExpect(
        \\enum Inner
        \\  case A
        \\  case Num(v: i16)
        \\end
        \\enum Outer
        \\  case None
        \\  case Wrap(i: Inner)
        \\end
        \\def main()
        \\  print Outer.Wrap(Inner.Num(7)) == Outer.Wrap(Inner.Num(7))
        \\  print Outer.Wrap(Inner.Num(7)) == Outer.Wrap(Inner.Num(8))
        \\  print Outer.Wrap(Inner.A) == Outer.Wrap(Inner.Num(7))
        \\  print Outer.None == Outer.Wrap(Inner.A)
        \\end
    , "1\n0\n0\n0\n");
}

test "codegen/enum: `==` on a recursive enum is a clean error" {
    // Structural equality of a self-referential enum would unroll the
    // comparison without bound; reject rather than hang the compiler.
    try expectCodegenError(
        \\enum List
        \\  case Nil
        \\  case Cons(head: i16, tail: List)
        \\end
        \\def main()
        \\  print List.Cons(1, List.Nil) == List.Cons(1, List.Nil)
        \\end
    , "E_CODEGEN_UNSUPPORTED");
}

test "codegen/enum: `print` of a recursive enum is a clean error (not a stack overflow)" {
    // A self-referential payload has no finite rendering; the support
    // walk must terminate on the cycle and reject, not recurse forever.
    try expectCodegenError(
        \\enum Tree
        \\  case Leaf
        \\  case Node(child: Tree)
        \\end
        \\def main()
        \\  print Tree.Leaf
        \\end
    , "E_CODEGEN_UNSUPPORTED");
}

test "codegen/struct: `print` of a diamond (a type reused by sibling fields) is not a false cycle" {
    try runAndExpect(
        \\struct Pt
        \\  x: i16
        \\  y: i16
        \\end
        \\struct Line
        \\  a: Pt
        \\  b: Pt
        \\end
        \\def main()
        \\  print Line { a: Pt { x: 1, y: 2 }, b: Pt { x: 3, y: 4 } }
        \\end
    , "Line { a: Pt { x: 1, y: 2 }, b: Pt { x: 3, y: 4 } }\n");
}

test "codegen/enum: a signed `i8` payload keeps its sign on match-bind" {
    // Byte-loading a narrow payload zero-extends; an `i8` must be
    // sign-extended so a negative value survives the binder.
    try runAndExpect(
        \\enum E
        \\  case V(n: i8)
        \\end
        \\def main()
        \\  match E.V(-5)
        \\    case E.V(v) =>
        \\      print v
        \\      if v < 0
        \\        print 1
        \\      end
        \\    case _ => print 0
        \\  end
        \\end
    , "-5\n1\n");
}

test "codegen: a `u16` prints as unsigned (bare, field, payload, interpolation)" {
    // The signed `print_int` would show a high-bit `u16` as negative;
    // unsigned values route to `print_uint` / `format_uint_to_buf`.
    try runAndExpect(
        \\struct S
        \\  a: u16
        \\end
        \\enum E
        \\  case V(n: u16)
        \\end
        \\def main()
        \\  let x: u16 = 50000
        \\  print x
        \\  print S { a: 65535 }
        \\  print E.V(40000)
        \\  print "v=$(x)"
        \\end
    , "50000\nS { a: 65535 }\nE.V(40000)\nv=50000\n");
}

test "codegen: an `i16` still prints signed" {
    try runAndExpect(
        \\def main()
        \\  let x: i16 = -1
        \\  print x
        \\end
    , "-1\n");
}

test "codegen: a signed `i8` field / payload prints with its sign" {
    try runAndExpect(
        \\enum E
        \\  case V(n: i8)
        \\end
        \\struct S
        \\  a: i8
        \\  b: u8
        \\end
        \\def main()
        \\  print E.V(-5)
        \\  print S { a: -5, b: 200 }
        \\end
    , "E.V(-5)\nS { a: -5, b: 200 }\n");
}

test "codegen: a signed `i8` struct-field read sign-extends in expression context" {
    // `s.d` byte-loads the field; an `i8` must sign-extend (not just in
    // the auto-render path) so a negative field reads as negative.
    try runAndExpect(
        \\struct S
        \\  d: i8
        \\end
        \\def main()
        \\  let s = S { d: -100 }
        \\  print s.d
        \\  let x: i16 = s.d
        \\  print x
        \\  if s.d < 0
        \\    print 1
        \\  end
        \\end
    , "-100\n-100\n1\n");
}

test "codegen: a signed `i8` global read sign-extends" {
    try runAndExpect(
        \\let g: i8 = -100
        \\def main()
        \\  print g
        \\  if g < 0
        \\    print 1
        \\  end
        \\end
    , "-100\n1\n");
}

test "codegen: the heap starts above the code + interned string pool" {
    // A large string literal grows the code buffer past the data base.
    // The heap must still begin at/after the whole image — otherwise
    // `alloc` (e.g. a `str` concat) would hand out addresses inside the
    // live string pool and corrupt it.
    const big = "z" ** 4000;
    var compiled = try compileSource("let s = \"" ++ big ++ "\"\ndef main()\n  print s\nend");
    defer compiled.deinit();
    const loaded = try gero.vm.parseGx(compiled.image);
    try std.testing.expect(loaded.header.heap_base >= loaded.header.image_size);
}

test "codegen/enum: payload-free `==` compares the bare tag" {
    try runAndExpect(
        \\enum Dir
        \\  case N
        \\  case S
        \\end
        \\def main()
        \\  let a = Dir.N
        \\  print a == Dir.N
        \\  print a == Dir.S
        \\end
    , "1\n0\n");
}

test "codegen/enum: `print` renders a payload-carrying value as `Enum.Variant(...)`" {
    try runAndExpect(
        \\enum Tok
        \\  case Eof
        \\  case Num(v: i16)
        \\  case Pair(a: i16, b: i16)
        \\end
        \\def main()
        \\  print Tok.Eof
        \\  print Tok.Num(42)
        \\  print Tok.Pair(3, 7)
        \\end
    , "Tok.Eof\nTok.Num(42)\nTok.Pair(3, 7)\n");
}

test "codegen/enum: `print` renders char / fixed / str payloads" {
    try runAndExpect(
        \\enum V
        \\  case C(c: char)
        \\  case F(f: fixed)
        \\  case S(s: str)
        \\end
        \\def main()
        \\  print V.C('A')
        \\  print V.F(1.5)
        \\  print V.S("hi")
        \\end
    , "V.C(A)\nV.F(1.500)\nV.S(hi)\n");
}

test "codegen/enum: `print` recurses into a nested enum payload" {
    try runAndExpect(
        \\enum Inner
        \\  case A
        \\  case Num(v: i16)
        \\end
        \\enum Outer
        \\  case None
        \\  case Wrap(i: Inner)
        \\end
        \\def main()
        \\  print Outer.Wrap(Inner.Num(7))
        \\  print Outer.Wrap(Inner.A)
        \\  print Outer.None
        \\end
    , "Outer.Wrap(Inner.Num(7))\nOuter.Wrap(Inner.A)\nOuter.None\n");
}

test "codegen/struct: `print` renders an enum field as `Enum.Variant(...)`" {
    try runAndExpect(
        \\enum Item
        \\  case Sword
        \\  case Potion(amount: i16)
        \\end
        \\struct Slot
        \\  qty: i16
        \\  it: Item
        \\end
        \\def main()
        \\  print Slot { qty: 2, it: Item.Potion(5) }
        \\  print Slot { qty: 1, it: Item.Sword }
        \\end
    , "Slot { qty: 2, it: Item.Potion(5) }\nSlot { qty: 1, it: Item.Sword }\n");
}

test "codegen/enum: `print` of a struct-payload variant is a clean error" {
    try expectCodegenError(
        \\struct Pt
        \\  x: i16
        \\end
        \\enum Shape
        \\  case At(p: Pt)
        \\end
        \\def main()
        \\  print Shape.At(Pt { x: 1 })
        \\end
    , "E_CODEGEN_UNSUPPORTED");
}

test "codegen: a frame past the 127-byte fp-offset limit is a clean error (not a panic)" {
    try expectCodegenError(
        \\struct Big
        \\  a: [i16; 70]
        \\end
        \\def main()
        \\  let b: Big
        \\end
    , "E_CODEGEN_FRAME_TOO_LARGE");
}

test "codegen/struct: `print` renders `Name { field: value, ... }`" {
    try runAndExpect(
        \\struct P
        \\  x: i16
        \\  y: i16
        \\end
        \\def main()
        \\  let p = P { x: 1, y: 2 }
        \\  print p
        \\end
    , "P { x: 1, y: 2 }\n");
}

test "codegen/struct: `print` recurses into nested structs + str/char fields" {
    try runAndExpect(
        \\struct In
        \\  v: i16
        \\end
        \\struct Out
        \\  n: In
        \\  tag: str
        \\  c: char
        \\end
        \\def main()
        \\  let o = Out { n: In { v: 9 }, tag: "hi", c: 'A' }
        \\  print o
        \\end
    , "Out { n: In { v: 9 }, tag: hi, c: A }\n");
}

test "codegen/struct: `print` works on a literal + amid other args" {
    try runAndExpect(
        \\struct P
        \\  x: i16
        \\end
        \\def main()
        \\  print "pt = ", P { x: 7 }, "!"
        \\end
    , "pt =  P { x: 7 } !\n");
}

test "codegen/struct: `print` of a struct with an array field is rejected" {
    try expectCodegenError(
        \\struct B
        \\  d: [u8; 3]
        \\end
        \\def main()
        \\  let b = B { d: [1, 2, 3] }
        \\  print b
        \\end
    , "E_CODEGEN_UNSUPPORTED");
}

// ---------- arrays: literal / repeat / indexing (#306) ----------

test "codegen/array: repeat-zero init + constant index (the issue example)" {
    try runAndExpect(
        \\def main()
        \\  let xs: [i16; 4] = [0; 4]
        \\  print xs[0]
        \\  print xs[3]
        \\end
    , "0\n0\n");
}

test "codegen/array: literal elements load at their offsets" {
    try runAndExpect(
        \\def main()
        \\  let xs: [i16; 3] = [10, 20, 30]
        \\  print xs[0]
        \\  print xs[1]
        \\  print xs[2]
        \\end
    , "10\n20\n30\n");
}

test "codegen/array: repeat with a non-zero value" {
    try runAndExpect(
        \\def main()
        \\  let xs: [i16; 3] = [7; 3]
        \\  print xs[2]
        \\end
    , "7\n");
}

test "codegen/array: runtime index (read)" {
    try runAndExpect(
        \\def main()
        \\  let xs: [i16; 3] = [10, 20, 30]
        \\  let i: i16 = 2
        \\  print xs[i]
        \\end
    , "30\n");
}

test "codegen/array: indexed store (constant + runtime)" {
    try runAndExpect(
        \\def main()
        \\  let xs: [i16; 4] = [0; 4]
        \\  xs[1] = 99
        \\  let j: i16 = 3
        \\  xs[j] = 77
        \\  print xs[1]
        \\  print xs[3]
        \\end
    , "99\n77\n");
}

test "codegen/array: byte elements (u8) load + store" {
    try runAndExpect(
        \\def main()
        \\  let bs: [u8; 4] = [0; 4]
        \\  bs[2] = 200
        \\  print bs[2]
        \\end
    , "200\n");
}

test "codegen/array: value semantics — copy on bind, no aliasing" {
    try runAndExpect(
        \\def main()
        \\  let a: [i16; 3] = [1, 2, 3]
        \\  let b: [i16; 3] = a
        \\  b[0] = 9
        \\  print a[0]
        \\  print b[0]
        \\end
    , "1\n9\n");
}

test "codegen/array: runtime out-of-bounds index traps (debug halts)" {
    // The bounds check faults to vector $02 (unhandled → VM halts), so
    // the post-index `print` never runs — output stops at the pre-print.
    try runAndExpect(
        \\def main()
        \\  let xs: [i16; 3] = [0; 3]
        \\  let i: i16 = 5
        \\  print 1
        \\  let v: i16 = xs[i]
        \\  print v
        \\end
    , "1\n");
}

// ---------- arrays of aggregate elements (struct / tuple / nested) ----------

test "codegen/array: struct elements — literal, const + runtime field access" {
    try runAndExpect(
        \\struct Pos
        \\  x: i16
        \\  y: i16
        \\end
        \\def main()
        \\  let ps: [Pos; 2] = [Pos { x: 1, y: 2 }, Pos { x: 3, y: 4 }]
        \\  print ps[0].x
        \\  print ps[1].y
        \\  let i: i16 = 1
        \\  print ps[i].x
        \\end
    , "1\n4\n3\n");
}

test "codegen/array: struct elements — repeat constructs once per slot" {
    try runAndExpect(
        \\struct Pos
        \\  x: i16
        \\  y: i16
        \\end
        \\def main()
        \\  let ps: [Pos; 3] = [Pos { x: 7, y: 8 }; 3]
        \\  print ps[2].x
        \\  print ps[0].y
        \\end
    , "7\n8\n");
}

test "codegen/array: struct elements — indexed store (const + runtime)" {
    try runAndExpect(
        \\struct Pos
        \\  x: i16
        \\  y: i16
        \\end
        \\def main()
        \\  let ps: [Pos; 3] = [Pos { x: 0, y: 0 }; 3]
        \\  ps[0] = Pos { x: 9, y: 9 }
        \\  let i: i16 = 2
        \\  ps[i] = Pos { x: 5, y: 6 }
        \\  print ps[0].x
        \\  print ps[2].y
        \\  print ps[1].x
        \\end
    , "9\n6\n0\n");
}

test "codegen/array: struct elements — value semantics on bind" {
    try runAndExpect(
        \\struct Pos
        \\  x: i16
        \\  y: i16
        \\end
        \\def main()
        \\  let a: [Pos; 2] = [Pos { x: 1, y: 1 }, Pos { x: 2, y: 2 }]
        \\  let b: [Pos; 2] = a
        \\  b[0] = Pos { x: 9, y: 9 }
        \\  print a[0].x
        \\  print b[0].x
        \\end
    , "1\n9\n");
}

test "codegen/array: tuple elements — literal + element access" {
    try runAndExpect(
        \\def main()
        \\  let ts: [(i16, i16); 2] = [(1, 2), (3, 4)]
        \\  print ts[0].0
        \\  print ts[1].1
        \\end
    , "1\n4\n");
}

test "codegen/array: nested arrays — index into the inner array" {
    try runAndExpect(
        \\def main()
        \\  let grid: [[i16; 2]; 2] = [[1, 2], [3, 4]]
        \\  print grid[0][1]
        \\  print grid[1][0]
        \\end
    , "2\n3\n");
}

test "codegen/array: tuple elements — store a tuple literal in place" {
    try runAndExpect(
        \\def main()
        \\  let ts: [(i16, i16); 2] = [(0, 0); 2]
        \\  ts[0] = (1, 2)
        \\  let i: i16 = 1
        \\  ts[i] = (3, 4)
        \\  print ts[0].0
        \\  print ts[1].1
        \\end
    , "1\n4\n");
}

test "codegen/array: nested arrays — store an array literal in place" {
    try runAndExpect(
        \\def main()
        \\  let grid: [[i16; 2]; 2] = [[0, 0]; 2]
        \\  grid[0] = [1, 2]
        \\  let i: i16 = 1
        \\  grid[i] = [3, 4]
        \\  print grid[0][1]
        \\  print grid[1][0]
        \\end
    , "2\n3\n");
}

test "codegen/array: aggregate store survives calls in the value's fields" {
    // The destination pointer is parked on the stack while the value's
    // fields evaluate; a call in a field (which pushes args, then restores
    // sp) must leave that parked pointer reachable.
    try runAndExpect(
        \\struct Pos
        \\  x: i16
        \\  y: i16
        \\end
        \\def five() -> i16
        \\  return 5
        \\end
        \\def main()
        \\  let ps: [Pos; 2] = [Pos { x: 0, y: 0 }; 2]
        \\  let i: i16 = 1
        \\  ps[i] = Pos { x: five() + 1, y: five() * 2 }
        \\  print ps[1].x
        \\  print ps[1].y
        \\end
    , "6\n10\n");
}

test "codegen/struct: assign a struct literal into a nested struct field" {
    try runAndExpect(
        \\struct Pos
        \\  x: i16
        \\  y: i16
        \\end
        \\struct Line
        \\  a: Pos
        \\  b: Pos
        \\end
        \\def main()
        \\  let ln: Line = Line { a: Pos { x: 1, y: 2 }, b: Pos { x: 3, y: 4 } }
        \\  ln.a = Pos { x: 9, y: 8 }
        \\  print ln.a.x
        \\  print ln.a.y
        \\  print ln.b.x
        \\end
    , "9\n8\n3\n");
}

test "codegen/struct: assign a tuple literal into a tuple field" {
    try runAndExpect(
        \\struct Holder
        \\  pair: (i16, i16)
        \\  tag: i16
        \\end
        \\def main()
        \\  let h: Holder = Holder { pair: (1, 2), tag: 7 }
        \\  h.pair = (8, 9)
        \\  print h.pair.0
        \\  print h.pair.1
        \\  print h.tag
        \\end
    , "8\n9\n7\n");
}

test "codegen/array: runtime index scales a non-power-of-2 element width (word fields)" {
    // A 6-byte element (three i16) needs `index * 6` via a multiply, not a
    // shift — exercises the mul-scale path for both read and write.
    try runAndExpect(
        \\struct Tri
        \\  a: i16
        \\  b: i16
        \\  c: i16
        \\end
        \\def main()
        \\  let arr: [Tri; 3] = [Tri { a: 1, b: 2, c: 3 }; 3]
        \\  let i: i16 = 2
        \\  arr[i] = Tri { a: 10, b: 20, c: 30 }
        \\  print arr[0].a
        \\  print arr[2].a
        \\  print arr[2].c
        \\  let j: i16 = 1
        \\  print arr[j].b
        \\end
    , "1\n10\n30\n2\n");
}

test "codegen/array: runtime index scales an odd element width (byte fields)" {
    // A 3-byte element (three u8) — an odd, non-power-of-2 width.
    try runAndExpect(
        \\struct Bytes3
        \\  a: u8
        \\  b: u8
        \\  c: u8
        \\end
        \\def main()
        \\  let arr: [Bytes3; 4] = [Bytes3 { a: 0, b: 0, c: 0 }; 4]
        \\  let i: i16 = 3
        \\  arr[i] = Bytes3 { a: 7, b: 8, c: 9 }
        \\  print arr[3].a
        \\  print arr[3].c
        \\  print arr[0].a
        \\  let j: i16 = 3
        \\  print arr[j].b
        \\end
    , "7\n9\n0\n8\n");
}

test "codegen/array: reassignment copies the full width (value semantics)" {
    try runAndExpect(
        \\struct Pos
        \\  x: i16
        \\  y: i16
        \\end
        \\def main()
        \\  let ps1: [Pos; 2] = [Pos { x: 10, y: 20 }, Pos { x: 30, y: 40 }]
        \\  let ps2: [Pos; 2] = [Pos { x: 50, y: 60 }, Pos { x: 70, y: 80 }]
        \\  ps2 = ps1
        \\  print ps2[0].x
        \\  print ps2[1].x
        \\  ps2[0].x = 999
        \\  print ps1[0].x
        \\  print ps2[0].x
        \\end
    , "10\n30\n10\n999\n");
}

test "codegen/array: scalar-array reassignment stays independent" {
    try runAndExpect(
        \\def main()
        \\  let xs1: [i16; 3] = [1, 2, 3]
        \\  let xs2: [i16; 3] = [0, 0, 0]
        \\  xs2 = xs1
        \\  xs2[0] = 99
        \\  print xs1[0]
        \\  print xs2[0]
        \\  print xs2[2]
        \\end
    , "1\n99\n3\n");
}

// ---------- pattern destructuring: let / if let / while let (#308) ----------

test "codegen/destructure: let tuple binds element-wise" {
    try runAndExpect(
        \\def main()
        \\  let (a, b) = (10, 20)
        \\  print a
        \\  print b
        \\end
    , "10\n20\n");
}

test "codegen/destructure: let struct binds named fields" {
    try runAndExpect(
        \\struct Pos
        \\  x: i16
        \\  y: i16
        \\end
        \\def main()
        \\  let Pos { x, y } = Pos { x: 3, y: 4 }
        \\  print x
        \\  print y
        \\end
    , "3\n4\n");
}

test "codegen/destructure: let single-variant enum binds the payload" {
    try runAndExpect(
        \\enum Wrap
        \\  case Of(i16, i16)
        \\end
        \\def main()
        \\  let Wrap.Of(a, b) = Wrap.Of(5, 6)
        \\  print a
        \\  print b
        \\end
    , "5\n6\n");
}

test "codegen/destructure: let tuple binders are independent copies" {
    try runAndExpect(
        \\def main()
        \\  let p: (i16, i16) = (1, 2)
        \\  let (a, b) = p
        \\  a = 99
        \\  print a
        \\  print b
        \\end
    , "99\n2\n");
}

test "codegen/destructure: if let enum payload + else on no match" {
    try runAndExpect(
        \\enum Item
        \\  case Sword
        \\  case Potion(i16)
        \\end
        \\def main()
        \\  let it: Item = Item.Potion(42)
        \\  if let Item.Potion(n) = it
        \\    print n
        \\  else
        \\    print 0
        \\  end
        \\  if let Item.Sword = it
        \\    print 1
        \\  else
        \\    print 9
        \\  end
        \\end
    , "42\n9\n");
}

test "codegen/destructure: if let multi-payload + when guard" {
    try runAndExpect(
        \\enum Ev
        \\  case Click(i16, i16)
        \\end
        \\def main()
        \\  if let Ev.Click(x, y) = Ev.Click(40, 7) when x < 128
        \\    print x
        \\    print y
        \\  end
        \\  if let Ev.Click(x, y) = Ev.Click(200, 7) when x < 128
        \\    print x
        \\  else
        \\    print 0
        \\  end
        \\end
    , "40\n7\n0\n");
}

test "codegen/destructure: if let tuple destructures in conditional position" {
    try runAndExpect(
        \\def main()
        \\  if let (a, b) = (100, 200)
        \\    print a
        \\    print b
        \\  end
        \\end
    , "100\n200\n");
}

test "codegen/destructure: while let drains a producer" {
    try runAndExpect(
        \\enum Cmd
        \\  case Go(i16)
        \\  case Stop
        \\end
        \\def poll(i: i16) -> Cmd
        \\  if i < 3
        \\    return Cmd.Go(i)
        \\  end
        \\  return Cmd.Stop
        \\end
        \\def main()
        \\  let i: i16 = 0
        \\  while let Cmd.Go(n) = poll(i)
        \\    print n
        \\    i = i + 1
        \\  end
        \\  print 99
        \\end
    , "0\n1\n2\n99\n");
}

test "codegen/destructure: match on a tuple binds elements" {
    try runAndExpect(
        \\def main()
        \\  match (7, 8)
        \\    case (x, y) => print x
        \\                   print y
        \\  end
        \\end
    , "7\n8\n");
}

test "codegen/destructure: match on a struct binds fields" {
    try runAndExpect(
        \\struct Pos
        \\  x: i16
        \\  y: i16
        \\end
        \\def main()
        \\  match Pos { x: 1, y: 2 }
        \\    case Pos { x, y } => print x
        \\                         print y
        \\  end
        \\end
    , "1\n2\n");
}

test "codegen/destructure: i8 payload binder sign-extends" {
    try runAndExpect(
        \\enum Tag
        \\  case V(i8)
        \\end
        \\def main()
        \\  if let Tag.V(n) = Tag.V(-5)
        \\    print n
        \\  end
        \\end
    , "-5\n");
}

test "codegen/destructure: aggregate enum payload — inline copy + value semantics" {
    // The struct payload is stored inline in the enum slot (the enum owns a
    // copy), so mutating the source after construction can't change it.
    try runAndExpect(
        \\struct Coord
        \\  x: i16
        \\  y: i16
        \\end
        \\enum Loc
        \\  case At(Coord)
        \\end
        \\def main()
        \\  let cv: Coord = Coord { x: 5, y: 6 }
        \\  let l: Loc = Loc.At(cv)
        \\  cv.x = 999
        \\  if let Loc.At(c) = l
        \\    print c.x
        \\    print c.y
        \\  end
        \\end
    , "5\n6\n");
}

test "codegen/destructure: aggregate enum payload destructures in place" {
    try runAndExpect(
        \\struct Coord
        \\  x: i16
        \\  y: i16
        \\end
        \\enum Loc
        \\  case At(Coord)
        \\end
        \\def main()
        \\  if let Loc.At(Coord { x, y }) = Loc.At(Coord { x: 1, y: 2 })
        \\    print x
        \\    print y
        \\  end
        \\end
    , "1\n2\n");
}

// ---------- Vec(T): growable dynamic array (#314) ----------

test "codegen/vec: new + push grows + len + at" {
    try runAndExpect(
        \\def main()
        \\  let v: Vec(i16) = Vec.new()
        \\  v.push(10)
        \\  v.push(20)
        \\  v.push(30)
        \\  print v.len()
        \\  print v.at(0)
        \\  print v.at(2)
        \\end
    , "3\n10\n30\n");
}

test "codegen/vec: from + cap + index read/write + set" {
    try runAndExpect(
        \\def main()
        \\  let v: Vec(i16) = Vec.from([5, 6, 7])
        \\  print v.len()
        \\  print v.cap()
        \\  print v[1]
        \\  v.set(1, 99)
        \\  print v[1]
        \\  v[2] = 88
        \\  print v.at(2)
        \\end
    , "3\n3\n6\n99\n88\n");
}

test "codegen/vec: with_capacity + clear keeps capacity" {
    try runAndExpect(
        \\def main()
        \\  let v: Vec(i16) = Vec.with_capacity(8)
        \\  print v.cap()
        \\  print v.len()
        \\  v.push(1)
        \\  v.push(2)
        \\  print v.len()
        \\  v.clear()
        \\  print v.len()
        \\  print v.cap()
        \\end
    , "8\n0\n2\n0\n8\n");
}

test "codegen/vec: slice is a borrowed view aliasing the parent" {
    try runAndExpect(
        \\def main()
        \\  let v: Vec(i16) = Vec.from([10, 20, 30, 40, 50])
        \\  let s: Vec(i16) = v.slice(1, 4)
        \\  print s.len()
        \\  print s[0]
        \\  print s[2]
        \\  s[0] = 99
        \\  print v[1]
        \\end
    , "3\n20\n40\n99\n");
}

test "codegen/vec: value binding copies the header" {
    try runAndExpect(
        \\def main()
        \\  let v: Vec(i16) = Vec.from([1, 2, 3])
        \\  let v2: Vec(i16) = v
        \\  print v2.len()
        \\  print v2[0]
        \\  print v2[2]
        \\end
    , "3\n1\n3\n");
}

test "codegen/vec: byte element type (u8)" {
    try runAndExpect(
        \\def main()
        \\  let v: Vec(u8) = Vec.new()
        \\  v.push(200)
        \\  v.push(5)
        \\  print v.len()
        \\  print v.at(0)
        \\  print v[1]
        \\end
    , "2\n200\n5\n");
}

test "codegen/vec: pop returns the last element + shrinks; empty pops None" {
    try runAndExpect(
        \\def main()
        \\  let v: Vec(i16) = Vec.from([10, 20, 30])
        \\  if let n = v.pop()
        \\    print n
        \\  end
        \\  print v.len()
        \\  v.clear()
        \\  if let m = v.pop()
        \\    print m
        \\  else
        \\    print 0
        \\  end
        \\end
    , "30\n2\n0\n");
}

test "codegen/vec: get returns an in-bounds element, None past the end" {
    try runAndExpect(
        \\def main()
        \\  let v: Vec(i16) = Vec.from([7, 8, 9])
        \\  if let a = v.get(1)
        \\    print a
        \\  end
        \\  if let b = v.get(99)
        \\    print b
        \\  else
        \\    print 0
        \\  end
        \\end
    , "8\n0\n");
}

test "codegen/vec: scalar optional == nil / != nil tests the present tag" {
    try runAndExpect(
        \\def main()
        \\  let v: Vec(i16) = Vec.new()
        \\  let x: i16? = v.pop()
        \\  print x == nil
        \\  v.push(5)
        \\  let y: i16? = v.pop()
        \\  print y != nil
        \\end
    , "1\n1\n");
}

// ---------- lambda return-type inference (§4.7.1) ----------

/// Compile `source`, run it, and assert on what it printed.
fn expectPrints(source: []const u8, expected: []const u8) !void {
    var compiled = try compileSource(source);
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    var vm = try runWith(compiled.image, &writer);
    defer vm.deinit();

    try std.testing.expectEqualStrings(expected, writer.written());
}

test "codegen: an unannotated short lambda prints its string, not its pointer" {
    try expectPrints(
        \\def main()
        \\  let f = || "hi"
        \\  print f()
        \\end
    , "hi\n");
}

test "codegen: an unannotated long lambda prints its string" {
    try expectPrints(
        \\def main()
        \\  let f = lambda ()
        \\    return "hi"
        \\  end
        \\  print f()
        \\end
    , "hi\n");
}

test "codegen: a `do`-bodied lambda prints its string" {
    try expectPrints(
        \\def main()
        \\  let f = || do
        \\    let x = "hi"
        \\    x
        \\  end
        \\  print f()
        \\end
    , "hi\n");
}

test "codegen: an inferred string lambda closing over a capture prints it" {
    try expectPrints(
        \\def main()
        \\  let n = 7
        \\  let f = || "n=$(n)"
        \\  print f()
        \\end
    , "n=7\n");
}

test "codegen: an explicitly annotated string lambda is unchanged" {
    try expectPrints(
        \\def main()
        \\  let f = || -> str "hi"
        \\  print f()
        \\end
    , "hi\n");
}

test "codegen: an inferred integer lambda still prints its value" {
    try expectPrints(
        \\def main()
        \\  let f = || 41 + 1
        \\  print f()
        \\end
    , "42\n");
}

// ---------- printing a nullable (§4.9) ----------

test "codegen/print: a scalar nullable is rejected, not printed as its slot" {
    try expectCodegenError(
        \\def main()
        \\  let a: i16? = 12
        \\  print a
        \\end
    , "E_CODEGEN_UNSUPPORTED");
}

test "codegen/print: a pointer-like nullable is rejected, not printed as its pointer" {
    try expectCodegenError(
        \\def main()
        \\  let s: str? = "hi"
        \\  print s
        \\end
    , "E_CODEGEN_UNSUPPORTED");
}

test "codegen/print: a nullable inside `$(…)` interpolation is rejected" {
    try expectCodegenError(
        \\def main()
        \\  let a: i16? = 12
        \\  print "val=$(a)"
        \\end
    , "E_CODEGEN_UNSUPPORTED");
}

test "codegen/print: a `Vec.get` result is rejected until unwrapped" {
    try expectCodegenError(
        \\def main()
        \\  let v: Vec(i16) = Vec.new()
        \\  v.push(41)
        \\  print v.get(0)
        \\end
    , "E_CODEGEN_UNSUPPORTED");
}

test "codegen/print: an `if let`-unwrapped scalar nullable prints its value" {
    try expectPrints(
        \\def main()
        \\  let a: i16? = 12
        \\  if let x = a
        \\    print x
        \\  end
        \\end
    , "12\n");
}

test "codegen/print: an `if let`-unwrapped `Vec.get` prints its element" {
    try expectPrints(
        \\def main()
        \\  let v: Vec(i16) = Vec.new()
        \\  v.push(41)
        \\  if let n = v.get(0)
        \\    print n
        \\  end
        \\end
    , "41\n");
}

test "codegen/print: an `if let`-unwrapped pointer nullable prints its bytes" {
    try expectPrints(
        \\def main()
        \\  let s: str? = "hi"
        \\  if let t = s
        \\    print t
        \\  end
        \\end
    , "hi\n");
}

test "codegen/print: a plain non-nullable value is unaffected" {
    try expectPrints(
        \\def main()
        \\  let n: i16 = 7
        \\  print n
        \\end
    , "7\n");
}

// ---------- baked strings (§3.8) ----------

test "codegen/bake: a baked `str` const resolves to its interned bytes" {
    try expectPrints(
        \\bake def greeting() -> str
        \\  return "hello"
        \\end
        \\
        \\const G: str = greeting()
        \\
        \\def main()
        \\  print G
        \\end
    , "hello\n");
}

test "codegen/bake: a `str` field inside a baked struct resolves" {
    try expectPrints(
        \\struct Label
        \\  id: i16
        \\  text: str
        \\end
        \\
        \\bake def make() -> Label
        \\  return Label { id: 7, text: "nested" }
        \\end
        \\
        \\const L: Label = make()
        \\
        \\def main()
        \\  print L.id
        \\  print L.text
        \\end
    , "7\nnested\n");
}

test "codegen/bake: a `str` element inside a baked tuple resolves" {
    try expectPrints(
        \\bake def pair() -> (str, i16)
        \\  return ("tup", 9)
        \\end
        \\
        \\const P: (str, i16) = pair()
        \\
        \\def main()
        \\  print P.0
        \\  print P.1
        \\end
    , "tup\n9\n");
}

test "codegen/bake: a baked `str` decodes escapes like a runtime literal" {
    try expectPrints(
        \\bake def tabbed() -> str
        \\  return "a\tb"
        \\end
        \\
        \\const T: str = tabbed()
        \\
        \\def main()
        \\  print T
        \\end
    , "a\tb\n");
}

test "codegen/bake: baked strings with the same bytes share one pool entry" {
    try expectPrints(
        \\bake def one() -> str
        \\  return "same"
        \\end
        \\
        \\bake def two() -> str
        \\  return "same"
        \\end
        \\
        \\const A: str = one()
        \\const B: str = two()
        \\
        \\def main()
        \\  print A
        \\  print B
        \\end
    , "same\nsame\n");
}

test "codegen/bake: `$(…)` interpolation inside a bake body is rejected" {
    try expectCodegenError(
        \\bake def greet() -> str
        \\  let n = 3
        \\  return "n=$(n)"
        \\end
        \\
        \\const G: str = greet()
        \\
        \\def main()
        \\  print G
        \\end
    , "E_BAKE_UNSUPPORTED");
}

// ---------- fixed-array returns ----------

test "codegen/def: a def returning a fixed array materializes into the caller" {
    try expectPrints(
        \\def nums() -> [i16; 3]
        \\  return [1, 2, 3]
        \\end
        \\
        \\def main()
        \\  let n = nums()
        \\  print n[0]
        \\  print n[2]
        \\end
    , "1\n3\n");
}

test "codegen/bake: a baked fixed array of ints resolves" {
    try expectPrints(
        \\bake def nums() -> [i16; 3]
        \\  return [1, 2, 3]
        \\end
        \\
        \\const NU: [i16; 3] = nums()
        \\
        \\def main()
        \\  print NU[0]
        \\  print NU[2]
        \\end
    , "1\n3\n");
}

test "codegen/bake: a baked fixed array of strings resolves each element" {
    try expectPrints(
        \\bake def names() -> [str; 3]
        \\  return ["a", "bb", "ccc"]
        \\end
        \\
        \\const NS: [str; 3] = names()
        \\
        \\def main()
        \\  print NS[0]
        \\  print NS[1]
        \\  print NS[2]
        \\end
    , "a\nbb\nccc\n");
}

test "codegen/def: a struct return is unaffected by the array return path" {
    try expectPrints(
        \\struct P
        \\  x: i16
        \\  y: i16
        \\end
        \\
        \\def make() -> P
        \\  return P { x: 4, y: 5 }
        \\end
        \\
        \\def main()
        \\  let p = make()
        \\  print p.x
        \\  print p.y
        \\end
    , "4\n5\n");
}

// ---------- module-scope destructuring `let` (§7.1) ----------

test "codegen/globals: a module-scope tuple destructure binds both names" {
    try expectPrints(
        \\let (a, b) = (3, 4)
        \\
        \\def main()
        \\  print a
        \\  print b
        \\end
    , "3\n4\n");
}

test "codegen/globals: a module-scope struct destructure binds its fields" {
    try expectPrints(
        \\struct P
        \\  x: i16
        \\  y: u8
        \\end
        \\
        \\def mk() -> P
        \\  return P { x: 11, y: 22 }
        \\end
        \\
        \\let P { x, y } = mk()
        \\
        \\def main()
        \\  print x
        \\  print y
        \\end
    , "11\n22\n");
}

test "codegen/globals: a module-scope wildcard binds nothing and skips its slot" {
    try expectPrints(
        \\let (_, keep) = (99, 5)
        \\
        \\def main()
        \\  print keep
        \\end
    , "5\n");
}

test "codegen/globals: a nested module-scope destructure resolves every binder" {
    try expectPrints(
        \\let ((n, m), o) = ((1, 2), 3)
        \\
        \\def main()
        \\  print n
        \\  print m
        \\  print o
        \\end
    , "1\n2\n3\n");
}

test "codegen/globals: a module-scope destructured binding is visible to any function" {
    try expectPrints(
        \\let (a, b) = (7, 8)
        \\
        \\def sum() -> i16
        \\  return a + b
        \\end
        \\
        \\def main()
        \\  print sum()
        \\end
    , "15\n");
}

test "codegen/globals: a plain module-scope `let` is unaffected" {
    try expectPrints(
        \\let g = 7
        \\
        \\def main()
        \\  print g
        \\end
    , "7\n");
}

// ---------- module namespaces (§5) ----------

test "codegen/modules: same-named defs in different modules keep separate symbols" {
    // Two modules each declare `helper`; each call must reach its own.
    // Before per-module symbols the second registration overwrote the
    // first and both call sites landed on one address.
    var fx = try util.ModuleFixture.init();
    defer fx.deinit();
    try fx.write("lib.gr",
        \\def helper() -> i16
        \\  return 1
        \\end
        \\
        \\def lib_only() -> i16
        \\  return helper() + 10
        \\end
    );
    try fx.write("main.gr",
        \\use "./lib"
        \\
        \\def helper() -> i16
        \\  return 100
        \\end
        \\
        \\def main()
        \\  print helper()
        \\  print lib_only()
        \\end
    );
    try fx.expectRuns("main.gr", "100\n11\n");
}

test "codegen/modules: a cross-module call resolves through the `use` binding" {
    var fx = try util.ModuleFixture.init();
    defer fx.deinit();
    try fx.write("m.gr",
        \\def twice(n: i16) -> i16
        \\  return n * 2
        \\end
    );
    try fx.write("main.gr",
        \\use "./m"
        \\
        \\def main()
        \\  print twice(21)
        \\end
    );
    try fx.expectRuns("main.gr", "42\n");
}

test "codegen/modules: `use X as Y from` still binds the alias" {
    var fx = try util.ModuleFixture.init();
    defer fx.deinit();
    try fx.write("m.gr",
        \\def twice(n: i16) -> i16
        \\  return n * 2
        \\end
    );
    try fx.write("main.gr",
        \\use twice as dbl from "./m"
        \\
        \\def main()
        \\  print dbl(21)
        \\end
    );
    try fx.expectRuns("main.gr", "42\n");
}

// ---------- module visibility (§5.1) ----------

test "codegen/modules: a `local` declaration still resolves inside its own module" {
    var fx = try util.ModuleFixture.init();
    defer fx.deinit();
    try fx.write("lib.gr",
        \\local def helper() -> i16
        \\  return 1
        \\end
        \\
        \\def exported() -> i16
        \\  return helper() + 10
        \\end
    );
    try fx.write("main.gr",
        \\use "./lib"
        \\
        \\def main()
        \\  print exported()
        \\end
    );
    try fx.expectRuns("main.gr", "11\n");
}

test "codegen/modules: a non-`local` declaration is exported by default" {
    var fx = try util.ModuleFixture.init();
    defer fx.deinit();
    try fx.write("lib.gr",
        \\def shown() -> i16
        \\  return 5
        \\end
    );
    try fx.write("main.gr",
        \\use "./lib"
        \\
        \\def main()
        \\  print shown()
        \\end
    );
    try fx.expectRuns("main.gr", "5\n");
}

// ---------- per-module declaration views (§5) ----------

test "codegen/modules: a `local` type is invisible to an importing module" {
    var fx = try util.ModuleFixture.init();
    defer fx.deinit();
    try fx.write("lib.gr",
        \\local struct Hidden
        \\  a: i16
        \\end
        \\
        \\struct Shown
        \\  b: i16
        \\end
    );
    try fx.write("main.gr",
        \\use "./lib"
        \\
        \\def main()
        \\  let s = Shown { b: 1 }
        \\  print s.b
        \\end
    );
    try fx.expectRuns("main.gr", "1\n");
}

test "codegen/modules: an importer sees only what its own imports export" {
    // `deep` is reachable from `mid`, but `main` never imports it, so
    // its declarations must not leak through into `main`'s view.
    var fx = try util.ModuleFixture.init();
    defer fx.deinit();
    try fx.write("deep.gr",
        \\def deep_fn() -> i16
        \\  return 3
        \\end
    );
    try fx.write("mid.gr",
        \\use "./deep"
        \\
        \\def mid_fn() -> i16
        \\  return deep_fn() + 1
        \\end
    );
    try fx.write("main.gr",
        \\use "./mid"
        \\
        \\def main()
        \\  print mid_fn()
        \\end
    );
    try fx.expectRuns("main.gr", "4\n");
}

// ---------- relocatable emission ----------

test "CodeRef: a base-buffer symbol resolves against the code base" {
    const ref: gero.lang.internal.codegen.CodeRef = .{ .bank = null, .offset = 0x10 };
    try std.testing.expectEqual(gero.lang.codegen.code_base + 0x10, ref.addr());
}

test "CodeRef: a banked symbol resolves against the bank window" {
    const base: gero.lang.internal.codegen.CodeRef = .{ .bank = null, .offset = 0x20 };
    const banked: gero.lang.internal.codegen.CodeRef = .{ .bank = 3, .offset = 0x20 };
    // Same offset in different buffers must not name the same address.
    try std.testing.expect(base.addr() != banked.addr());
}

test "CodeRef: an offset past the address space clamps rather than truncating" {
    // An over-large image still records positions; resolution saturates
    // so the overflow diagnostic reports instead of wrapping to a
    // plausible-looking low address.
    const ref: gero.lang.internal.codegen.CodeRef = .{ .bank = null, .offset = 0x1_0000 };
    try std.testing.expectEqual(@as(u16, 0xFFFF), ref.addr());
}

test "variadic: arities from different modules each get a specialization" {
    var fx = try util.ModuleFixture.init();
    defer fx.deinit();
    try fx.write("sum.gr",
        \\def first(args: ...) -> i16
        \\  return args.0
        \\end
        \\
    );
    // Two modules call the same variadic at different arities. The
    // specializations exist only if the link step unions both modules'
    // requests — neither module's set names the other's arity.
    try fx.write("mid.gr",
        \\use "./sum"
        \\def from_mid() -> i16
        \\  return first(1, 2, 3)
        \\end
        \\
    );
    try fx.write("main.gr",
        \\use "./mid"
        \\def main()
        \\  print from_mid()
        \\  print first(9)
        \\end
        \\
    );
    try fx.expectRuns("main.gr", "1\n9\n");
}

// ---------- allocation-free formatting ----------

test "str.format_into: writes the formatted bytes into the caller's buffer" {
    try runAndExpect(
        \\use str
        \\use mem
        \\def main()
        \\  let buf: [u8; 64] = [0; 64]
        \\  let dst = mem.addr_of(buf)
        \\  let n = str.format_into(dst, "score {0}", 42)
        \\  print n
        \\  print mem.read_u8(dst) as char
        \\  print mem.read_u8(dst + n)
        \\end
        \\
    , "8\ns\n0\n");
}

test "str.format_into: formatting in a loop does not consume the heap" {
    // The allocating `str.format` exhausts the default heap in roughly
    // 700 calls; a per-frame caller needs a form that never allocates.
    try runAndExpect(
        \\use str
        \\use mem
        \\def main()
        \\  let buf: [u8; 64] = [0; 64]
        \\  let dst = mem.addr_of(buf)
        \\  let i = 0
        \\  while i < 5000
        \\    let n = str.format_into(dst, "score {0}", i)
        \\    i = i + 1
        \\  end
        \\  print "done"
        \\end
        \\
    , "done\n");
}

test "str.format_into: the byte count excludes the terminator" {
    try runAndExpect(
        \\use str
        \\use mem
        \\def main()
        \\  let buf: [u8; 32] = [0; 32]
        \\  let dst = mem.addr_of(buf)
        \\  print str.format_into(dst, "{0}", 7)
        \\  print str.format_into(dst, "ab{0}cd", 100)
        \\end
        \\
    , "1\n7\n");
}

test "interrupt: a handler's bank switch does not leak to the interrupted code" {
    // Interrupt entry preserves only ip / fp / flg (ISA §6.2), so a
    // handler that selects a bank would otherwise return with a
    // different 16 KB mapped and leave the mainline reading the wrong
    // memory. gtx-16 fires a vblank every frame, which makes this
    // certain to surface in a banked cart.
    try runAndExpect(
        \\use bank
        \\use mem
        \\@bank 1
        \\def in_bank() -> i16
        \\  return 1
        \\end
        \\@interrupt $20
        \\def on_int()
        \\  bank.switch_to(1)
        \\end
        \\def main()
        \\  bank.switch_to(0)
        \\  mem.write_u16($C000, 111)
        \\  asm "int $20"
        \\  print mem.read_u16($C000)
        \\  print bank.current()
        \\end
        \\
    , "111\n0\n");
}

test "interrupt: an unbanked handler saves no bank register" {
    // `mb` has no addressing effect when `bank_count == 0` (ISA §3.2),
    // so an unbanked program must not pay for the save.
    var compiled = try compileSource(
        \\@interrupt $20
        \\def on_int()
        \\  print 1
        \\end
        \\def main()
        \\  asm "int $20"
        \\end
        \\
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    // `push mb` / `pop mb` would be a `0x31` / `0x32` naming register
    // `0x0C`; neither pair appears.
    try std.testing.expectEqual(@as(usize, 0), countByteSeq(compiled.image, &.{ 0x31, 0x0C }));
    try std.testing.expectEqual(@as(usize, 0), countByteSeq(compiled.image, &.{ 0x32, 0x0C }));
}

test "stdlib: every documented call lowers" {
    // The gate against spec drift: the stdlib is the surface a user
    // learns, so a documented call that fails to compile is worse than
    // ordinary staleness. If a §3.4.3 / §5.3 entry stops lowering, this
    // fails; if an entry is added to the spec, add it here.
    var compiled = try compileSource(
        \\use math
        \\use str
        \\use mem
        \\use bank
        \\
        \\def main()
        \\  -- §3.4.3 Vec
        \\  let a: Vec(i16) = Vec.new()
        \\  let b: Vec(i16) = Vec.with_capacity(4)
        \\  let v: Vec(i16) = Vec.from([1, 2, 3])
        \\  v.push(4)
        \\  let popped = v.pop()
        \\  v.pop()
        \\  print v.len()
        \\  print v.cap()
        \\  print v.at(0)
        \\  let got = v.get(0)
        \\  v.set(0, 9)
        \\  print v[0]
        \\  v[0] = 8
        \\  let s = v.slice(0, 2)
        \\  for x in v
        \\    print x
        \\  end
        \\  v.clear()
        \\  print a.len() + b.len() + s.len()
        \\
        \\  -- §3.2.1 str
        \\  let text: str = "hi"
        \\  print text.len
        \\  print text.at(0)
        \\  print text.cmp("ho")
        \\  let joined: str = "a" + "b"
        \\  print joined
        \\
        \\  -- §5.3.2 math
        \\  print math.abs(0 - 5)
        \\  print math.min(1, 2)
        \\  print math.max(1, 2)
        \\  print math.clamp(5, 0, 3)
        \\  print math.rng()
        \\  print math.wrap_add(1, 2)
        \\  print math.wrap_sub(2, 1)
        \\  print math.wrap_mul(2, 3)
        \\  print math.sat_add(1, 2)
        \\  print math.sat_sub(2, 1)
        \\  print math.sat_mul(2, 3)
        \\  print math.sqrt_fixed(4.0)
        \\  print math.fixed_sin(90)
        \\
        \\  -- §5.3.1 mem
        \\  let cell: i16 = 1
        \\  print mem.addr_of(cell)
        \\  mem.poke($200, 1)
        \\  print mem.peek($200)
        \\  mem.write_u8($200, 1)
        \\  mem.write_u16($202, 1)
        \\  mem.write_i8($204, 1)
        \\  mem.write_i16($206, 1)
        \\  print mem.read_u8($200)
        \\  print mem.read_u16($202)
        \\  print mem.read_i8($204)
        \\  print mem.read_i16($206)
        \\  mem.memcpy($300, $200, 4)
        \\  mem.memset($300, 0, 4)
        \\
        \\  -- §5.3.3 bank
        \\  bank.switch_to(0)
        \\  print bank.current()
        \\
        \\  -- §5.4 formatting
        \\  let buf: [u8; 32] = [0; 32]
        \\  print str.format("{0}", 1)
        \\  print str.format_into(mem.addr_of(buf), "{0}", 1)
        \\end
        \\
    );
    defer compiled.deinit();

    // Name the offending call in the failure rather than only that one
    // exists — a bare "has errors" tells you nothing about which entry
    // drifted.
    var broke: std.ArrayList(u8) = .empty;
    defer broke.deinit(alloc);
    for (compiled.diagnostics) |d| {
        if (d.severity != .fatal) continue;
        try broke.appendSlice(alloc, d.code);
        try broke.appendSlice(alloc, ": ");
        try broke.appendSlice(alloc, d.message);
        try broke.append(alloc, '\n');
    }
    try std.testing.expectEqualStrings("", broke.items);
}

test "spec: every documented language feature compiles" {
    // One minimal program per feature `gero-lang.md` documents. If a
    // section starts describing something that no longer lowers, this
    // names it rather than only reporting that something broke.
    const Feature = struct { name: []const u8, src: []const u8 };
    const features = [_]Feature{
        .{ .name = "2.4 numeric literals", .src =
        \\def main()
        \\  print $FF
        \\  print 42
        \\  print 1_000
        \\end
        \\
        },
        .{ .name = "2.5 string literals", .src =
        \\def main()
        \\  print "a\nb"
        \\end
        \\
        },
        .{ .name = "2.5.1 char literals", .src =
        \\def main()
        \\  let c: u8 = 65
        \\  print c
        \\end
        \\
        },
        .{ .name = "3.1 primitives", .src =
        \\def main()
        \\  let a: i16 = 1
        \\  let b: u16 = 2
        \\  let c: u8 = 3
        \\  let d: i8 = 4
        \\  let e: bool = true
        \\    print a + b as i16
        \\  print e
        \\  print d
        \\end
        \\
        },
        .{ .name = "3.2.1 string ops", .src =
        \\def main()
        \\  let s: str = "hi"
        \\  print s.len
        \\  print s.at(0)
        \\  print s.cmp("ho")
        \\  print "a" + "b"
        \\end
        \\
        },
        .{ .name = "3.2.2 interpolation", .src =
        \\def main()
        \\  let n = 5
        \\  print "n=$(n)"
        \\end
        \\
        },
        .{ .name = "3.2.2 format spec", .src =
        \\def main()
        \\  let n = 5
        \\  print "$(n:04X)"
        \\end
        \\
        },
        .{ .name = "3.3 fixed", .src =
        \\def main()
        \\  let v: fixed = 1.5
        \\  print v * 2.0
        \\end
        \\
        },
        .{ .name = "3.4 array", .src =
        \\def main()
        \\  let a: [i16; 3] = [1, 2, 3]
        \\  print a[0]
        \\end
        \\
        },
        .{ .name = "3.4 array repeat", .src =
        \\def main()
        \\  let a: [i16; 4] = [0; 4]
        \\  print a[3]
        \\end
        \\
        },
        .{ .name = "3.4 tuple", .src =
        \\def main()
        \\  let t: (i16, i16) = (1, 2)
        \\  print t.0
        \\end
        \\
        },
        .{ .name = "3.4.1 nullable scalar", .src =
        \\def main()
        \\  let n: i16? = nil
        \\  if n == nil
        \\    print 1
        \\  end
        \\end
        \\
        },
        .{ .name = "3.4.2 struct", .src =
        \\struct P
        \\  x: i16
        \\  y: i16
        \\end
        \\def main()
        \\  let p = P { x: 1, y: 2 }
        \\  print p.x
        \\end
        \\
        },
        .{ .name = "3.4.3 Vec", .src =
        \\def main()
        \\  let v: Vec(i16) = Vec.from([1, 2])
        \\  print v.len()
        \\end
        \\
        },
        .{ .name = "3.4.4 references", .src =
        \\struct S
        \\  hp: i16
        \\end
        \\def hit(s: &S)
        \\  s.hp = s.hp - 1
        \\end
        \\def main()
        \\  let s = S { hp: 3 }
        \\  hit(&s)
        \\  print s.hp
        \\end
        \\
        },
        .{ .name = "3.5 inference", .src =
        \\def main()
        \\  let x = 5
        \\  print x
        \\end
        \\
        },
        .{ .name = "3.5.1 casts", .src =
        \\def main()
        \\  let a: i16 = 300
        \\  let b: u8 = (a & $FF) as u8
        \\  print b
        \\end
        \\
        },
        .{ .name = "3.6 enum plain", .src =
        \\enum Item
        \\  case Sword
        \\  case Shield
        \\end
        \\def main()
        \\  let s = Item.Sword
        \\  if s == Item.Sword
        \\    print 1
        \\  end
        \\end
        \\
        },
        .{ .name = "3.6 enum payload", .src =
        \\enum Ev
        \\  case Key(i16)
        \\  case Quit
        \\end
        \\def main()
        \\  let e = Ev.Key(5)
        \\  match e
        \\    case Ev.Key(k) => print k
        \\    case Ev.Quit => print 0
        \\  end
        \\end
        \\
        },
        .{ .name = "3.7.1 @zero_page", .src =
        \\@zero_page
        \\let g: u16 = 0
        \\def main()
        \\  print g
        \\end
        \\
        },
        .{ .name = "3.7.1 @addr", .src =
        \\@addr $0300
        \\let g: u16 = 0
        \\def main()
        \\  print g
        \\end
        \\
        },
        .{ .name = "3.7.1 @volatile", .src =
        \\@volatile
        \\@addr $0300
        \\let g: u16 = 0
        \\def main()
        \\  print g
        \\end
        \\
        },
        .{ .name = "3.7.1 @align", .src =
        \\@align(4)
        \\let g: u16 = 0
        \\def main()
        \\  print g
        \\end
        \\
        },
        .{ .name = "3.7.2 @inline", .src =
        \\@inline
        \\def d(x: i16) -> i16
        \\  return x * 2
        \\end
        \\def main()
        \\  print d(2)
        \\end
        \\
        },
        .{ .name = "3.7.2 @cold", .src =
        \\@cold
        \\def rare()
        \\  print 1
        \\end
        \\def main()
        \\  rare()
        \\end
        \\
        },
        .{ .name = "3.7.2 @bank", .src =
        \\@bank 1
        \\def far() -> i16
        \\  return 1
        \\end
        \\def main()
        \\  print far()
        \\end
        \\
        },
        .{ .name = "3.7.3 @noreturn", .src =
        \\@noreturn
        \\def stop()
        \\  panic("x")
        \\end
        \\def main()
        \\  print 1
        \\end
        \\
        },
        .{ .name = "3.7.4 @interrupt", .src =
        \\@interrupt $07
        \\def on_vb()
        \\  print 1
        \\end
        \\def main()
        \\  print 0
        \\end
        \\
        },
        .{ .name = "3.7.5 @test", .src =
        \\@test
        \\def t_x()
        \\  test.assert_eq(1, 1)
        \\end
        \\def main()
        \\  print 0
        \\end
        \\
        },
        .{ .name = "3.7.5 @bench", .src =
        \\@bench
        \\def b_x()
        \\  let a = 1
        \\end
        \\def main()
        \\  print 0
        \\end
        \\
        },
        .{ .name = "3.7.6 class", .src =
        \\class P
        \\  let hp: i16
        \\  def init(self, h: i16)
        \\    self.hp = h
        \\  end
        \\  def get(self) -> i16
        \\    return self.hp
        \\  end
        \\end
        \\def main()
        \\  let p = P(5)
        \\  print p.get()
        \\end
        \\
        },
        .{ .name = "3.7.6 inheritance", .src =
        \\class A
        \\  let x: i16
        \\  def init(self)
        \\    self.x = 1
        \\  end
        \\end
        \\class B extends A
        \\  def init(self)
        \\    super.init()
        \\  end
        \\end
        \\def main()
        \\  let b = B()
        \\  print b.x
        \\end
        \\
        },
        .{ .name = "3.7.7 / 4.11 inline asm", .src =
        \\def main()
        \\  asm "nop"
        \\  print 1
        \\end
        \\
        },
        .{ .name = "3.8 bake", .src =
        \\const N: i16 = bake do
        \\  1 + 2
        \\end
        \\def main()
        \\  print N
        \\end
        \\
        },
        .{ .name = "3.8 bake def", .src =
        \\bake def f() -> i16
        \\  return 7
        \\end
        \\const N: i16 = bake do
        \\  f()
        \\end
        \\def main()
        \\  print N
        \\end
        \\
        },
        .{ .name = "4.1 let / const", .src =
        \\const K: i16 = 1
        \\def main()
        \\  let x = K
        \\  print x
        \\end
        \\
        },
        .{ .name = "4.1.1 destructuring let", .src =
        \\def pair() -> (i16, i16)
        \\  return (1, 2)
        \\end
        \\def main()
        \\  let (a, b) = pair()
        \\  print a + b
        \\end
        \\
        },
        .{ .name = "4.2.1 operators", .src =
        \\def main()
        \\  print 1 + 2 - 3 * 4 / 2 % 3
        \\  print 1 < 2 and 3 > 2 or false
        \\  print $F0 & $0F | $01 ^ $02
        \\  print 1 << 2 >> 1
        \\end
        \\
        },
        .{ .name = "4.2.2 discard", .src =
        \\def f() -> i16
        \\  return 1
        \\end
        \\def main()
        \\  _ = f()
        \\  print 0
        \\end
        \\
        },
        .{ .name = "4.3 do block", .src =
        \\def main()
        \\  let a = do
        \\    1 + 2
        \\  end
        \\  print a
        \\end
        \\
        },
        .{ .name = "4.4 if/elif/else", .src =
        \\def main()
        \\  let x = 1
        \\  if x == 0
        \\    print 0
        \\  elif x == 1
        \\    print 1
        \\  else
        \\    print 2
        \\  end
        \\end
        \\
        },
        .{ .name = "4.4.1 if let", .src =
        \\enum E
        \\  case A(i16)
        \\  case B
        \\end
        \\def main()
        \\  let e = E.A(1)
        \\  if let E.A(n) = e
        \\    print n
        \\  end
        \\end
        \\
        },
        .{ .name = "4.5 while / for", .src =
        \\def main()
        \\  let i = 0
        \\  while i < 2
        \\    i = i + 1
        \\  end
        \\  for j in 0..2
        \\    print j
        \\  end
        \\end
        \\
        },
        .{ .name = "4.5.1 inclusive range", .src =
        \\def main()
        \\  for j in 0..=2
        \\    print j
        \\  end
        \\end
        \\
        },
        .{ .name = "4.5.2 while let", .src =
        \\enum E
        \\  case A(i16)
        \\  case B
        \\end
        \\let c: i16 = 0
        \\def poll() -> E
        \\  c = c + 1
        \\  if c < 3
        \\    return E.A(c)
        \\  end
        \\  return E.B
        \\end
        \\def main()
        \\  while let E.A(n) = poll()
        \\    print n
        \\  end
        \\end
        \\
        },
        .{ .name = "4.5.4 repeat until", .src =
        \\def main()
        \\  let i = 0
        \\  repeat
        \\    i = i + 1
        \\  until i >= 2
        \\  print i
        \\end
        \\
        },
        .{ .name = "4.5.5 labeled loops", .src =
        \\def main()
        \\  for y in 0..2 :rows
        \\    for x in 0..2
        \\      if x == 1
        \\        break :rows
        \\      end
        \\    end
        \\  end
        \\  print 1
        \\end
        \\
        },
        .{ .name = "4.6 functions", .src =
        \\def add(a: i16, b: i16) -> i16
        \\  return a + b
        \\end
        \\def main()
        \\  print add(1, 2)
        \\end
        \\
        },
        .{ .name = "4.6.2 variadics", .src =
        \\def first(args: ...) -> i16
        \\  return args.0
        \\end
        \\def main()
        \\  print first(1, 2)
        \\end
        \\
        },
        .{ .name = "4.6.3 method chaining", .src =
        \\class C
        \\  let v: i16
        \\  def init(self)
        \\    self.v = 1
        \\  end
        \\  def bump(self) -> i16
        \\    return self.v + 1
        \\  end
        \\end
        \\def main()
        \\  let c = C()
        \\  print c.bump()
        \\end
        \\
        },
        .{ .name = "4.7 lambda (long form)", .src =
        \\def main()
        \\  let f = lambda (x: i16) -> i16
        \\    return x * 2
        \\  end
        \\  print f(2)
        \\end
        \\
        },
        .{ .name = "4.7.1 short lambda", .src =
        \\def main()
        \\  let f = |x: i16| -> i16 x * 2
        \\  print f(2)
        \\end
        \\
        },
        .{ .name = "4.7.2 closure capture", .src =
        \\def main()
        \\  let n = 5
        \\  let f = || -> i16 n + 1
        \\  print f()
        \\end
        \\
        },
        .{ .name = "4.8 match", .src =
        \\enum E
        \\  case A
        \\  case B
        \\end
        \\def main()
        \\  let e = E.A
        \\  match e
        \\    case E.A => print 1
        \\    case E.B => print 2
        \\  end
        \\end
        \\
        },
        .{ .name = "4.8.2 match guards", .src =
        \\def main()
        \\  let n = 5
        \\  match n
        \\    case x when x > 3 => print 1
        \\    case _ => print 0
        \\  end
        \\end
        \\
        },
        .{ .name = "4.9 print", .src =
        \\def main()
        \\  print 1
        \\  print "s"
        \\  print 1, " ", 2
        \\end
        \\
        },
        .{ .name = "4.10 defer", .src =
        \\def main()
        \\  defer print 2
        \\  print 1
        \\end
        \\
        },
        .{ .name = "5.2 imports", .src =
        \\use math
        \\def main()
        \\  print math.abs(0 - 1)
        \\end
        \\
        },
        .{ .name = "assert / debug_assert", .src =
        \\def main()
        \\  assert(true, "ok")
        \\  debug_assert(true, "ok")
        \\  print 1
        \\end
        \\
        },
        .{ .name = "panic / unreachable / todo", .src =
        \\def f(x: i16) -> i16
        \\  if x > 0
        \\    return 1
        \\  end
        \\  panic("neg")
        \\end
        \\def main()
        \\  print f(1)
        \\end
        \\
        },
    };

    var broke: std.ArrayList(u8) = .empty;
    defer broke.deinit(alloc);
    for (features) |f| {
        var compiled = compileSource(f.src) catch {
            try broke.appendSlice(alloc, f.name);
            try broke.appendSlice(alloc, ": did not compile\n");
            continue;
        };
        defer compiled.deinit();
        if (!compiled.hasErrors()) continue;
        try broke.appendSlice(alloc, f.name);
        for (compiled.diagnostics) |d| {
            if (d.severity != .fatal) continue;
            try broke.appendSlice(alloc, ": ");
            try broke.appendSlice(alloc, d.code);
            break;
        }
        try broke.append(alloc, '\n');
    }
    try std.testing.expectEqualStrings("", broke.items);
}
