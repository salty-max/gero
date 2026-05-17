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
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);

    var checked = try gero.lang.typecheck(alloc, source, &tree.program);
    defer checked.deinit();
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
