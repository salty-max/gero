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
const header = @import("header.zig");

/// Mnemonic column width in characters — covers every ISA
/// mnemonic plus one trailing space.
const mnemonic_col_width: usize = 6;

/// Minimum number of consecutive `$00` bytes (with no symbol
/// landing inside them) before the printer collapses the run into
/// a single `; N bytes zero padding (org $XXXX)` comment. Below
/// this threshold the bytes still render as individual
/// `; .byte $00` lines so small genuine gaps aren't hidden.
const zero_run_collapse_threshold: usize = 4;

/// ANSI escape strings the disasm printer wraps around each
/// rendered piece. `Style.plain` emits no escapes (round-trip);
/// `Style.ansi` is the human-facing palette the CLI flips to
/// when stdout is a TTY.
pub const Style = struct {
    /// `XXXX:` address gutter.
    address: []const u8 = "",
    /// `10 30 00 02` hex-bytes column.
    bytes_col: []const u8 = "",
    /// `mov`, `int`, `hlt`, … mnemonic.
    mnemonic: []const u8 = "",
    /// `r1`, `acu`, `mb`, … register names.
    register: []const u8 = "",
    /// `$1234`, `&5678`, hex/addr literals.
    literal: []const u8 = "",
    /// `; .byte`, `; truncated` warnings on undecodable bytes.
    comment: []const u8 = "",
    /// `; entry point` callout.
    entry: []const u8 = "",
    /// Reset escape emitted after every wrapped piece.
    reset: []const u8 = "",

    /// No ANSI — default for tests, round-trip, and non-TTY.
    pub const plain: Style = .{};

    /// Standard palette: dim gutter / bytes, bold mnemonic, cyan
    /// registers, yellow literals, dim comments, bold-yellow entry.
    pub const ansi: Style = .{
        .address = "\x1b[2m",
        .bytes_col = "\x1b[2m",
        .mnemonic = "\x1b[1m",
        .register = "\x1b[36m",
        .literal = "\x1b[33m",
        .comment = "\x1b[2m",
        .entry = "\x1b[1;33m",
        .reset = "\x1b[0m",
    };
};

/// Render one instruction to `writer`. Caller controls leading
/// indent / label emission separately. Pass `Style.plain` for the
/// round-trip-friendly bare output; `Style.ansi` for the colored
/// CLI view. Optional `symbols` substitutes matching addresses
/// with their name (e.g. `call greet` instead of `call &C000`).
pub fn writeInstruction(
    writer: *std.Io.Writer,
    inst: decoder.Instruction,
    style: Style,
    symbols: ?header.Symbols,
) std.Io.Writer.Error!void {
    try writer.print("{s}{s}{s}", .{ style.mnemonic, inst.mnemonic, style.reset });
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
        try writeOperand(writer, op, style, symbols);
    }
}

/// Render the bytes between `addr` and `addr + N` (for some
/// caller-chosen N) as a series of asm instructions, one per
/// line, terminated by `\n`. Stops on the first
/// `error.UnknownOpcode` and emits a `; .byte $XX` comment so the
/// surrounding context stays readable.
///
/// Output is round-trip-friendly: pass it to the assembler and
/// you get the same bytes back (for all-code programs). For the
/// human-facing "disassembly view" with address column + raw
/// hex bytes + entry marker, use `writeBytesPretty`.
pub fn writeBytes(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    bytes: []const u8,
) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
    return writeBytesPretty(allocator, writer, bytes, .{});
}

/// Optional decoration knobs for `writeBytesPretty`.
pub const PrintOptions = struct {
    /// Start address of `bytes[0]` in CPU space. Set this when
    /// either the address gutter, the entry marker, or
    /// symbol-address mapping needs a meaningful CPU address.
    /// `null` (default) disables all three.
    base_addr: ?u16 = null,
    /// When `true` (default) and `base_addr` is set, each line
    /// gets a leading `XXXX:  ` gutter. Set to `false` to keep
    /// symbol mapping but suppress the gutter — the round-trip
    /// path needs symbol-aware rendering whose output is still
    /// parseable by the assembler.
    show_addresses: bool = true,
    /// `true` → emit a fixed-width hex-bytes column between the
    /// address and the asm line (objdump style). Requires
    /// `base_addr` to be meaningful for alignment; otherwise just
    /// shows the bytes inline.
    show_bytes: bool = false,
    /// When the cursor lands at `entry_addr`, append a
    /// `; entry point` comment to that line. `null` skips the
    /// marker. Only meaningful with `base_addr` set.
    entry_addr: ?u16 = null,
    /// ANSI palette to wrap around each rendered piece. Default
    /// `Style.plain` emits no escapes.
    style: Style = .plain,
    /// Optional debug-symbol lookup. When set, `addr` operands
    /// matching a known symbol render as the symbol name instead
    /// of `&XXXX`. `null` keeps the raw addresses.
    symbols: ?header.Symbols = null,
};

