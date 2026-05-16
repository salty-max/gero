const std = @import("std");
const gero = @import("gero");

const ast = gero.lang.ast;
const alloc = std.testing.allocator;

// The AST module's own tests are minimal — most coverage comes via
// `parser.test.zig`, which exercises every node type through real
// parses. These specs pin the lightweight invariants of `Span` and
// the discriminated-union `span()` accessors that don't need a
// running parser to verify.

test "ast.Span: join merges two spans by min-start / max-end" {
    const a: ast.Span = .{ .start = 5, .end = 10 };
    const b: ast.Span = .{ .start = 8, .end = 20 };
    const j = ast.Span.join(a, b);
    try std.testing.expectEqual(@as(u32, 5), j.start);
    try std.testing.expectEqual(@as(u32, 20), j.end);
}

test "ast.Span: join is commutative" {
    const a: ast.Span = .{ .start = 3, .end = 7 };
    const b: ast.Span = .{ .start = 1, .end = 4 };
    const ab = ast.Span.join(a, b);
    const ba = ast.Span.join(b, a);
    try std.testing.expectEqual(ab.start, ba.start);
    try std.testing.expectEqual(ab.end, ba.end);
}

test "ast: Expr.span() returns the variant's span field" {
    const e: ast.Expr = .{ .int_lit = .{
        .value = 42,
        .span = .{ .start = 10, .end = 12 },
    } };
    const s = e.span();
    try std.testing.expectEqual(@as(u32, 10), s.start);
    try std.testing.expectEqual(@as(u32, 12), s.end);
}

test "ast: Statement.span() returns the variant's span field" {
    const s: ast.Statement = .{ .break_stmt = .{
        .label = null,
        .span = .{ .start = 3, .end = 8 },
    } };
    const sp = s.span();
    try std.testing.expectEqual(@as(u32, 3), sp.start);
    try std.testing.expectEqual(@as(u32, 8), sp.end);
}

test "ast: Pattern.span() returns the variant's span field" {
    const p: ast.Pattern = .{ .wildcard = .{
        .span = .{ .start = 7, .end = 8 },
    } };
    const sp = p.span();
    try std.testing.expectEqual(@as(u32, 7), sp.start);
    try std.testing.expectEqual(@as(u32, 8), sp.end);
}

test "ast: TypeAnn.span() returns the variant's span field" {
    const t: ast.TypeAnn = .{ .named = .{
        .name = .{ .start = 0, .end = 3 },
        .span = .{ .start = 0, .end = 3 },
    } };
    const sp = t.span();
    try std.testing.expectEqual(@as(u32, 0), sp.start);
    try std.testing.expectEqual(@as(u32, 3), sp.end);
}

test "ast: empty Program.deinit is a no-op safe path" {
    var prog: ast.Program = .{
        .statements = &.{},
        .allocator = alloc,
    };
    prog.deinit();
}
