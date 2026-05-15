/// Opcode table — the canonical mapping from byte → mnemonic +
/// operand schema. Dispatch consults this for instruction sizing;
/// the disassembler can re-use it for textual rendering.
///
/// Bytes are organized by 16-slot pages, one page per role:
///   0x1X  mov word        | 0x8X  cmp/tst
///   0x2X  mov byte        | 0x9X  branches
///   0x3X  stack           | 0xAX  subroutines
///   0x4X  arith primary   | 0xBX  flag manipulation
///   0x5X  arith carry     | 0xCX  misc
///   0x6X  bitwise         | 0xD-EX reserved
///   0x7X  shifts/rotates  | 0xFX  system
const std = @import("std");

/// Operand kinds. Encoding sizes:
///   `reg`/`imm8`/`zp`/`reg_indirect`   = 1 byte
///   `imm16`/`addr`/`reg_offset`        = 2 bytes
///   `indexed`                          = 3 bytes
pub const Operand = enum {
    /// 1-byte register index.
    reg,
    /// 1-byte immediate.
    imm8,
    /// 2-byte little-endian immediate.
    imm16,
    /// 2-byte little-endian address.
    addr,
    /// 1-byte zero-page address.
    zp,
    /// `[reg]` indirect — encodes as 1 register-index byte
    /// treated as effective address.
    reg_indirect,
    /// `[reg + imm8]` register-relative — encodes as base-reg
    /// byte + signed imm8 byte.
    reg_offset,
    /// `[addr + reg]` indexed — encodes as 2 addr bytes + 1
    /// reg byte.
    indexed,
};