/// Same shape as `writeBytes` but with `PrintOptions` for the
/// disassembly view (address column, hex bytes, entry marker).
pub fn writeBytesPretty(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    bytes: []const u8,
    opts: PrintOptions,
) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        // Before trying to decode an instruction, check whether
        // the cursor lands at a *data* symbol — if so, render
        // those bytes as a `data8` block instead of fake
        // instructions. Length goes from this symbol's address
        // to the next symbol's address (or end of section).
        if (dataSymbolAt(offset, opts)) |info| {
            const len = @min(info.length, bytes.len - offset);
            try writeDataBlock(writer, bytes, offset, len, info.name, opts);
            offset += len;
            continue;
        }
        // Detect a run of $00 bytes with no symbol landing inside
        // them. Anything ≥ 4 is almost certainly leading or
        // mid-image padding from an `org $XXXX` directive in the
        // source — collapse to a single annotated comment instead
        // of N noisy `; .byte $00` lines.
        if (bytes[offset] == 0x00) {
            const run_end = scanZeroRun(bytes, offset, opts);
            if (run_end - offset >= zero_run_collapse_threshold) {
                try writeZeroRunComment(writer, offset, run_end - offset, opts);
                offset = run_end;
                continue;
            }
        }
        const out_or_err = decoder.decodeOne(allocator, bytes, offset);
        if (out_or_err) |out| {
            defer decoder.freeInstruction(allocator, out.instruction);
            try writePrefix(writer, bytes, offset, out.instruction.size, opts);
            try writeInstruction(writer, out.instruction, opts.style, opts.symbols);
            try writeEntryMarker(writer, offset, opts);
            try writer.writeByte('\n');
            offset = out.next_offset;
        } else |err| switch (err) {
            error.UnknownOpcode => {
                try writePrefix(writer, bytes, offset, 1, opts);
                try writer.print("{s}; .byte ${X:0>2}{s}", .{ opts.style.comment, bytes[offset], opts.style.reset });
                try writeEntryMarker(writer, offset, opts);
                try writer.writeByte('\n');
                offset += 1;
            },
            error.Truncated => {
                try writer.print("{s}; truncated at offset ${X:0>4}{s}\n", .{ opts.style.comment, offset, opts.style.reset });
                break;
            },
            error.OutOfMemory => return error.OutOfMemory,
        }
    }
}

/// What `dataSymbolAt` returns — a matched data symbol's name
/// plus how many bytes the data block spans (from this offset
/// to the next symbol's address or to end-of-section).
const DataBlock = struct {
    name: []const u8,
    length: usize,
};

/// If `offset` corresponds to the CPU address of a `data`-kind
/// symbol, return its name + length. `null` otherwise. Length is
/// the gap to the next symbol in the same section (whether label
/// or data); when no later symbol exists we return a "rest of
/// section" sentinel that `writeDataBlock` caps at `bytes.len`.
fn dataSymbolAt(offset: usize, opts: PrintOptions) ?DataBlock {
    const symbols = opts.symbols orelse return null;
    const base = opts.base_addr orelse return null;
    // @as: offset bounded by caller's slice — fits u16 in the base image / bank window contexts.
    const cur_addr: u16 = base +% @as(u16, @intCast(offset));
    for (symbols.entries, 0..) |e, i| {
        if (e.address != cur_addr) continue;
        if (e.kind != .data) return null;
        // Find the smallest later-symbol address that lives in
        // the same section (`> cur_addr`). Entries are sorted by
        // address ascending, so the first hit wins.
        for (symbols.entries[i + 1 ..]) |later| {
            if (later.address > cur_addr) {
                return .{ .name = e.name, .length = later.address - cur_addr };
            }
        }
        // No later symbol — let writeDataBlock cap at bytes.len.
        return .{ .name = e.name, .length = std.math.maxInt(usize) };
    }
    return null;
}

