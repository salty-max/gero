const std = @import("std");
const gero = @import("gero");

test "ast.Span: fromToken copies offsets" {
    const t = gero.asm_.Token{
        .kind = .ident,
        .start = 4,
        .end = 9,
        .value = 0,
    };
    const s = gero.asm_.Span.fromToken(t);
    try std.testing.expectEqual(@as(u32, 4), s.start);
    try std.testing.expectEqual(@as(u32, 9), s.end);
}

test "ast.Span: join takes min start, max end" {
    const a: gero.asm_.Span = .{ .start = 10, .end = 14 };
    const b: gero.asm_.Span = .{ .start = 20, .end = 25 };
    const j = gero.asm_.Span.join(a, b);
    try std.testing.expectEqual(@as(u32, 10), j.start);
    try std.testing.expectEqual(@as(u32, 25), j.end);
}

test "ast.Span: join with overlapping ranges picks the outer envelope" {
    const a: gero.asm_.Span = .{ .start = 5, .end = 12 };
    const b: gero.asm_.Span = .{ .start = 8, .end = 10 };
    const j = gero.asm_.Span.join(a, b);
    try std.testing.expectEqual(@as(u32, 5), j.start);
    try std.testing.expectEqual(@as(u32, 12), j.end);
}

test "ast.Span: join is order-independent" {
    const a: gero.asm_.Span = .{ .start = 20, .end = 25 };
    const b: gero.asm_.Span = .{ .start = 10, .end = 14 };
    const j = gero.asm_.Span.join(a, b);
    try std.testing.expectEqual(@as(u32, 10), j.start);
    try std.testing.expectEqual(@as(u32, 25), j.end);
}
