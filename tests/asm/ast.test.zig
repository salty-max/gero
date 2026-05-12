const std = @import("std");
const gero = @import("gero");

// `Span` is the only public type the AST module currently exposes
// with non-trivial behavior (join / fromToken). Once Statement
// gains variants, those grow their own spec files.

test "ast.Span: fromToken copies file_id + offsets" {
    const t = gero.asm_.Token{
        .kind = .ident,
        .start = 4,
        .end = 9,
        .value = 0,
        .file_id = 7,
    };
    const s = gero.asm_.Span.fromToken(t);
    try std.testing.expectEqual(@as(u16, 7), s.file_id);
    try std.testing.expectEqual(@as(u32, 4), s.start);
    try std.testing.expectEqual(@as(u32, 9), s.end);
}

test "ast.Span: join takes min start, max end, keeps first file_id" {
    const a: gero.asm_.Span = .{ .file_id = 2, .start = 10, .end = 14 };
    const b: gero.asm_.Span = .{ .file_id = 2, .start = 20, .end = 25 };
    const j = gero.asm_.Span.join(a, b);
    try std.testing.expectEqual(@as(u16, 2), j.file_id);
    try std.testing.expectEqual(@as(u32, 10), j.start);
    try std.testing.expectEqual(@as(u32, 25), j.end);
}

test "ast.Span: join with overlapping ranges still picks the outer envelope" {
    const a: gero.asm_.Span = .{ .file_id = 0, .start = 5, .end = 12 };
    const b: gero.asm_.Span = .{ .file_id = 0, .start = 8, .end = 10 };
    const j = gero.asm_.Span.join(a, b);
    try std.testing.expectEqual(@as(u32, 5), j.start);
    try std.testing.expectEqual(@as(u32, 12), j.end);
}

test "ast.Span: join with reversed order normalizes" {
    const a: gero.asm_.Span = .{ .file_id = 1, .start = 20, .end = 25 };
    const b: gero.asm_.Span = .{ .file_id = 1, .start = 10, .end = 14 };
    const j = gero.asm_.Span.join(a, b);
    try std.testing.expectEqual(@as(u32, 10), j.start);
    try std.testing.expectEqual(@as(u32, 25), j.end);
}