/// Render `bytes[offset..offset+length]` as a `data8 <name> = $XX, ...`
/// directive — round-trippable through the assembler. Uses its
/// own minimal prefix (address only, no hex-bytes column since
/// the bytes are inlined in the directive itself).
fn writeDataBlock(
    writer: *std.Io.Writer,
    bytes: []const u8,
    offset: usize,
    length: usize,
    name: []const u8,
    opts: PrintOptions,
) std.Io.Writer.Error!void {
    const end = @min(offset + length, bytes.len);
    if (opts.show_addresses) if (opts.base_addr) |base| {
        // @as: offset bounded by caller's slice (≤ 64 KiB image / 16 KiB bank).
        const addr: u16 = base +% @as(u16, @intCast(offset));
        try writer.print("{s}{X:0>4}:{s}  ", .{ opts.style.address, addr, opts.style.reset });
    };
    // Pad with the same width the instruction lines use for the
    // hex-bytes column (5 bytes × 3 chars + 1 trailing space) so
    // the `data8` keyword aligns with the mnemonic column above
    // and below it.
    if (opts.show_bytes) try writer.writeAll(" " ** 16);
    try writer.print("{s}data8{s} {s}{s}{s} = ", .{ opts.style.mnemonic, opts.style.reset, opts.style.register, name, opts.style.reset });
    var i: usize = offset;
    var first = true;
    while (i < end) : (i += 1) {
        if (!first) try writer.writeAll(", ");
        first = false;
        try writer.print("{s}${X:0>2}{s}", .{ opts.style.literal, bytes[i], opts.style.reset });
    }
    try writer.writeByte('\n');
}

/// Walk forward from `start` while `bytes[i] == 0x00`, stopping
/// at end-of-buffer or at any symbol whose CPU address lands at
/// or after the run (to avoid swallowing a labeled region that
/// happens to begin with zero bytes). Returns the offset of the
/// first non-zero byte / next symbol / end of buffer.
fn scanZeroRun(bytes: []const u8, start: usize, opts: PrintOptions) usize {
    var i: usize = start;
    while (i < bytes.len and bytes[i] == 0x00) : (i += 1) {
        // A symbol exactly at offset `start` was already handled
        // by the caller (`dataSymbolAt`/label path), so only stop
        // when a *later* symbol lands inside the run.
        if (i > start and symbolAtOffset(i, opts)) break;
    }
    return i;
}

/// `true` if any symbol in `opts.symbols` has its CPU address
/// equal to `base_addr + offset`. Used by `scanZeroRun` to stop
/// the run at the next labeled region.
fn symbolAtOffset(offset: usize, opts: PrintOptions) bool {
    const symbols = opts.symbols orelse return false;
    const base = opts.base_addr orelse return false;
    // @as: offset bounded by caller's slice (≤ 64 KiB image / 16 KiB bank).
    const addr: u16 = base +% @as(u16, @intCast(offset));
    for (symbols.entries) |e| if (e.address == addr) return true;
    return false;
}

/// Render a collapsed zero-padding run as a single annotated
/// comment line: `XXXX:  ; N bytes zero padding (org $YYYY)`.
/// `YYYY` is the CPU address of the first byte AFTER the run —
/// re-assembling with that `org` directive reproduces the same
/// padding (codegen zero-fills up to the directive's address).
fn writeZeroRunComment(
    writer: *std.Io.Writer,
    offset: usize,
    run_len: usize,
    opts: PrintOptions,
) std.Io.Writer.Error!void {
    if (opts.base_addr) |base| {
        // @as: offset bounded by caller's slice.
        const addr: u16 = base +% @as(u16, @intCast(offset));
        try writer.print("{s}{X:0>4}:{s}  ", .{ opts.style.address, addr, opts.style.reset });
    }
    // Match the width the instruction lines reserve for the
    // hex-bytes column when `show_bytes` is on, so the comment
    // sits at the mnemonic column.
    if (opts.show_bytes) try writer.writeAll(" " ** 16);
    const after: u16 = @intCast(offset + run_len);
    const next: u16 = if (opts.base_addr) |b| b +% after else after;
    try writer.print("{s}; {d} bytes zero padding (org ${X:0>4}){s}\n", .{ opts.style.comment, run_len, next, opts.style.reset });
}

/// `XXXX:  ` address column + optional hex-bytes column. Width
/// of the hex column is fixed at 5 bytes (max ISA instruction
/// width) so subsequent columns align.
fn writePrefix(
    writer: *std.Io.Writer,
    bytes: []const u8,
    offset: usize,
    size: usize,
    opts: PrintOptions,
) std.Io.Writer.Error!void {
    if (opts.show_addresses) if (opts.base_addr) |base| {
        // @as: offset bounded by caller's slice (max 64 KiB image / 16 KiB bank) so the u16 narrow never truncates.
        const addr: u16 = base +% @as(u16, @intCast(offset));
        try writer.print("{s}{X:0>4}:{s}  ", .{ opts.style.address, addr, opts.style.reset });
    };
    if (opts.show_bytes) {
        const end = @min(offset + size, bytes.len);
        const max_inst_bytes: usize = 5;
        try writer.writeAll(opts.style.bytes_col);
        var i: usize = offset;
        while (i < end) : (i += 1) try writer.print("{X:0>2} ", .{bytes[i]});
        try writer.writeAll(opts.style.reset);
        // Pad to fixed width so the asm column aligns.
        var pad: usize = (max_inst_bytes - (end - offset)) * 3;
        while (pad > 0) : (pad -= 1) try writer.writeByte(' ');
        try writer.writeAll(" ");
    }
}

