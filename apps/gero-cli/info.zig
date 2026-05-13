/// `gero info` — print the `.gx` header in human-readable form.
/// The formatter is pure (takes already-parsed values) so the
/// host shell wires file I/O around it.
const std = @import("std");
const gero = @import("gero");

/// All the values the formatter needs that aren't on the
/// `Header` itself.
pub const InfoContext = struct {
    /// Path the user passed on the CLI — printed verbatim.
    path: []const u8,
    /// Total `.gx` size on disk in bytes.
    file_size: usize,
};

/// Write the multi-line header summary to `out`. Matches the
/// layout sketched in `cli.md` §3.7.
pub fn format(
    out: *std.Io.Writer,
    ctx: InfoContext,
    loaded: gero.vm.LoadedProgram,
) std.Io.Writer.Error!void {
    const h = loaded.header;
    try out.print("file:    {s}\n", .{ctx.path});
    try out.print("size:    {d} bytes\n", .{ctx.file_size});
    try out.print("magic:   GERO\n", .{});
    try out.print("version: 0x{X:0>4}\n", .{h.version});
    try out.print("entry:   0x{X:0>4}\n", .{h.entry_point});
    try out.print("image:   {d} bytes\n", .{h.image_size});
    if (h.bank_count == 0) {
        try out.print("banks:   none\n", .{});
    } else {
        try out.print("banks:   {d} \xC3\x97 16 KB\n", .{h.bank_count});
    }
    if (h.sram_bank_count == 0) {
        try out.print("sram:    none\n", .{});
    } else {
        const noun: []const u8 = if (h.sram_bank_count == 1) "bank" else "banks";
        try out.print("sram:    {d} {s} (battery-backed)\n", .{ h.sram_bank_count, noun });
    }
    if (h.hasDebugSymbols()) {
        // Parse the trailing debug blob to extract the symbol
        // count for the summary line. The slice is borrowed; we
        // only read the count header (no allocation needed here).
        const count = peekSymbolCount(loaded.debug);
        try out.print("debug:   yes (symbols: {d})\n", .{count});
    } else {
        try out.print("debug:   no\n", .{});
    }
}

/// Read just the first 2-byte u16 from the debug blob — that's
/// the symbol count per ISA §7.3. Returns 0 if the blob is too
/// short (treated as "no symbols").
fn peekSymbolCount(debug: []const u8) u16 {
    if (debug.len < 2) return 0;
    return @as(u16, debug[0]) | (@as(u16, debug[1]) << 8);
}

// ---------- tests ----------

const testing = std.testing;

/// Tests reuse the same buildGx helper shape as the loader tests.
fn buildGx(
    out: []u8,
    flags: u16,
    entry: u16,
    image_size: u16,
    bank_count: u8,
    sram_bank_count: u8,
) []u8 {
    @memset(out, 0);
    @memcpy(out[0..4], "GERO");
    out[0x04] = 0x01;
    out[0x05] = 0x00;
    out[0x06] = @truncate(flags & 0xFF);
    out[0x07] = @truncate(flags >> 8);
    out[0x08] = @truncate(entry & 0xFF);
    out[0x09] = @truncate(entry >> 8);
    out[0x0A] = @truncate(image_size & 0xFF);
    out[0x0B] = @truncate(image_size >> 8);
    out[0x0C] = bank_count;
    out[0x0D] = sram_bank_count;
    return out;
}

test "format: unbanked program prints `banks: none` and `sram: none`" {
    var buf: [16]u8 = undefined;
    _ = buildGx(&buf, 0, 0x1100, 0, 0, 0);
    const loaded = try gero.vm.parseGx(&buf);

    var out_buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    try format(&out, .{ .path = "prog.gx", .file_size = buf.len }, loaded);
    const written = out_buf[0..out.end];

    try testing.expect(std.mem.indexOf(u8, written, "file:    prog.gx") != null);
    try testing.expect(std.mem.indexOf(u8, written, "size:    16 bytes") != null);
    try testing.expect(std.mem.indexOf(u8, written, "magic:   GERO") != null);
    try testing.expect(std.mem.indexOf(u8, written, "version: 0x0001") != null);
    try testing.expect(std.mem.indexOf(u8, written, "entry:   0x1100") != null);
    try testing.expect(std.mem.indexOf(u8, written, "image:   0 bytes") != null);
    try testing.expect(std.mem.indexOf(u8, written, "banks:   none") != null);
    try testing.expect(std.mem.indexOf(u8, written, "sram:    none") != null);
    try testing.expect(std.mem.indexOf(u8, written, "debug:   no") != null);
}

test "format: banked + sram + debug program renders all sections" {
    // banked + debug flags; bank_count = 4, sram_count = 2.
    var buf: [16 + 0x4000 * 4 + 2]u8 = undefined;
    _ = buildGx(buf[0..16], 0x0003, 0x1100, 0, 4, 2);
    @memset(buf[16..], 0); // image+banks+debug all zeroed (just need bytes to fit)
    const loaded = try gero.vm.parseGx(&buf);

    var out_buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    try format(&out, .{ .path = "game.gx", .file_size = buf.len }, loaded);
    const written = out_buf[0..out.end];

    try testing.expect(std.mem.indexOf(u8, written, "banks:   4 ") != null);
    try testing.expect(std.mem.indexOf(u8, written, "× 16 KB") != null);
    try testing.expect(std.mem.indexOf(u8, written, "sram:    2 banks (battery-backed)") != null);
    try testing.expect(std.mem.indexOf(u8, written, "debug:   yes") != null);
}

test "format: single SRAM bank uses singular noun" {
    var buf: [16 + 0x4000]u8 = undefined;
    _ = buildGx(buf[0..16], 0x0001, 0x0000, 0, 1, 1);
    @memset(buf[16..], 0);
    const loaded = try gero.vm.parseGx(&buf);

    var out_buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    try format(&out, .{ .path = "x.gx", .file_size = buf.len }, loaded);

    try testing.expect(std.mem.indexOf(u8, out_buf[0..out.end], "sram:    1 bank (battery-backed)") != null);
}

test "format: file size is the on-disk size, not just the image" {
    var buf: [16 + 7]u8 = undefined;
    _ = buildGx(buf[0..16], 0, 0x0000, 7, 0, 0);
    @memset(buf[16..], 0xAB);
    const loaded = try gero.vm.parseGx(&buf);

    var out_buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    try format(&out, .{ .path = "x.gx", .file_size = buf.len }, loaded);

    try testing.expect(std.mem.indexOf(u8, out_buf[0..out.end], "size:    23 bytes") != null);
    try testing.expect(std.mem.indexOf(u8, out_buf[0..out.end], "image:   7 bytes") != null);
}
