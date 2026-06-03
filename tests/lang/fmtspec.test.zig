/// Unit tests for the compile-time format-spec parser (§3.2.2).
const std = @import("std");
const gero = @import("gero");

const fmtspec = gero.lang.internal.fmtspec;

test "fmtspec: hex-upper with zero-pad and width (`04X`)" {
    const s = try fmtspec.parse("04X");
    try std.testing.expect(s.zero_pad);
    try std.testing.expectEqual(@as(u8, 4), s.width);
    try std.testing.expectEqual(fmtspec.Type.hex_upper, s.ty);
}

test "fmtspec: alignment + width + type (`>3d`)" {
    const s = try fmtspec.parse(">3d");
    try std.testing.expectEqual(fmtspec.Align.right, s.alignment);
    try std.testing.expectEqual(@as(u8, 3), s.width);
    try std.testing.expectEqual(fmtspec.Type.dec, s.ty);
    try std.testing.expect(!s.zero_pad);
}

test "fmtspec: explicit fill before alignment (`*^6s`)" {
    const s = try fmtspec.parse("*^6s");
    try std.testing.expectEqual(@as(u8, '*'), s.fill);
    try std.testing.expectEqual(fmtspec.Align.center, s.alignment);
    try std.testing.expectEqual(@as(u8, 6), s.width);
    try std.testing.expectEqual(fmtspec.Type.str, s.ty);
}

test "fmtspec: precision (`10.3s`)" {
    const s = try fmtspec.parse("10.3s");
    try std.testing.expectEqual(@as(u8, 10), s.width);
    try std.testing.expectEqual(@as(?u8, 3), s.precision);
    try std.testing.expectEqual(fmtspec.Type.str, s.ty);
}

test "fmtspec: bare type-less width defaults the type (`5`)" {
    const s = try fmtspec.parse("5");
    try std.testing.expectEqual(@as(u8, 5), s.width);
    try std.testing.expectEqual(fmtspec.Type.default, s.ty);
}

test "fmtspec: trailing garbage is Malformed" {
    try std.testing.expectError(error.Malformed, fmtspec.parse("3dx"));
}

test "fmtspec: unknown type letter is Malformed" {
    try std.testing.expectError(error.Malformed, fmtspec.parse("zzz"));
}

test "fmtspec: out-of-range width is Malformed" {
    try std.testing.expectError(error.Malformed, fmtspec.parse("999d"));
}
