const std = @import("std");
const gero = @import("gero");

const alloc = std.testing.allocator;

test "decoder: hlt (zero-operand) decodes to mnemonic + empty operands" {
    const bytes = [_]u8{0xFF};
    const out = try gero.disasm.decodeOne(alloc, &bytes, 0);
    defer gero.disasm.freeInstruction(alloc, out.instruction);
    try std.testing.expectEqualStrings("hlt", out.instruction.mnemonic);
    try std.testing.expectEqual(@as(u8, 1), out.instruction.size);
    try std.testing.expectEqual(@as(usize, 0), out.instruction.operands.len);
    try std.testing.expectEqual(@as(usize, 1), out.next_offset);
}

test "decoder: mov imm16, reg → 0x10 LE imm + reg" {
    // mov $1234, r1
    const bytes = [_]u8{ 0x10, 0x34, 0x12, 0x02 };
    const out = try gero.disasm.decodeOne(alloc, &bytes, 0);
    defer gero.disasm.freeInstruction(alloc, out.instruction);
    try std.testing.expectEqualStrings("mov", out.instruction.mnemonic);
    try std.testing.expectEqual(@as(u8, 4), out.instruction.size);
    try std.testing.expectEqual(@as(usize, 2), out.instruction.operands.len);
    try std.testing.expectEqual(@as(u16, 0x1234), out.instruction.operands[0].imm16);
    try std.testing.expectEqual(@as(u8, 0x02), out.instruction.operands[1].reg);
}

test "decoder: mov reg, reg → 0x11 src dst (post-#94 src-first convention)" {
    const bytes = [_]u8{ 0x11, 0x02, 0x03 };
    const out = try gero.disasm.decodeOne(alloc, &bytes, 0);
    defer gero.disasm.freeInstruction(alloc, out.instruction);
    try std.testing.expectEqualStrings("mov", out.instruction.mnemonic);
    try std.testing.expectEqual(@as(u8, 0x02), out.instruction.operands[0].reg);
    try std.testing.expectEqual(@as(u8, 0x03), out.instruction.operands[1].reg);
}

test "decoder: indexed mov decodes 5 bytes (opcode + addr + reg + reg)" {
    // mov [&2620 + r1], r2  →  0x17 20 26 02 03
    const bytes = [_]u8{ 0x17, 0x20, 0x26, 0x02, 0x03 };
    const out = try gero.disasm.decodeOne(alloc, &bytes, 0);
    defer gero.disasm.freeInstruction(alloc, out.instruction);
    try std.testing.expectEqual(@as(u8, 5), out.instruction.size);
    try std.testing.expectEqual(@as(u16, 0x2620), out.instruction.operands[0].indexed.addr);
    try std.testing.expectEqual(@as(u8, 0x02), out.instruction.operands[0].indexed.reg);
    try std.testing.expectEqual(@as(u8, 0x03), out.instruction.operands[1].reg);
}

test "decoder: int (imm8) decodes 2 bytes" {
    const bytes = [_]u8{ 0xFC, 0x10 };
    const out = try gero.disasm.decodeOne(alloc, &bytes, 0);
    defer gero.disasm.freeInstruction(alloc, out.instruction);
    try std.testing.expectEqualStrings("int", out.instruction.mnemonic);
    try std.testing.expectEqual(@as(u8, 0x10), out.instruction.operands[0].imm8);
}

test "decoder: unknown opcode returns error.UnknownOpcode" {
    const bytes = [_]u8{0x00}; // 0x00 is not in the v0.1 ISA
    try std.testing.expectError(error.UnknownOpcode, gero.disasm.decodeOne(alloc, &bytes, 0));
}

test "decoder: truncated operand returns error.Truncated" {
    // `mov` (0x10) expects 3 more bytes — only give it 2.
    const bytes = [_]u8{ 0x10, 0x34, 0x12 };
    try std.testing.expectError(error.Truncated, gero.disasm.decodeOne(alloc, &bytes, 0));
}
