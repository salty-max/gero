/// Tests for `gero.lang.render` — the diagnostic-rendering layer.
const std = @import("std");
const gero = @import("gero");

const Diagnostic = gero.lang.Diagnostic;
const FileDiagnostics = gero.lang.render.FileDiagnostics;
const alloc = std.testing.allocator;

fn renderPretty(file: FileDiagnostics) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    try gero.lang.render.prettyOne(&writer.writer, file, gero.lang.render.Style.none);
    return writer.toOwnedSlice();
}

fn renderJson(files: []const FileDiagnostics) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    try gero.lang.render.json(&writer.writer, files);
    return writer.toOwnedSlice();
}

test "render: lineColAt computes 1-based (line, col)" {
    const src = "abc\ndef\nghi";
    try std.testing.expectEqual(@as(usize, 1), gero.lang.render.lineColAt(src, 0).line);
    try std.testing.expectEqual(@as(usize, 1), gero.lang.render.lineColAt(src, 0).col);
    try std.testing.expectEqual(@as(usize, 2), gero.lang.render.lineColAt(src, 5).line);
    try std.testing.expectEqual(@as(usize, 2), gero.lang.render.lineColAt(src, 5).col);
}

test "render: lineAt slices the line containing the offset" {
    const src = "first\nsecond\nthird";
    try std.testing.expectEqualStrings("first", gero.lang.render.lineAt(src, 2));
    try std.testing.expectEqualStrings("second", gero.lang.render.lineAt(src, 7));
    try std.testing.expectEqualStrings("third", gero.lang.render.lineAt(src, 14));
}

test "render: pretty single diagnostic emits header + excerpt + caret" {
    const source = "let x: i16 = \"hi\"";
    const d = Diagnostic{
        .severity = .fatal,
        .code = "E_TYPE_MISMATCH",
        .message = "type mismatch: expected `i16`, found `str`",
        .span = .{ .start = 13, .end = 17 },
    };
    const file: FileDiagnostics = .{
        .path = "src/foo.gr",
        .source = source,
        .diagnostics = &.{d},
    };
    const out = try renderPretty(file);
    defer alloc.free(out);
    // Header carries severity, message, code.
    try std.testing.expect(std.mem.indexOf(u8, out, "error:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[E_TYPE_MISMATCH]") != null);
    // Location header.
    try std.testing.expect(std.mem.indexOf(u8, out, "--> src/foo.gr:1:14") != null);
    // Excerpt + caret line.
    try std.testing.expect(std.mem.indexOf(u8, out, "let x: i16 = \"hi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "^^^^") != null);
}

test "render: pretty includes help block when provided" {
    const source = "let x: i16 = 0";
    const d = Diagnostic{
        .severity = .fatal,
        .code = "E_TYPE_MISMATCH",
        .message = "type mismatch",
        .span = .{ .start = 13, .end = 14 },
        .help = "use `let x: u8 = 0` instead",
    };
    const file: FileDiagnostics = .{
        .path = "foo.gr",
        .source = source,
        .diagnostics = &.{d},
    };
    const out = try renderPretty(file);
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "help: use `let x: u8 = 0` instead") != null);
}

test "render: json emits one object per diagnostic" {
    const source = "let x: i16 = \"hi\"";
    const d = Diagnostic{
        .severity = .fatal,
        .code = "E_TYPE_MISMATCH",
        .message = "type mismatch",
        .span = .{ .start = 13, .end = 17 },
    };
    const file: FileDiagnostics = .{
        .path = "src/foo.gr",
        .source = source,
        .diagnostics = &.{d},
    };
    const out = try renderJson(&.{file});
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"path\":\"src/foo.gr\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"code\":\"E_TYPE_MISMATCH\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"line\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"col\":14") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"severity\":\"error\"") != null);
}

test "render: severity warning emits `warning:` prefix" {
    const d = Diagnostic{
        .severity = .warning,
        .code = "E_CAST_PRECISION_LOSS",
        .message = "narrowing without explicit cast",
        .span = .{ .start = 0, .end = 1 },
    };
    const file: FileDiagnostics = .{
        .path = "x.gr",
        .source = "x = 1",
        .diagnostics = &.{d},
    };
    const out = try renderPretty(file);
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "warning:") != null);
}

test "render: empty diagnostics list emits nothing" {
    const file: FileDiagnostics = .{
        .path = "x.gr",
        .source = "",
        .diagnostics = &.{},
    };
    const out = try renderPretty(file);
    defer alloc.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "render: pretty multi-file emits summary header + per-file sections" {
    const d1 = Diagnostic{
        .severity = .fatal,
        .code = "E_TYPE_MISMATCH",
        .message = "boom",
        .span = .{ .start = 0, .end = 1 },
    };
    const d2 = Diagnostic{
        .severity = .fatal,
        .code = "E_UNDEFINED_SYMBOL",
        .message = "missing",
        .span = .{ .start = 0, .end = 1 },
    };
    const file_a: FileDiagnostics = .{ .path = "a.gr", .source = "x", .diagnostics = &.{d1} };
    const file_b: FileDiagnostics = .{ .path = "b.gr", .source = "y", .diagnostics = &.{d2} };

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    try gero.lang.render.pretty(&writer.writer, &.{ file_a, file_b }, gero.lang.render.Style.none);
    const out = try writer.toOwnedSlice();
    defer alloc.free(out);

    // Summary header.
    try std.testing.expect(std.mem.indexOf(u8, out, "2 errors in 2 files") != null);
    // Both per-file sections present.
    try std.testing.expect(std.mem.indexOf(u8, out, "a.gr") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "b.gr") != null);
    // Diagnostic for each.
    try std.testing.expect(std.mem.indexOf(u8, out, "boom") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "missing") != null);
}

test "render: pretty skips files with zero diagnostics in multi-file mode" {
    const d = Diagnostic{
        .severity = .fatal,
        .code = "E_TYPE_MISMATCH",
        .message = "boom",
        .span = .{ .start = 0, .end = 1 },
    };
    const failing: FileDiagnostics = .{ .path = "fail.gr", .source = "x", .diagnostics = &.{d} };
    const clean: FileDiagnostics = .{ .path = "clean.gr", .source = "y", .diagnostics = &.{} };

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    try gero.lang.render.pretty(&writer.writer, &.{ failing, clean }, gero.lang.render.Style.none);
    const out = try writer.toOwnedSlice();
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "1 error in 1 file") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "fail.gr") != null);
    // Clean file must not appear in the report.
    try std.testing.expect(std.mem.indexOf(u8, out, "clean.gr") == null);
}
