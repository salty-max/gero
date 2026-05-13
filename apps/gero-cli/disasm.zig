/// `gero disasm` — read a `.gx` byte buffer, emit asm source to
/// stdout (or to a file via `-o`). Per cli.md §3.6.
///
/// `--bank=N` selects a single bank slot to disassemble; the
/// default is the base image. Out-of-range bank slots surface as
/// an exit-1 error.
const std = @import("std");
const gero = @import("gero");
const cli = @import("cli.zig");
const term_mod = @import("term.zig");

/// Drive the disasm flow against `opts.positional()[0]`.
pub fn execute(
    io: std.Io,
    arena: std.mem.Allocator,
    opts: cli.Options,
    stdout: *std.Io.Writer,
    term: *term_mod.Term,
) !u8 {
    const positionals = opts.positional();
    if (positionals.len < 1) {
        try term.err("gero disasm: missing .gx file path", .{});
        return 2;
    }
    const src_path = positionals[0];

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, src_path, arena, .unlimited) catch |err| {
        try term.err("gero disasm: cannot read {s} ({s})", .{ src_path, @errorName(err) });
        return 1;
    };

    const header = gero.disasm.parseHeader(bytes) catch |err| {
        try term.err("gero disasm: invalid .gx file ({s})", .{@errorName(err)});
        return 1;
    };

    // For the base image, the slice is `header.image`; for a
    // banked target the slice is bank N's 16 KiB segment with the
    // trailing zero-padding trimmed off (codegen zero-fills
    // unused bytes; printing 16 KiB of `; .byte $00` is just
    // noise for the user).
    const bank_size: usize = 0x4000;
    const bank_window_base: u16 = 0xC000;
    const target_bytes: []const u8 = if (opts.bank) |b| blk: {
        if (b >= header.bank_count) {
            try term.err("gero disasm: --bank={d} out of range (cart has {d} bank(s))", .{ b, header.bank_count });
            return 1;
        }
        // @as: widen u8 bank index to usize for the offset math.
        const start = @as(usize, b) * bank_size;
        const raw = header.banks[start .. start + bank_size];
        break :blk trimTrailingZeros(raw);
    } else header.image;

    // Pretty view: address + hex-bytes columns, `; entry point`
    // marker, optional ANSI color. The base image starts at CPU
    // address $0000; a bank is mirrored at the window base
    // $C000 when its `mb` is selected. Entry-point comment only
    // makes sense for the base image (the loader stores the
    // address there).
    const base_addr: u16 = if (opts.bank == null) 0x0000 else bank_window_base;
    const entry_addr: ?u16 = if (opts.bank == null) header.entry_point else null;
    const style: gero.disasm.Style = if (term.color) .ansi else .plain;
    try gero.disasm.writeBytesPretty(arena, stdout, target_bytes, .{
        .base_addr = base_addr,
        .show_bytes = true,
        .entry_addr = entry_addr,
        .style = style,
    });
    return 0;
}

/// Drop trailing `0x00` bytes from `bytes` — codegen pads banks
/// up to the full 16 KiB on disk, but those zeros are the unused
/// tail of a bank and shouldn't render as `; .byte $00` noise.
/// A user with a legitimately-zero-trailing payload can pipe
/// through `gero disasm | head -N` instead.
fn trimTrailingZeros(bytes: []const u8) []const u8 {
    var end = bytes.len;
    while (end > 0 and bytes[end - 1] == 0) end -= 1;
    return bytes[0..end];
}
