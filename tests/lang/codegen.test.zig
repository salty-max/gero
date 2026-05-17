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
