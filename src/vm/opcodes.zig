/// Opcode table — the canonical mapping from byte → mnemonic +
/// operand schema. Dispatch consults this for instruction sizing;
/// the disassembler can re-use it for textual rendering.
const std = @import("std");

/// Operand kinds. Encoding sizes:
/// `reg`/`imm8`/`zp` = 1 byte, `imm16`/`addr` = 2 bytes.
pub const Operand = enum {
    reg,
    imm8,
    imm16,
    addr,
    zp,
};

/// Encoded byte size of one operand.
pub fn operandSize(op: Operand) u8 {
    return switch (op) {
        .reg, .imm8, .zp => 1,
        .imm16, .addr => 2,
    };
}

/// One opcode's metadata: mnemonic plus the byte-layout schema
/// of its operands (in source order). The handler comes later;
/// dispatch tracks it in its own structure.
pub const OpcodeInfo = struct {
    mnemonic: []const u8,
    operands: []const Operand,

    /// Total instruction byte size: opcode + sum of operand sizes.
    pub fn size(self: OpcodeInfo) u8 {
        var s: u8 = 1;
        for (self.operands) |op| s += operandSize(op);
        return s;
    }
};

/// 256-entry table indexed by opcode byte. `null` = no opcode
/// defined at that byte (raises invalid-opcode fault on dispatch).
pub const table: [256]?OpcodeInfo = blk: {
    var t = [_]?OpcodeInfo{null} ** 256;

    // mov family
    t[0x10] = .{ .mnemonic = "mov", .operands = &.{ .imm16, .reg } };
    t[0x11] = .{ .mnemonic = "mov", .operands = &.{ .reg, .reg } };
    t[0x12] = .{ .mnemonic = "mov", .operands = &.{ .reg, .addr } };
    t[0x13] = .{ .mnemonic = "mov", .operands = &.{ .addr, .reg } };
    t[0x14] = .{ .mnemonic = "mov", .operands = &.{ .imm16, .addr } };
    t[0x15] = .{ .mnemonic = "mov", .operands = &.{ .reg, .reg } };
    t[0x16] = .{ .mnemonic = "mov", .operands = &.{ .reg, .reg } };
    t[0x17] = .{ .mnemonic = "mov", .operands = &.{ .addr, .reg, .reg } };
    t[0x18] = .{ .mnemonic = "mov", .operands = &.{ .imm16, .reg } };
    t[0x19] = .{ .mnemonic = "mov", .operands = &.{ .reg, .zp } };
    t[0x1A] = .{ .mnemonic = "mov", .operands = &.{ .zp, .reg } };
    t[0x1B] = .{ .mnemonic = "mov", .operands = &.{ .imm16, .zp } };

    // mov8 / movh / movl
    t[0x20] = .{ .mnemonic = "mov8", .operands = &.{ .imm8, .addr } };
    t[0x21] = .{ .mnemonic = "mov8", .operands = &.{ .imm8, .reg } };
    t[0x22] = .{ .mnemonic = "mov8", .operands = &.{ .addr, .reg } };
    t[0x23] = .{ .mnemonic = "mov8", .operands = &.{ .reg, .reg } };
    t[0x24] = .{ .mnemonic = "mov8", .operands = &.{ .reg, .reg } };
    t[0x29] = .{ .mnemonic = "mov8", .operands = &.{ .addr, .reg, .reg } };
    t[0x25] = .{ .mnemonic = "movh", .operands = &.{ .reg, .addr } };
    t[0x26] = .{ .mnemonic = "movl", .operands = &.{ .reg, .addr } };

    // mov8 / movh / movl — zero-page variants
    t[0x2A] = .{ .mnemonic = "mov8", .operands = &.{ .imm8, .zp } };
    t[0x2B] = .{ .mnemonic = "mov8", .operands = &.{ .zp, .reg } };
    t[0x2C] = .{ .mnemonic = "movh", .operands = &.{ .reg, .zp } };
    t[0x2D] = .{ .mnemonic = "movl", .operands = &.{ .reg, .zp } };

    // block memory ops
    t[0x27] = .{ .mnemonic = "bcpy", .operands = &.{ .reg, .reg, .reg } };
    t[0x28] = .{ .mnemonic = "bfill", .operands = &.{ .reg, .reg, .reg } };
    t[0x2E] = .{ .mnemonic = "sext", .operands = &.{.reg} };

    // stack
    t[0x30] = .{ .mnemonic = "push", .operands = &.{.imm16} };
    t[0x31] = .{ .mnemonic = "push", .operands = &.{.reg} };
    t[0x32] = .{ .mnemonic = "pop", .operands = &.{.reg} };

    // arithmetic
    t[0x40] = .{ .mnemonic = "add", .operands = &.{ .imm16, .reg } };
    t[0x41] = .{ .mnemonic = "add", .operands = &.{ .reg, .reg } };
    t[0x42] = .{ .mnemonic = "add", .operands = &.{.reg} };
    t[0x43] = .{ .mnemonic = "sub", .operands = &.{ .imm16, .reg } };
    t[0x44] = .{ .mnemonic = "sub", .operands = &.{ .reg, .reg } };
    t[0x45] = .{ .mnemonic = "sub", .operands = &.{.reg} };
    t[0x46] = .{ .mnemonic = "mul", .operands = &.{ .imm16, .reg } };
    t[0x47] = .{ .mnemonic = "mul", .operands = &.{ .reg, .reg } };
    t[0x48] = .{ .mnemonic = "inc", .operands = &.{.reg} };
    t[0x49] = .{ .mnemonic = "dec", .operands = &.{.reg} };
    t[0x4A] = .{ .mnemonic = "neg", .operands = &.{.reg} };
    t[0x4B] = .{ .mnemonic = "div", .operands = &.{ .imm16, .reg } };
    t[0x4C] = .{ .mnemonic = "div", .operands = &.{ .reg, .reg } };
    t[0x4D] = .{ .mnemonic = "divs", .operands = &.{ .imm16, .reg } };
    t[0x4E] = .{ .mnemonic = "divs", .operands = &.{ .reg, .reg } };
    t[0x64] = .{ .mnemonic = "adc", .operands = &.{ .imm16, .reg } };
    t[0x65] = .{ .mnemonic = "adc", .operands = &.{ .reg, .reg } };
    t[0x66] = .{ .mnemonic = "sbc", .operands = &.{ .imm16, .reg } };
    t[0x67] = .{ .mnemonic = "sbc", .operands = &.{ .reg, .reg } };

    // logical
    t[0x50] = .{ .mnemonic = "and", .operands = &.{ .imm16, .reg } };
    t[0x51] = .{ .mnemonic = "and", .operands = &.{ .reg, .reg } };
    t[0x52] = .{ .mnemonic = "or", .operands = &.{ .imm16, .reg } };
    t[0x53] = .{ .mnemonic = "or", .operands = &.{ .reg, .reg } };
    t[0x54] = .{ .mnemonic = "xor", .operands = &.{ .imm16, .reg } };
    t[0x55] = .{ .mnemonic = "xor", .operands = &.{ .reg, .reg } };
    t[0x56] = .{ .mnemonic = "not", .operands = &.{.reg} };

    // shifts and rotates
    t[0x58] = .{ .mnemonic = "shl", .operands = &.{ .reg, .imm8 } };
    t[0x59] = .{ .mnemonic = "shl", .operands = &.{ .reg, .reg } };
    t[0x5A] = .{ .mnemonic = "shr", .operands = &.{ .reg, .imm8 } };
    t[0x5B] = .{ .mnemonic = "shr", .operands = &.{ .reg, .reg } };
    t[0x5C] = .{ .mnemonic = "rol", .operands = &.{ .reg, .imm8 } };
    t[0x5D] = .{ .mnemonic = "rol", .operands = &.{ .reg, .reg } };
    t[0x5E] = .{ .mnemonic = "ror", .operands = &.{ .reg, .imm8 } };
    t[0x5F] = .{ .mnemonic = "ror", .operands = &.{ .reg, .reg } };

    // cmp / tst
    t[0x60] = .{ .mnemonic = "cmp", .operands = &.{ .reg, .imm16 } };
    t[0x61] = .{ .mnemonic = "cmp", .operands = &.{ .reg, .reg } };
    t[0x62] = .{ .mnemonic = "tst", .operands = &.{ .reg, .imm16 } };
    t[0x63] = .{ .mnemonic = "tst", .operands = &.{ .reg, .reg } };
    t[0x68] = .{ .mnemonic = "bset", .operands = &.{ .reg, .imm8 } };
    t[0x69] = .{ .mnemonic = "bclr", .operands = &.{ .reg, .imm8 } };
    t[0x6A] = .{ .mnemonic = "btest", .operands = &.{ .reg, .imm8 } };

    // control flow
    t[0x70] = .{ .mnemonic = "jmp", .operands = &.{.addr} };
    t[0x71] = .{ .mnemonic = "jmp", .operands = &.{.reg} };
    t[0x72] = .{ .mnemonic = "jeq", .operands = &.{.addr} };
    t[0x73] = .{ .mnemonic = "jne", .operands = &.{.addr} };
    t[0x74] = .{ .mnemonic = "jlt", .operands = &.{.addr} };
    t[0x75] = .{ .mnemonic = "jle", .operands = &.{.addr} };
    t[0x76] = .{ .mnemonic = "jgt", .operands = &.{.addr} };
    t[0x77] = .{ .mnemonic = "jge", .operands = &.{.addr} };
    t[0x78] = .{ .mnemonic = "jcc", .operands = &.{.addr} };
    t[0x79] = .{ .mnemonic = "jcs", .operands = &.{.addr} };
    t[0x7A] = .{ .mnemonic = "jvc", .operands = &.{.addr} };
    t[0x7B] = .{ .mnemonic = "jvs", .operands = &.{.addr} };
    t[0x7C] = .{ .mnemonic = "jz", .operands = &.{.addr} };
    t[0x7D] = .{ .mnemonic = "jnz", .operands = &.{.addr} };
    t[0x7E] = .{ .mnemonic = "djnz", .operands = &.{ .reg, .addr } };
    t[0x7F] = .{ .mnemonic = "jr", .operands = &.{.imm8} };

    // subroutines
    t[0x80] = .{ .mnemonic = "call", .operands = &.{.addr} };
    t[0x81] = .{ .mnemonic = "call", .operands = &.{.reg} };
    t[0x82] = .{ .mnemonic = "ret", .operands = &.{} };

    // misc
    t[0x90] = .{ .mnemonic = "swap", .operands = &.{ .reg, .reg } };
    t[0x91] = .{ .mnemonic = "nop", .operands = &.{} };

    // flag manipulation
    t[0xA0] = .{ .mnemonic = "clc", .operands = &.{} };
    t[0xA1] = .{ .mnemonic = "sec", .operands = &.{} };
    t[0xA2] = .{ .mnemonic = "cli", .operands = &.{} };
    t[0xA3] = .{ .mnemonic = "sei", .operands = &.{} };
    t[0xA4] = .{ .mnemonic = "clv", .operands = &.{} };

    // system
    t[0xFC] = .{ .mnemonic = "int", .operands = &.{.imm8} };
    t[0xFD] = .{ .mnemonic = "rti", .operands = &.{} };
    t[0xFE] = .{ .mnemonic = "brk", .operands = &.{} };
    t[0xFF] = .{ .mnemonic = "hlt", .operands = &.{} };

    break :blk t;
};