fn writeEntryMarker(
    writer: *std.Io.Writer,
    offset: usize,
    opts: PrintOptions,
) std.Io.Writer.Error!void {
    if (opts.entry_addr) |e| if (opts.base_addr) |base| {
        // @as: same bound as writePrefix — offset fits u16 within the bank window / base image.
        const addr: u16 = base +% @as(u16, @intCast(offset));
        if (addr == e) try writer.print("  {s}; entry point{s}", .{ opts.style.entry, opts.style.reset });
    };
}

fn writeOperand(
    writer: *std.Io.Writer,
    op: decoder.Operand,
    style: Style,
    symbols: ?header.Symbols,
) std.Io.Writer.Error!void {
    switch (op) {
        .reg => |r| try writeReg(writer, r, style),
        .imm8 => |v| try writer.print("{s}${X:0>2}{s}", .{ style.literal, v, style.reset }),
        .imm16 => |v| try writer.print("{s}${X:0>4}{s}", .{ style.literal, v, style.reset }),
        .addr => |v| try writeAddrOrSymbol(writer, v, style, symbols),
        // ZP renders as a 1-digit-zero-padded `&XX` (Addr literal) so
        // it round-trips: the assembler's resolver picks the ZP form
        // again when the value fits in `0..0xFF`. Emitting as `$XX`
        // would re-parse as imm8 and break round-trip.
        .zp => |v| try writer.print("{s}&{X:0>2}{s}", .{ style.literal, v, style.reset }),
        .reg_indirect => |r| {
            try writer.writeByte('[');
            try writeReg(writer, r, style);
            try writer.writeByte(']');
        },
        .indexed => |idx| {
            try writer.writeByte('[');
            try writeAddrOrSymbol(writer, idx.addr, style, symbols);
            try writer.writeAll(" + ");
            try writeReg(writer, idx.reg, style);
            try writer.writeByte(']');
        },
        .reg_offset => |r| {
            try writer.writeByte('[');
            try writeReg(writer, r.reg, style);
            if (r.offset >= 0) {
                // @as: narrow non-negative i8 → u8 for the hex print.
                const v: u8 = @as(u8, @intCast(r.offset));
                try writer.print(" + {s}${X:0>2}{s}", .{ style.literal, v, style.reset });
            } else {
                // i8 negation overflows only for −128; render that
                // boundary as `$80` (its absolute value) directly.
                // @as: narrow `-offset` (in i8 range 1..127) → u8.
                const abs: u8 = if (r.offset == -128) 0x80 else @as(u8, @intCast(-r.offset));
                try writer.print(" - {s}${X:0>2}{s}", .{ style.literal, abs, style.reset });
            }
            try writer.writeByte(']');
        },
    }
}

/// Render an address: prefer a matching symbol name (cyan, no
/// `&` prefix) over the raw `&XXXX` literal. The asm accepts
/// bare identifiers as label-refs so the symbolic form
/// round-trips.
fn writeAddrOrSymbol(
    writer: *std.Io.Writer,
    addr: u16,
    style: Style,
    symbols: ?header.Symbols,
) std.Io.Writer.Error!void {
    if (symbols) |s| if (s.lookup(addr)) |name| {
        try writer.print("{s}{s}{s}", .{ style.register, name, style.reset });
        return;
    };
    try writer.print("{s}&{X:0>4}{s}", .{ style.literal, addr, style.reset });
}

fn writeReg(writer: *std.Io.Writer, idx: u8, style: Style) std.Io.Writer.Error!void {
    // Map the raw 0..14 index back to the canonical asm name via
    // the `vm.Register` enum. Out-of-range bytes (the VM would
    // fault on these at runtime) round-trip as `r?<hex>` so the
    // disasm output is still readable instead of crashing.
    try writer.writeAll(style.register);
    if (std.enums.fromInt(gero.vm.Register, idx)) |reg| {
        try writer.writeAll(@tagName(reg));
    } else {
        try writer.print("r?{X:0>2}", .{idx});
    }
    try writer.writeAll(style.reset);
}
