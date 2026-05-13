const std = @import("std");
const gero = @import("gero");

const alloc = std.testing.allocator;

// The opcode resolver isn't directly re-exported through
// `gero.asm_` since it's an implementation detail of codegen.
// We exercise it indirectly via codegen — but the smoke tests
// here verify a few intrinsic invariants of the table that
// would otherwise require cross-file coverage to reveal.

test "opres: mov reg,reg resolves to opcode 0x11" {
    // Indirect proxy via codegen: assemble `mov r1, r2` and check
    // the first byte of the body is 0x11.
    var pt = try gero.asm_.parse(alloc, "mov r1, r2\n");
    defer pt.deinit();
    var cg = try gero.asm_.assemble(alloc, "mov r1, r2\n", pt, .{});
    defer cg.deinit();
    try std.testing.expect(!cg.hasErrors());
    try std.testing.expectEqual(@as(u8, 0x11), cg.image[16]); // skip header
}

test "opres: hlt resolves to 0xFF (zero-operand sentinel)" {
    var pt = try gero.asm_.parse(alloc, "hlt\n");
    defer pt.deinit();
    var cg = try gero.asm_.assemble(alloc, "hlt\n", pt, .{});
    defer cg.deinit();
    try std.testing.expectEqual(@as(u8, 0xFF), cg.image[16]);
}

test "opres: cmp reg, label_ref(const) uses imm16 form (0x60)" {
    // `TARGET` is a const → label_ref resolves to imm16, picking
    // 0x60 (cmp Reg, Imm16) over a hypothetical addr form.
    const src =
        \\const TARGET = $10
        \\cmp r1, TARGET
        \\
    ;
    var pt = try gero.asm_.parse(alloc, src);
    defer pt.deinit();
    var cg = try gero.asm_.assemble(alloc, src, pt, .{ .debug_symbols = false });
    defer cg.deinit();
    try std.testing.expect(!cg.hasErrors());
    try std.testing.expectEqual(@as(u8, 0x60), cg.image[16]);
}

test "opres: jmp label_ref(label) uses addr form (0x70)" {
    const src =
        \\target:
        \\  hlt
        \\jmp target
        \\
    ;
    var pt = try gero.asm_.parse(alloc, src);
    defer pt.deinit();
    var cg = try gero.asm_.assemble(alloc, src, pt, .{ .debug_symbols = false });
    defer cg.deinit();
    try std.testing.expect(!cg.hasErrors());
    // image: hlt(0xFF) then jmp(0x70) + addr LE(00 00)
    try std.testing.expectEqual(@as(u8, 0xFF), cg.image[16]);
    try std.testing.expectEqual(@as(u8, 0x70), cg.image[17]);
}

test "opres: indexed addressing emits 3-byte operand (addr + reg)" {
    const src = "mov [&2620 + r1], r2\n";
    var pt = try gero.asm_.parse(alloc, src);
    defer pt.deinit();
    var cg = try gero.asm_.assemble(alloc, src, pt, .{ .debug_symbols = false });
    defer cg.deinit();
    try std.testing.expect(!cg.hasErrors());
    // 0x17 + addr LE (20 26) + idx_reg (r1 = 0x02) + dst_reg (r2 = 0x03)
    try std.testing.expectEqualSlices(u8, &.{ 0x17, 0x20, 0x26, 0x02, 0x03 }, cg.image[16..]);
}

test "opres: mov8 indexed emits 5-byte operand (opcode + addr + 2 regs)" {
    const src = "mov8 [&3000 + r1], r2\n";
    var pt = try gero.asm_.parse(alloc, src);
    defer pt.deinit();
    var cg = try gero.asm_.assemble(alloc, src, pt, .{ .debug_symbols = false });
    defer cg.deinit();
    try std.testing.expect(!cg.hasErrors());
    // 0x29 + addr LE (00 30) + idx_reg (r1 = 0x02) + dst_reg (r2 = 0x03)
    try std.testing.expectEqualSlices(u8, &.{ 0x29, 0x00, 0x30, 0x02, 0x03 }, cg.image[16..]);
}

test "opres: imm8 narrowing — mov8 picks Imm8 shape over widening" {
    // `mov8 $42, r1` — value fits u8, mov8 has an Imm8,Reg shape
    // exactly. Total 3 bytes: opcode + imm8 + reg.
    const src = "mov8 $42, r1\n";
    var pt = try gero.asm_.parse(alloc, src);
    defer pt.deinit();
    var cg = try gero.asm_.assemble(alloc, src, pt, .{ .debug_symbols = false });
    defer cg.deinit();
    try std.testing.expect(!cg.hasErrors());
    try std.testing.expectEqualSlices(u8, &.{ 0x21, 0x42, 0x02 }, cg.image[16..]);
}
