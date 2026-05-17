const std = @import("std");
const gero = @import("gero");
const archive = gero.lang.codegen.archive;

test "archive: alignUpU16 rounds to the next power-of-two multiple" {
    try std.testing.expectEqual(@as(u16, 0), archive.alignUpU16(0, 16));
    try std.testing.expectEqual(@as(u16, 16), archive.alignUpU16(1, 16));
    try std.testing.expectEqual(@as(u16, 16), archive.alignUpU16(15, 16));
    try std.testing.expectEqual(@as(u16, 16), archive.alignUpU16(16, 16));
    try std.testing.expectEqual(@as(u16, 32), archive.alignUpU16(17, 16));
}

test "archive: alignUpU16 with align <= 1 is a no-op" {
    try std.testing.expectEqual(@as(u16, 7), archive.alignUpU16(7, 0));
    try std.testing.expectEqual(@as(u16, 7), archive.alignUpU16(7, 1));
}

test "archive: writeU16Le encodes the low byte first" {
    var buf: [2]u8 = .{ 0, 0 };
    archive.writeU16Le(&buf, 0x1234);
    try std.testing.expectEqual(@as(u8, 0x34), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x12), buf[1]);
}

test "archive: banksEqual handles both null + matching index" {
    try std.testing.expect(archive.banksEqual(null, null));
    try std.testing.expect(archive.banksEqual(3, 3));
    try std.testing.expect(!archive.banksEqual(null, 0));
    try std.testing.expect(!archive.banksEqual(0, 1));
}

test "archive: decodeStringEscapes resolves the standard set" {
    const alloc = std.testing.allocator;
    const decoded = try archive.decodeStringEscapes(alloc, "a\\tb\\nc");
    defer alloc.free(decoded);
    try std.testing.expectEqualStrings("a\tb\nc", decoded);
}
