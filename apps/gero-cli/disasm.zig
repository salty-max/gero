/// `gero disasm` — read a `.gx` byte buffer, emit asm source to
/// stdout (or to a file via `-o`). Per cli.md §3.6.
///
/// `--bank=N` selects a single bank slot to disassemble. With no
/// `--bank` flag, the default renders the base image followed by
/// every bank, each prefixed with a `; --- ... ---` section
/// header. Out-of-range bank slots surface as an exit-1 error.
const std = @import("std");
const gero = @import("gero");
const cli = @import("cli.zig");
const term_mod = @import("term.zig");

const bank_size: usize = 0x4000;
const bank_window_base: u16 = 0xC000;

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

    if (opts.check_roundtrip) return checkRoundTrip(arena, bytes, header, src_path, opts.quiet, stdout, term);

    // Parse the debug-symbol section (if present) so the printer
    // renders `call greet` instead of `call &C000` etc. Borrows
    // name bytes from `header.debug`; valid for the lifetime of
    // this function.
    const symbols = gero.disasm.parseSymbols(arena, header.debug) catch |err| {
        try term.err("gero disasm: malformed debug section ({s})", .{@errorName(err)});
        return 1;
    };

    const style: gero.disasm.Style = if (term.color) gero.disasm.Style.ansi else gero.disasm.Style.plain;

    if (opts.bank) |b| {
        if (b >= header.bank_count) {
            try term.err("gero disasm: --bank={d} out of range (cart has {d} bank(s))", .{ b, header.bank_count });
            return 1;
        }
        // @as: widen u8 bank index to usize for the offset math.
        const start = @as(usize, b) * bank_size;
        const raw = header.banks[start .. start + bank_size];
        try gero.disasm.writeBytesPretty(arena, stdout, trimTrailingZeros(raw), .{
            .base_addr = bank_window_base,
            .show_bytes = opts.show_bytes,
            .style = style,
            .symbols = symbols,
        });
        return 0;
    }

    // No `--bank` → whole-cart view. Render the base image first
    // with its entry-point marker, then walk every bank with a
    // section header so a multi-bank cart fits in one transcript.
    if (header.bank_count > 0) try writeSection(stdout, style, "--- base image ---");
    try gero.disasm.writeBytesPretty(arena, stdout, header.image, .{
        .base_addr = 0x0000,
        .show_bytes = opts.show_bytes,
        .entry_addr = header.entry_point,
        .style = style,
        .symbols = symbols,
    });

    var bank_idx: u8 = 0;
    while (bank_idx < header.bank_count) : (bank_idx += 1) {
        // @as: widen u8 bank index to usize for the offset math.
        const start = @as(usize, bank_idx) * bank_size;
        const raw = header.banks[start .. start + bank_size];
        try writeBankSection(stdout, style, bank_idx);
        try gero.disasm.writeBytesPretty(arena, stdout, trimTrailingZeros(raw), .{
            .base_addr = bank_window_base,
            .show_bytes = opts.show_bytes,
            .style = style,
            .symbols = symbols,
        });
    }
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

/// Emit a `; --- TEXT ---` separator, dim-styled (`Style.comment`)
/// when ANSI is on. Blank line above and below so the section
/// stands out in the transcript.
fn writeSection(out: *std.Io.Writer, style: gero.disasm.Style, text: []const u8) !void {
    try out.print("\n{s}; {s}{s}\n", .{ style.comment, text, style.reset });
}

/// Emit a `; --- bank N ---` separator for the whole-cart view.
fn writeBankSection(out: *std.Io.Writer, style: gero.disasm.Style, idx: u8) !void {
    var buf: [32]u8 = undefined;
    // allow-strict: idx is u8 — "--- bank 255 ---" fits in 16 chars,
    // well under the 32-byte buffer.
    const label = std.fmt.bufPrint(&buf, "--- bank {d} ---", .{idx}) catch unreachable;
    try writeSection(out, style, label);
}

test "disasm: writeSection emits plain header without ANSI" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeSection(&out.writer, gero.disasm.Style.plain, "--- base image ---");
    try std.testing.expectEqualStrings("\n; --- base image ---\n", out.written());
}

test "disasm: writeSection wraps text in dim ANSI escapes" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeSection(&out.writer, gero.disasm.Style.ansi, "--- bank 0 ---");
    try std.testing.expectEqualStrings("\n\x1b[2m; --- bank 0 ---\x1b[0m\n", out.written());
}

test "disasm: writeBankSection labels the bank by index" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeBankSection(&out.writer, gero.disasm.Style.plain, 3);
    try std.testing.expectEqualStrings("\n; --- bank 3 ---\n", out.written());
}

/// Drive `bytes` through `roundTripArchive` and assert that the
/// base image comes back byte-identical. The debug section's
/// symbol order can shift without breaking losslessness, so it
/// is excluded. Bank sections are excluded too — the underlying
/// `roundTripArchive` only disassembles the base image, so a
/// multi-bank archive's `header.banks` always disagrees with the
/// re-assembled side. Extending the round-trip helper to cover
/// banks is tracked separately.
fn checkRoundTrip(
    arena: std.mem.Allocator,
    bytes: []const u8,
    header: gero.disasm.Header,
    src_path: []const u8,
    quiet: bool,
    stdout: *std.Io.Writer,
    term: *term_mod.Term,
) !u8 {
    const reasm = gero.disasm.roundTripArchive(arena, bytes) catch |err| {
        try term.err("gero disasm: round-trip failed for {s} ({s})", .{ src_path, @errorName(err) });
        return 1;
    };

    const h_reasm = gero.disasm.parseHeader(reasm) catch |err| {
        try term.err("gero disasm: re-assembled archive is malformed ({s})", .{@errorName(err)});
        return 1;
    };

    if (!std.mem.eql(u8, header.image, h_reasm.image)) {
        try term.err("gero disasm: round-trip image mismatch for {s} ({d} vs {d} bytes)", .{ src_path, header.image.len, h_reasm.image.len });
        return 1;
    }

    if (!quiet) try stdout.print("round-trip ok: {s} ({d} image bytes)\n", .{ src_path, header.image.len });
    return 0;
}
