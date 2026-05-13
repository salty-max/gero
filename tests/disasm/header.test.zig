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
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0xFF, 0xFF }, h.image);
    try std.testing.expectEqual(@as(usize, 0), h.banks.len);
    try std.testing.expectEqual(@as(usize, 0), h.debug.len);
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
