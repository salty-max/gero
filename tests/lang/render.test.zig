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

test "render: pretty summary names warnings honestly when no errors" {
    const w = Diagnostic{
        .severity = .warning,
        .code = "W_DEBUG_ASSERT_SIDE_EFFECT",
        .message = "calls in debug_assert are elided in release",
        .span = .{ .start = 0, .end = 1 },
    };
    const file: FileDiagnostics = .{ .path = "x.gr", .source = "x = 1", .diagnostics = &.{w} };

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    try gero.lang.render.pretty(&writer.writer, &.{file}, gero.lang.render.Style.none);
    const out = try writer.toOwnedSlice();
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "1 warning in 1 file") != null);
    // Must NOT call a warning an error.
    try std.testing.expect(std.mem.indexOf(u8, out, "error in") == null);
}

// ---------- multi-span rendering (#254) ----------

test "render: same-line secondary draws `---` underline + stacked label" {
    // `let x: i16 = "hi"`
    //  0    5  8   13  17
    const source = "let x: i16 = \"hi\"";
    const d = Diagnostic{
        .severity = .fatal,
        .code = "E_TYPE_MISMATCH",
        .message = "type mismatch: expected `i16`, found `str`",
        .span = .{ .start = 13, .end = 17 },
        .secondary = &[_]gero.lang.SpanLabel{
            .{
                .span = .{ .start = 7, .end = 10 },
                .message = "expected `i16` because of this annotation",
            },
        },
    };
    const file: FileDiagnostics = .{ .path = "x.gr", .source = source, .diagnostics = &.{d} };
    const out = try renderPretty(file);
    defer alloc.free(out);

    // Primary carets + secondary dashes on the same line.
    try std.testing.expect(std.mem.indexOf(u8, out, "---") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "^^^^") != null);
    // Pointer (`|`) line then the label line stacked under it.
    // Order matters: pointer first, label second.
    const ptr_idx = std.mem.indexOf(u8, out, "|\n").?;
    const label_idx = std.mem.indexOf(u8, out, "expected `i16` because of this annotation").?;
    try std.testing.expect(label_idx > ptr_idx);
}

test "render: cross-line secondary emits its own `-->` excerpt block" {
    const source = "let foo: i16 = 1\nlet foo: i16 = 2";
    // Primary at the SECOND `foo` (offset 21..24), secondary at the FIRST (offset 4..7).
    const d = Diagnostic{
        .severity = .fatal,
        .code = "E_TYPE_REDEFINED",
        .message = "`foo` is already defined in this scope",
        .span = .{ .start = 21, .end = 24 },
        .secondary = &[_]gero.lang.SpanLabel{
            .{ .span = .{ .start = 4, .end = 7 }, .message = "previous definition here" },
        },
    };
    const file: FileDiagnostics = .{ .path = "x.gr", .source = source, .diagnostics = &.{d} };
    const out = try renderPretty(file);
    defer alloc.free(out);

    // Two `-->` blocks — one for the primary, one for the secondary.
    const first_arrow = std.mem.indexOf(u8, out, "-->").?;
    try std.testing.expect(std.mem.indexOf(u8, out[first_arrow + 1 ..], "-->") != null);
    // Inline label after the secondary's dashes.
    try std.testing.expect(std.mem.indexOf(u8, out, "previous definition here") != null);
}

test "render: empty `secondary` keeps the existing single-span layout" {
    const source = "let x: i16 = \"hi\"";
    const d = Diagnostic{
        .severity = .fatal,
        .code = "E_TYPE_MISMATCH",
        .message = "type mismatch",
        .span = .{ .start = 13, .end = 17 },
    };
    const file: FileDiagnostics = .{ .path = "x.gr", .source = source, .diagnostics = &.{d} };
    const out = try renderPretty(file);
    defer alloc.free(out);

    // No secondary → no underline, no second `-->`.
    try std.testing.expect(std.mem.indexOf(u8, out, "---") == null);
    var arrow_count: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOf(u8, out[search_from..], "-->")) |idx| {
        arrow_count += 1;
        search_from += idx + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), arrow_count);
}

test "render: pretty summary mixes `N errors + M warnings` when both present" {
    const err = Diagnostic{
        .severity = .fatal,
        .code = "E_TYPE_MISMATCH",
        .message = "boom",
        .span = .{ .start = 0, .end = 1 },
    };
    const w1 = Diagnostic{
        .severity = .warning,
        .code = "W_X",
        .message = "a",
        .span = .{ .start = 0, .end = 1 },
    };
    const w2 = Diagnostic{
        .severity = .warning,
        .code = "W_Y",
        .message = "b",
        .span = .{ .start = 0, .end = 1 },
    };
    const file: FileDiagnostics = .{ .path = "x.gr", .source = "x = 1", .diagnostics = &.{ err, w1, w2 } };

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();
    try gero.lang.render.pretty(&writer.writer, &.{file}, gero.lang.render.Style.none);
    const out = try writer.toOwnedSlice();
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "1 error + 2 warnings in 1 file") != null);
}
