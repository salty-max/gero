const std = @import("std");
const gero = @import("gero");

/// Build a minimal `.gx` byte buffer per ISA §7.1.
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

test "header: minimal valid cart exposes fields" {
    var buf: [16 + 3]u8 = undefined;
    _ = buildGx(&buf, 0, 0x1100, 3, 0, 0);
    buf[16] = 0xFF; // image bytes (just `hlt` x 3, irrelevant)
    buf[17] = 0xFF;
    buf[18] = 0xFF;

    const h = try gero.disasm.parseHeader(&buf);
    try std.testing.expectEqual(@as(u16, 0x0001), h.version);
    try std.testing.expectEqual(@as(u16, 0x0000), h.flags);
    try std.testing.expectEqual(@as(u16, 0x1100), h.entry_point);
    try std.testing.expectEqual(@as(u16, 3), h.image_size);
    try std.testing.expectEqual(@as(u8, 0), h.bank_count);
    try std.testing.expectEqual(@as(u8, 0), h.sram_bank_count);
    try std.testing.expectEqual(@as(u16, 0), h.heap_base);
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0xFF, 0xFF }, h.image);
    try std.testing.expectEqual(@as(usize, 0), h.banks.len);
    try std.testing.expectEqual(@as(usize, 0), h.debug.len);
}

test "header: heap_base parses from bytes 0x0E..0x0F (little-endian)" {
    var buf: [16]u8 = undefined;
    _ = buildGx(&buf, 0, 0x1100, 0, 0, 0);
    buf[0x0E] = 0x34;
    buf[0x0F] = 0x12;
    const h = try gero.disasm.parseHeader(&buf);
    try std.testing.expectEqual(@as(u16, 0x1234), h.heap_base);
}

test "header: bad magic rejected" {
    var buf: [16]u8 = .{ 'F', 'A', 'K', 'E', 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.BadMagic, gero.disasm.parseHeader(&buf));
}

test "header: future version rejected" {
    var buf: [16]u8 = undefined;
    _ = buildGx(&buf, 0, 0, 0, 0, 0);
    // Bump the major version to something past v1.
    buf[0x04] = 0x00;
    buf[0x05] = 0x02; // big-endian-looking but version is LE → major byte = 0x02
    try std.testing.expectError(error.UnsupportedVersion, gero.disasm.parseHeader(&buf));
}

test "header: file shorter than header rejected" {
    var buf: [10]u8 = .{ 'G', 'E', 'R', 'O', 0x01, 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.TooSmall, gero.disasm.parseHeader(&buf));
}

// ---------- debug symbols (#100) ----------

test "symbols: empty blob produces zero entries" {
    const out = try gero.disasm.parseSymbols(std.testing.allocator, &.{});
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), out.entries.len);
}

test "symbols: parse count + (addr, kind, name) entries" {
    // count=2, entry1: $0010 label "main", entry2: $0042 data "buf"
    const blob = [_]u8{
        0x02, 0x00, // count = 2
        0x10, 0x00, 0x00, 0x04, 'm', 'a', 'i', 'n', // addr / kind=label / len / name
        0x42, 0x00, 0x01, 0x03, 'b', 'u', 'f', // addr / kind=data / len / name
    };
    const out = try gero.disasm.parseSymbols(std.testing.allocator, &blob);
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), out.entries.len);
    try std.testing.expectEqual(@as(u16, 0x0010), out.entries[0].address);
    try std.testing.expectEqual(gero.disasm.SymbolKind.label, out.entries[0].kind);
    try std.testing.expectEqualStrings("main", out.entries[0].name);
    try std.testing.expectEqual(@as(u16, 0x0042), out.entries[1].address);
    try std.testing.expectEqual(gero.disasm.SymbolKind.data, out.entries[1].kind);
    try std.testing.expectEqualStrings("buf", out.entries[1].name);
}

test "symbols: lookup returns name on hit, null on miss" {
    const blob = [_]u8{
        0x01, 0x00,
        0x10, 0x00,
        0x00, 0x04,
        'm',  'a',
        'i',  'n',
    };
    const out = try gero.disasm.parseSymbols(std.testing.allocator, &blob);
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("main", out.lookup(0x0010).?);
    try std.testing.expect(out.lookup(0x0042) == null);
}

test "symbols: truncated count rejected" {
    const blob = [_]u8{0x02}; // only 1 of 2 bytes
    try std.testing.expectError(error.TruncatedSymbolSection, gero.disasm.parseSymbols(std.testing.allocator, &blob));
}

test "symbols: truncated name rejected" {
    // Declares 4 bytes of name but only has 2.
    const blob = [_]u8{ 0x01, 0x00, 0x10, 0x00, 0x00, 0x04, 'a', 'b' };
    try std.testing.expectError(error.TruncatedSymbolSection, gero.disasm.parseSymbols(std.testing.allocator, &blob));
}

test "header: banked cart exposes bank slice + isBanked flag" {
    const bank_size: usize = 0x4000;
    var buf: [16 + 1 + bank_size]u8 = undefined;
    _ = buildGx(buf[0..16], 0x0001, 0x0000, 1, 1, 0); // flag bit 0 = banked
    buf[16] = 0xFF; // single-byte base image
    @memset(buf[17..], 0);
    const h = try gero.disasm.parseHeader(&buf);
    try std.testing.expect(h.isBanked());
    try std.testing.expectEqual(bank_size, h.banks.len);
    try std.testing.expectEqual(@as(u8, 1), h.bank_count);
}