/// Encoded byte size of one operand.
pub fn operandSize(op: Operand) u8 {
    return switch (op) {
        .reg, .imm8, .zp, .reg_indirect => 1,
        .imm16, .addr, .reg_offset => 2,
        .indexed => 3,
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

    // 0x1X — mov word
    t[0x10] = .{ .mnemonic = "mov", .operands = &.{ .imm16, .reg } };
    t[0x11] = .{ .mnemonic = "mov", .operands = &.{ .reg, .reg } };
    t[0x12] = .{ .mnemonic = "mov", .operands = &.{ .reg, .addr } };
    t[0x13] = .{ .mnemonic = "mov", .operands = &.{ .addr, .reg } };
    t[0x14] = .{ .mnemonic = "mov", .operands = &.{ .imm16, .addr } };
    t[0x15] = .{ .mnemonic = "mov", .operands = &.{ .reg, .reg_indirect } };
    t[0x16] = .{ .mnemonic = "mov", .operands = &.{ .reg_indirect, .reg } };
    t[0x17] = .{ .mnemonic = "mov", .operands = &.{ .indexed, .reg } };
    t[0x18] = .{ .mnemonic = "mov", .operands = &.{ .imm16, .reg_indirect } };
    t[0x19] = .{ .mnemonic = "mov", .operands = &.{ .reg, .zp } };
    t[0x1A] = .{ .mnemonic = "mov", .operands = &.{ .zp, .reg } };
    t[0x1B] = .{ .mnemonic = "mov", .operands = &.{ .imm16, .zp } };
    t[0x1C] = .{ .mnemonic = "mov", .operands = &.{ .reg_offset, .reg } };
    t[0x1D] = .{ .mnemonic = "mov", .operands = &.{ .reg, .reg_offset } };

    // 0x2X — mov byte (mov8 / movh / movl + block memory)
    t[0x20] = .{ .mnemonic = "mov8", .operands = &.{ .imm8, .addr } };
    t[0x21] = .{ .mnemonic = "mov8", .operands = &.{ .imm8, .reg } };
    t[0x22] = .{ .mnemonic = "mov8", .operands = &.{ .addr, .reg } };
    t[0x23] = .{ .mnemonic = "mov8", .operands = &.{ .reg, .reg_indirect } };
    t[0x24] = .{ .mnemonic = "mov8", .operands = &.{ .reg_indirect, .reg } };
    t[0x25] = .{ .mnemonic = "mov8", .operands = &.{ .indexed, .reg } };
    t[0x26] = .{ .mnemonic = "movh", .operands = &.{ .reg, .addr } };
    t[0x27] = .{ .mnemonic = "movl", .operands = &.{ .reg, .addr } };
    t[0x28] = .{ .mnemonic = "mov8", .operands = &.{ .imm8, .zp } };
    t[0x29] = .{ .mnemonic = "mov8", .operands = &.{ .zp, .reg } };
    t[0x2A] = .{ .mnemonic = "movh", .operands = &.{ .reg, .zp } };
    t[0x2B] = .{ .mnemonic = "movl", .operands = &.{ .reg, .zp } };
    t[0x2C] = .{ .mnemonic = "bcpy", .operands = &.{ .reg, .reg, .reg } };
    t[0x2D] = .{ .mnemonic = "bfill", .operands = &.{ .reg, .reg, .reg } };

    // 0x3X — stack
    t[0x30] = .{ .mnemonic = "push", .operands = &.{.imm16} };
    t[0x31] = .{ .mnemonic = "push", .operands = &.{.reg} };
    t[0x32] = .{ .mnemonic = "pop", .operands = &.{.reg} };

    // 0x4X — arithmetic primary
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
    t[0x4F] = .{ .mnemonic = "sext", .operands = &.{.reg} };

    // 0x5X — arithmetic carry-propagating
    t[0x50] = .{ .mnemonic = "adc", .operands = &.{ .imm16, .reg } };
    t[0x51] = .{ .mnemonic = "adc", .operands = &.{ .reg, .reg } };
    t[0x52] = .{ .mnemonic = "sbc", .operands = &.{ .imm16, .reg } };
    t[0x53] = .{ .mnemonic = "sbc", .operands = &.{ .reg, .reg } };

    // 0x6X — bitwise (logical word ops + single-bit ops)
    t[0x60] = .{ .mnemonic = "and", .operands = &.{ .imm16, .reg } };
    t[0x61] = .{ .mnemonic = "and", .operands = &.{ .reg, .reg } };
    t[0x62] = .{ .mnemonic = "or", .operands = &.{ .imm16, .reg } };
    t[0x63] = .{ .mnemonic = "or", .operands = &.{ .reg, .reg } };
    t[0x64] = .{ .mnemonic = "xor", .operands = &.{ .imm16, .reg } };
    t[0x65] = .{ .mnemonic = "xor", .operands = &.{ .reg, .reg } };
    t[0x66] = .{ .mnemonic = "not", .operands = &.{.reg} };
    t[0x67] = .{ .mnemonic = "btest", .operands = &.{ .reg, .imm8 } };
    t[0x68] = .{ .mnemonic = "bset", .operands = &.{ .reg, .imm8 } };
    t[0x69] = .{ .mnemonic = "bclr", .operands = &.{ .reg, .imm8 } };

    // 0x7X — shifts / rotates
    t[0x70] = .{ .mnemonic = "shl", .operands = &.{ .reg, .imm8 } };
    t[0x71] = .{ .mnemonic = "shl", .operands = &.{ .reg, .reg } };
    t[0x72] = .{ .mnemonic = "shr", .operands = &.{ .reg, .imm8 } };
    t[0x73] = .{ .mnemonic = "shr", .operands = &.{ .reg, .reg } };
    t[0x74] = .{ .mnemonic = "asr", .operands = &.{ .reg, .imm8 } };
    t[0x75] = .{ .mnemonic = "asr", .operands = &.{ .reg, .reg } };
    t[0x76] = .{ .mnemonic = "rol", .operands = &.{ .reg, .imm8 } };
    t[0x77] = .{ .mnemonic = "rol", .operands = &.{ .reg, .reg } };
    t[0x78] = .{ .mnemonic = "ror", .operands = &.{ .reg, .imm8 } };
    t[0x79] = .{ .mnemonic = "ror", .operands = &.{ .reg, .reg } };

    // 0x8X — comparison
    t[0x80] = .{ .mnemonic = "cmp", .operands = &.{ .reg, .imm16 } };
    t[0x81] = .{ .mnemonic = "cmp", .operands = &.{ .reg, .reg } };
    t[0x82] = .{ .mnemonic = "tst", .operands = &.{ .reg, .imm16 } };
    t[0x83] = .{ .mnemonic = "tst", .operands = &.{ .reg, .reg } };

    // 0x9X — branches
    t[0x90] = .{ .mnemonic = "jmp", .operands = &.{.addr} };
    t[0x91] = .{ .mnemonic = "jmp", .operands = &.{.reg} };
    t[0x92] = .{ .mnemonic = "jeq", .operands = &.{.addr} };
    t[0x93] = .{ .mnemonic = "jne", .operands = &.{.addr} };
    t[0x94] = .{ .mnemonic = "jlt", .operands = &.{.addr} };
    t[0x95] = .{ .mnemonic = "jle", .operands = &.{.addr} };
    t[0x96] = .{ .mnemonic = "jgt", .operands = &.{.addr} };
    t[0x97] = .{ .mnemonic = "jge", .operands = &.{.addr} };
    t[0x98] = .{ .mnemonic = "jcc", .operands = &.{.addr} };
    t[0x99] = .{ .mnemonic = "jcs", .operands = &.{.addr} };
    t[0x9A] = .{ .mnemonic = "jvc", .operands = &.{.addr} };
    t[0x9B] = .{ .mnemonic = "jvs", .operands = &.{.addr} };
    t[0x9C] = .{ .mnemonic = "jz", .operands = &.{.addr} };
    t[0x9D] = .{ .mnemonic = "jnz", .operands = &.{.addr} };
    t[0x9E] = .{ .mnemonic = "djnz", .operands = &.{ .reg, .addr } };
    t[0x9F] = .{ .mnemonic = "jr", .operands = &.{.imm8} };

    // 0xAX — subroutines
    t[0xA0] = .{ .mnemonic = "call", .operands = &.{.addr} };
    t[0xA1] = .{ .mnemonic = "call", .operands = &.{.reg} };
    t[0xA2] = .{ .mnemonic = "ret", .operands = &.{} };

    // 0xBX — flag manipulation
    t[0xB0] = .{ .mnemonic = "clc", .operands = &.{} };
    t[0xB1] = .{ .mnemonic = "sec", .operands = &.{} };
    t[0xB2] = .{ .mnemonic = "cli", .operands = &.{} };
    t[0xB3] = .{ .mnemonic = "sei", .operands = &.{} };
    t[0xB4] = .{ .mnemonic = "clv", .operands = &.{} };

    // 0xCX — misc
    t[0xC0] = .{ .mnemonic = "swap", .operands = &.{ .reg, .reg } };
    t[0xC1] = .{ .mnemonic = "nop", .operands = &.{} };

    // 0xFX — system
    t[0xFC] = .{ .mnemonic = "int", .operands = &.{.imm8} };
    t[0xFD] = .{ .mnemonic = "rti", .operands = &.{} };
    t[0xFE] = .{ .mnemonic = "brk", .operands = &.{} };
    t[0xFF] = .{ .mnemonic = "hlt", .operands = &.{} };

    break :blk t;
};
