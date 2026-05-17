/// Tests for `gero.lang.codegen` — slice-B1 framework smoke.
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
