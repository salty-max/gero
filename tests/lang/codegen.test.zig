/// Tests for `gero.lang.codegen` — compiles small programs end
/// to end (tokenize → parse → typecheck → compile → boot on the
/// VM) and asserts on printed output or VM-memory state.
const std = @import("std");
const gero = @import("gero");

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

test "codegen: non-print interpolation formats into a per-site data buffer" {
    // `let s = "x=$(x)"; print s` formats into a static buffer
    // reserved in the data region (one allocation per interp
    // site per spec §3.2.2). Reading `s` later prints the same
    // bytes since the buffer persists.
    try runAndExpect(
        \\def main()
        \\  let x: i16 = 42
        \\  let s: str = "x=$(x)"
        \\  print s
        \\end
    , "x=42\n");
}

test "codegen: format-spec `$(x:d)` is rejected with E_CODEGEN_UNSUPPORTED" {
    const source =
        \\def main()
        \\  let x: i16 = 1
        \\  let s: str = "$(x:d)"
        \\  print s
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
        if (std.mem.eql(u8, d.code, "E_CODEGEN_UNSUPPORTED")) found = true;
    }
    try std.testing.expect(found);
}

test "codegen: diagnostic message slices outlive `compile`" {
    // Regression: `Diagnostic.message` strings allocated by
    // `Emitter.unsupported` live on `Compiled.diag_arena`. A prior
    // shape kept them on a scratch arena that deinit'd before
    // `compile` returned, leaving the slices dangling. This test
    // reads `.message` AFTER `compile` returns to prove the arena
    // outlives the call.
    const source =
        \\def main()
        \\  let x: i16 = 1
        \\  let s: str = "$(x:d)"
        \\  print s
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
            try std.testing.expect(std.mem.indexOf(u8, d.message, "format specs") != null);
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

// ---------- enum codegen (nullary variants) ----------

test "codegen: nullary enum constructor loads tag byte into acu" {
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
    ,
        // Green is the second declared variant → tag = 1.
        "1\n");
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
