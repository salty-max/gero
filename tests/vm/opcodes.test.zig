const std = @import("std");
const gero = @import("gero");
const Operand = gero.vm.Operand;
const OpcodeInfo = gero.vm.OpcodeInfo;
const table = gero.vm.opcode_table;

test "opcodes: operandSize matches encoding widths" {
    try std.testing.expectEqual(@as(u8, 1), gero.vm.operandSize(.reg));
    try std.testing.expectEqual(@as(u8, 1), gero.vm.operandSize(.imm8));
    try std.testing.expectEqual(@as(u8, 1), gero.vm.operandSize(.zp));
    try std.testing.expectEqual(@as(u8, 2), gero.vm.operandSize(.imm16));
    try std.testing.expectEqual(@as(u8, 2), gero.vm.operandSize(.addr));
}

test "opcodes: OpcodeInfo.size sums opcode + operands" {
    const nop = OpcodeInfo{ .mnemonic = "nop", .operands = &.{} };
    try std.testing.expectEqual(@as(u8, 1), nop.size());

    const jr = OpcodeInfo{ .mnemonic = "jr", .operands = &.{.imm8} };
    try std.testing.expectEqual(@as(u8, 2), jr.size());

    const jmp = OpcodeInfo{ .mnemonic = "jmp", .operands = &.{.addr} };
    try std.testing.expectEqual(@as(u8, 3), jmp.size());

    const movx = OpcodeInfo{ .mnemonic = "mov", .operands = &.{ .imm16, .reg } };
    try std.testing.expectEqual(@as(u8, 4), movx.size());

    const movix = OpcodeInfo{ .mnemonic = "mov", .operands = &.{ .addr, .reg, .reg } };
    try std.testing.expectEqual(@as(u8, 5), movix.size());
}

test "opcodes: table holds exactly 103 named entries" {
    var count: usize = 0;
    for (table) |entry| if (entry != null) {
        count += 1;
    };
    // 97 = 93 base + 4 byte-mov ZP variants (0x2A-0x2D), then 3
    // single-bit ops at 0x68/0x69/0x6A (bset / bclr / btest),
    // sext at 0x2E (sign-extension), then 2 asr variants at
    // 0x6B/0x6C (arithmetic shift right).
    try std.testing.expectEqual(@as(usize, 103), count);
}

test "opcodes: every named entry has a non-empty mnemonic" {
    for (table, 0..) |entry, op| {
        if (entry) |info| {
            std.testing.expect(info.mnemonic.len > 0) catch |e| {
                std.debug.print("opcode 0x{X:0>2} has empty mnemonic\n", .{op});
                return e;
            };
        }
    }
}

test "opcodes: table sample — mov family" {
    try std.testing.expectEqualStrings("mov", table[0x10].?.mnemonic);
    try std.testing.expectEqualSlices(Operand, &.{ .imm16, .reg }, table[0x10].?.operands);
    try std.testing.expectEqualStrings("mov", table[0x17].?.mnemonic);
    try std.testing.expectEqualSlices(Operand, &.{ .addr, .reg, .reg }, table[0x17].?.operands);
    try std.testing.expectEqualStrings("mov", table[0x1B].?.mnemonic);
    try std.testing.expectEqualSlices(Operand, &.{ .imm16, .zp }, table[0x1B].?.operands);
}

test "opcodes: table sample — control flow" {
    try std.testing.expectEqualStrings("jmp", table[0x70].?.mnemonic);
    try std.testing.expectEqualSlices(Operand, &.{.addr}, table[0x70].?.operands);
    try std.testing.expectEqualStrings("djnz", table[0x7E].?.mnemonic);
    try std.testing.expectEqualSlices(Operand, &.{ .reg, .addr }, table[0x7E].?.operands);
    try std.testing.expectEqualStrings("jr", table[0x7F].?.mnemonic);
    try std.testing.expectEqualSlices(Operand, &.{.imm8}, table[0x7F].?.operands);
}

test "opcodes: table sample — system" {
    try std.testing.expectEqualStrings("hlt", table[0xFF].?.mnemonic);
    try std.testing.expectEqual(@as(usize, 0), table[0xFF].?.operands.len);
    try std.testing.expectEqualStrings("brk", table[0xFE].?.mnemonic);
    try std.testing.expectEqualStrings("rti", table[0xFD].?.mnemonic);
    try std.testing.expectEqualStrings("int", table[0xFC].?.mnemonic);
    try std.testing.expectEqualSlices(Operand, &.{.imm8}, table[0xFC].?.operands);
}

test "opcodes: instruction sizes span the full 1-5 byte range" {
    // 1 byte — no operands.
    try std.testing.expectEqual(@as(u8, 1), table[0xFF].?.size()); // hlt
    try std.testing.expectEqual(@as(u8, 1), table[0x91].?.size()); // nop
    try std.testing.expectEqual(@as(u8, 1), table[0xA0].?.size()); // clc

    // 2 bytes — 1 single-byte operand.
    try std.testing.expectEqual(@as(u8, 2), table[0x31].?.size()); // push reg
    try std.testing.expectEqual(@as(u8, 2), table[0x7F].?.size()); // jr imm8
    try std.testing.expectEqual(@as(u8, 2), table[0xFC].?.size()); // int imm8

    // 3 bytes — combinations summing to 2 operand bytes.
    try std.testing.expectEqual(@as(u8, 3), table[0x70].?.size()); // jmp addr
    try std.testing.expectEqual(@as(u8, 3), table[0x11].?.size()); // mov reg,reg
    try std.testing.expectEqual(@as(u8, 3), table[0x30].?.size()); // push imm16

    // 4 bytes — most binary ops.
    try std.testing.expectEqual(@as(u8, 4), table[0x10].?.size()); // mov imm16,reg
    try std.testing.expectEqual(@as(u8, 4), table[0x40].?.size()); // add imm16,reg
    try std.testing.expectEqual(@as(u8, 4), table[0x7E].?.size()); // djnz reg,addr

    // 5 bytes — indexed mov (word) + indexed mov8 (byte).
    try std.testing.expectEqual(@as(u8, 5), table[0x17].?.size()); // mov addr,reg,reg
    try std.testing.expectEqual(@as(u8, 5), table[0x29].?.size()); // mov8 addr,reg,reg
}

test "opcodes: unused byte values are null" {
    // Spot-check several gaps in the spec's opcode space.
    try std.testing.expect(table[0x00] == null);
    try std.testing.expect(table[0x0F] == null);
    try std.testing.expect(table[0x33] == null);
    try std.testing.expect(table[0x57] == null);
    try std.testing.expect(table[0x6F] == null);
    try std.testing.expect(table[0xB0] == null);
    try std.testing.expect(table[0xFB] == null);
}

test "opcodes: schema sizes never overflow a u8 instruction" {
    // No instruction in the ISA is wider than 5 bytes.
    for (table) |entry| {
        if (entry) |info| try std.testing.expect(info.size() <= 5);
    }
}
