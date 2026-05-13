/// Pretty-printer for decoded instructions. Emits asm syntax
/// the assembler can re-consume (round-trip), with an aligned
/// mnemonic column and conventional hex / addr / register
/// literals.
///
/// Output shape (one line per instruction):
///   `<mnemonic-padded-to-width>  <op1>, <op2>`
///
/// Columns are right-padded to `mnemonic_col_width` so the
/// operands line up across the block.
const std = @import("std");
const gero = @import("../gero.zig");
const decoder = @import("decoder.zig");

/// Mnemonic column width in characters — covers every v0.1
/// mnemonic plus one trailing space.
const mnemonic_col_width: usize = 6;

/// Render one instruction to `writer`. Caller controls leading
/// indent / label emission separately.
pub fn writeInstruction(writer: *std.Io.Writer, inst: decoder.Instruction) std.Io.Writer.Error!void {
    try writer.print("{s}", .{inst.mnemonic});
    // Pad the mnemonic column — only when operands follow. A
    // zero-operand mnemonic (`hlt`, `nop`, `ret`, …) prints
    // unpadded so the line has no trailing spaces.
    if (inst.operands.len > 0) {
        var pad: usize = if (inst.mnemonic.len < mnemonic_col_width)
            mnemonic_col_width - inst.mnemonic.len
        else
            1;
        while (pad > 0) : (pad -= 1) try writer.writeByte(' ');
    }

    for (inst.operands, 0..) |op, i| {
        if (i != 0) try writer.writeAll(", ");
        try writeOperand(writer, op);
    }
}

/// Render the bytes between `addr` and `addr + N` (for some
/// caller-chosen N) as a series of asm instructions, one per
/// line, terminated by `\n`. Stops on the first
/// `error.UnknownOpcode` and emits a `; .byte $XX` comment so the
/// surrounding context stays readable.
pub fn writeBytes(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    bytes: []const u8,
) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const out = decoder.decodeOne(allocator, bytes, offset) catch |err| switch (err) {
            error.UnknownOpcode => {
                try writer.print("; .byte ${X:0>2}\n", .{bytes[offset]});
                offset += 1;
                continue;
            },
            error.Truncated => {
                try writer.print("; truncated at offset ${X:0>4}\n", .{offset});
                break;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer decoder.freeInstruction(allocator, out.instruction);
        try writeInstruction(writer, out.instruction);
        try writer.writeByte('\n');
        offset = out.next_offset;
    }
}

fn writeOperand(writer: *std.Io.Writer, op: decoder.Operand) std.Io.Writer.Error!void {
    switch (op) {
        .reg => |r| try writeReg(writer, r),
        .imm8 => |v| try writer.print("${X:0>2}", .{v}),
        .imm16 => |v| try writer.print("${X:0>4}", .{v}),
        .addr => |v| try writer.print("&{X:0>4}", .{v}),
        .zp => |v| try writer.print("${X:0>2}", .{v}),
        .reg_indirect => |r| {
            try writer.writeByte('[');
            try writeReg(writer, r);
            try writer.writeByte(']');
        },
        .indexed => |idx| {
            try writer.print("[&{X:0>4} + ", .{idx.addr});
            try writeReg(writer, idx.reg);
            try writer.writeByte(']');
        },
    }
}

fn writeReg(writer: *std.Io.Writer, idx: u8) std.Io.Writer.Error!void {
    // Map the raw 0..14 index back to the canonical asm name via
    // the `vm.Register` enum. Out-of-range bytes (the VM would
    // fault on these at runtime) round-trip as `r?<hex>` so the
    // disasm output is still readable instead of crashing.
    if (std.enums.fromInt(gero.vm.Register, idx)) |reg| {
        try writer.writeAll(@tagName(reg));
    } else {
        try writer.print("r?{X:0>2}", .{idx});
    }
}
