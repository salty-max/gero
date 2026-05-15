/// Byte → `Instruction` decoder. Reuses the asm-side opcode
/// table (`opcode_resolver.shape_by_opcode`) for the reverse
/// mapping, so the printer can reconstruct the exact asm syntax
/// the bytes came from — including `[reg]` indirect and
/// `[addr + reg]` indexed forms that the VM's bare opcode table
/// flattens to plain `reg, reg, reg` schemas.
const std = @import("std");
const opres = @import("../asm/opcode_resolver.zig");

/// One decoded operand. Mirrors the asm-side `Kind` enum but
/// carries the actual operand bytes rather than a type tag.
pub const Operand = union(enum) {
    /// 1-byte register index (raw, post-decode mapping via
    /// `vm.Register` lives in the printer).
    reg: u8,
    /// 1-byte immediate.
    imm8: u8,
    /// 2-byte little-endian immediate.
    imm16: u16,
    /// 2-byte little-endian address.
    addr: u16,
    /// 1-byte zero-page address.
    zp: u8,
    /// `[reg]` — register index used as a pointer.
    reg_indirect: u8,
    /// `[addr + reg]` — indexed addressing (3 bytes: addr LE + reg).
    indexed: Indexed,
    /// `[reg + imm8]` / `[reg - imm8]` — register-relative
    /// addressing (2 bytes: base-reg + signed imm8 offset).
    reg_offset: RegOffset,

    /// `[addr + reg]` payload — the addr word + the index reg
    /// index. Lives inside `Operand.indexed`.
    pub const Indexed = struct {
        addr: u16,
        reg: u8,
    };

    /// `[reg + imm]` payload — the base reg index + the raw signed
    /// imm8 (caller sign-extends + renders sign in the asm output).
    pub const RegOffset = struct {
        reg: u8,
        offset: i8,
    };
};

/// One decoded instruction.
pub const Instruction = struct {
    /// Raw opcode byte.
    opcode: u8,
    /// Lowercase mnemonic from the asm spec (borrowed from the
    /// opcode table — static lifetime).
    mnemonic: []const u8,
    /// Operands in source order. Storage backing depends on the
    /// caller's allocator — see `decode` below.
    operands: []const Operand,
    /// Total byte width (opcode + sum of operand widths).
    size: u8,
};

/// Failure modes when decoding a single instruction.
pub const DecodeError = error{
    /// Opcode byte isn't in the ISA's reverse table.
    UnknownOpcode,
    /// Bytes ran out before the operands could be fully read.
    Truncated,
    OutOfMemory,
};

/// Decode the one instruction starting at `bytes[offset]`. Returns
/// the instruction (with operands allocated via `allocator`) plus
/// the byte offset of the next instruction.
///
/// The opcode byte determines the operand schema via
/// `opres.shape_by_opcode`. Unknown opcodes return
/// `error.UnknownOpcode` — the caller decides whether to skip the
/// byte and continue (e.g. emit a `.byte $XX` directive) or
/// abort.
pub fn decodeOne(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    offset: usize,
) DecodeError!Decoded {
    if (offset >= bytes.len) return error.Truncated;
    const op = bytes[offset];
    const shape = opres.shape_by_opcode[op] orelse return error.UnknownOpcode;

    var operands: std.ArrayList(Operand) = .empty;
    errdefer operands.deinit(allocator);

    var cursor: usize = offset + 1;
    for (shape.kinds) |kind| {
        const decoded_op, const advance = try readOperand(bytes, cursor, kind);
        try operands.append(allocator, decoded_op);
        cursor += advance;
    }
    if (cursor > bytes.len) return error.Truncated;

    const operands_slice = try operands.toOwnedSlice(allocator);
    return .{
        .instruction = .{
            .opcode = op,
            .mnemonic = shape.mnemonic,
            .operands = operands_slice,
            // safety: cursor - offset bounded by 1 (opcode) + sum
            //         of operand widths; max instruction = 5 bytes.
            .size = @intCast(cursor - offset),
        },
        .next_offset = cursor,
    };
}

/// Result of `decodeOne`: the decoded instruction plus the next
/// byte offset to feed back in for the following instruction.
pub const Decoded = struct {
    instruction: Instruction,
    next_offset: usize,
};

/// Read one operand from `bytes[cursor..]` per its `kind`. Returns
/// the decoded operand and the byte width consumed.
fn readOperand(bytes: []const u8, cursor: usize, kind: opres.Kind) DecodeError!struct { Operand, usize } {
    return switch (kind) {
        .reg => .{ .{ .reg = try readByte(bytes, cursor) }, 1 },
        .imm8 => .{ .{ .imm8 = try readByte(bytes, cursor) }, 1 },
        .imm16 => .{ .{ .imm16 = try readWord(bytes, cursor) }, 2 },
        .addr => .{ .{ .addr = try readWord(bytes, cursor) }, 2 },
        .zp => .{ .{ .zp = try readByte(bytes, cursor) }, 1 },
        .reg_indirect => .{ .{ .reg_indirect = try readByte(bytes, cursor) }, 1 },
        .indexed => blk: {
            const addr = try readWord(bytes, cursor);
            const reg = try readByte(bytes, cursor + 2);
            break :blk .{ .{ .indexed = .{ .addr = addr, .reg = reg } }, 3 };
        },
        .reg_offset => blk: {
            const reg = try readByte(bytes, cursor);
            const raw = try readByte(bytes, cursor + 1);
            // safety: bitcast u8 → i8 to recover the signed offset.
            const offset: i8 = @bitCast(raw);
            break :blk .{ .{ .reg_offset = .{ .reg = reg, .offset = offset } }, 2 };
        },
    };
}

fn readByte(bytes: []const u8, cursor: usize) DecodeError!u8 {
    if (cursor >= bytes.len) return error.Truncated;
    return bytes[cursor];
}

fn readWord(bytes: []const u8, cursor: usize) DecodeError!u16 {
    if (cursor + 1 >= bytes.len) return error.Truncated;
    // @as: widen each u8 byte to u16 before the OR / shift so the result is u16.
    return @as(u16, bytes[cursor]) | (@as(u16, bytes[cursor + 1]) << 8);
}

/// Release the operand slice attached to `inst`.
pub fn freeInstruction(allocator: std.mem.Allocator, inst: Instruction) void {
    allocator.free(inst.operands);
}
