const std = @import("std");
const gero = @import("gero");

/// Pretty-print a single list of diagnostics (e.g., include-phase
/// errors) against a fused-source map. No header, no grouping —
/// each diagnostic renders with its own caret snippet via
/// `gero.asm_.formatPretty`.
pub fn printSingle(
    stdout: *std.Io.Writer,
    source_map: gero.asm_.SourceMap,
    errors: []const gero.asm_.Diagnostic,
    style: gero.asm_.Style,
) std.Io.Writer.Error!void {
    for (errors) |d| try gero.asm_.formatPretty(stdout, source_map, d, style);
}

/// Augment each diagnostic with its resolved file path so the
/// merged printer can group + sort by `(path, fused_index)`.
pub const Keyed = struct {
    diag: gero.asm_.Diagnostic,
    path: []const u8,
};

/// One failed file's worth of diagnostic context — a path + the
/// `SourceMap` the parser produced + the parse/codegen error
/// slices. Owned by the caller's arena.
pub const FileFailure = struct {
    source_map: gero.asm_.SourceMap,
    parse_errors: []const gero.asm_.Diagnostic,
    codegen_errors: []const gero.asm_.Diagnostic,
};

/// Render every diagnostic across one or more failed files under
/// **a single** Cargo-style summary header. Each file's parse +
/// codegen errors are merged, grouped by the path the source-map
/// resolves them to (handles included-file diagnostics), and
/// sorted within each group by fused-source offset.
///
/// ```text
/// 3 errors in 2 files
///
/// foo.gas
///   <caret-style body for each diagnostic>
///
/// bar.gas
///   <caret-style body for each diagnostic>
/// ```
///
/// Use a one-element `failures` slice for the single-file case —
/// the header still emits cleanly.
pub fn printAllFailures(
    arena: std.mem.Allocator,
    stdout: *std.Io.Writer,
    style: gero.asm_.Style,
    failures: []const FileFailure,
) !void {
    var total: usize = 0;
    for (failures) |f| total += f.parse_errors.len + f.codegen_errors.len;
    try writeSummaryHeader(stdout, style, total, failures.len);

    for (failures) |f| {
        const local = f.parse_errors.len + f.codegen_errors.len;
        const keyed = try arena.alloc(Keyed, local);
        for (f.parse_errors, 0..) |d, i| keyed[i] = .{ .diag = d, .path = gero.diagnostics_json.pathOf(f.source_map, d) };
        for (f.codegen_errors, 0..) |d, j| keyed[f.parse_errors.len + j] = .{ .diag = d, .path = gero.diagnostics_json.pathOf(f.source_map, d) };
        std.mem.sort(Keyed, keyed, {}, byPathThenIndex);

        var prev_path: []const u8 = "";
        for (keyed) |k| {
            if (!std.mem.eql(u8, k.path, prev_path)) {
                try stdout.writeByte('\n');
                try stdout.print("{s}{s}{s}\n", .{ style.location, k.path, style.reset });
                prev_path = k.path;
            }
            try gero.asm_.formatPrettyBody(stdout, f.source_map, k.diag, style);
        }
    }
}

/// `<N> error(s) in <M> file(s)` summary printed above the per-
/// file sections.
pub fn writeSummaryHeader(
    stdout: *std.Io.Writer,
    style: gero.asm_.Style,
    errors: usize,
    files: usize,
) std.Io.Writer.Error!void {
    const error_noun: []const u8 = if (errors == 1) "error" else "errors";
    const file_noun: []const u8 = if (files == 1) "file" else "files";
    try stdout.print("{s}{d} {s}{s} in {d} {s}\n", .{ style.code, errors, error_noun, style.reset, files, file_noun });
}

/// Resolved diagnostic location used by the JSON renderer + any
/// future structured-output consumer.
pub const Location = struct {
    path: []const u8,
    line: usize,
    column: usize,
};

/// Emit a single JSON object summarizing the run — stable contract
/// for editor integration (`gero check --format=json`). Schema:
///
/// ```json
/// {
///   "version": 1,
///   "diagnostics": [
///     {
///       "file": "<path>",
///       "line": <1-based>,
///       "column": <1-based>,
///       "severity": "error",
///       "code": "E004",          // omitted when the diagnostic has no E-code
///       "message": "<text>",
///       "note": "<hint>"          // omitted when absent
///     }
///   ],
///   "files_checked": <N>,
///   "files_failed": <M>
/// }
/// ```
///
/// Stdout is reserved for this object — no human-readable output is
/// emitted in JSON mode. Stderr stays free for host I/O failures.
pub fn printJsonReport(
    stdout: *std.Io.Writer,
    failures: []const FileFailure,
    lang_files: []const gero.lang.render.FileDiagnostics,
    read_errors: []const ReadErrorEntry,
    files_checked: usize,
    files_failed: usize,
) !void {
    var jw = std.json.Stringify{ .writer = stdout, .options = .{ .whitespace = .minified } };
    try jw.beginObject();

    try jw.objectField("version");
    try jw.write(@as(u32, 1));

    try jw.objectField("diagnostics");
    try jw.beginArray();
    for (failures) |f| {
        for (f.parse_errors) |d| try gero.diagnostics_json.writeAsm(&jw, f.source_map, d);
        for (f.codegen_errors) |d| try gero.diagnostics_json.writeAsm(&jw, f.source_map, d);
    }
    // `.gr` diagnostics share the array rather than trailing the object
    // as separate lines: `--format=json` is one object so an editor can
    // `JSON.parse(stdout)` whichever front-end produced the report.
    for (lang_files) |f| {
        for (f.diagnostics) |d| try gero.diagnostics_json.writeLang(&jw, f, d);
    }
    for (read_errors) |re| {
        try jw.beginObject();
        try jw.objectField("file");
        try jw.write(re.path);
        try jw.objectField("line");
        try jw.write(@as(u32, 1));
        try jw.objectField("column");
        try jw.write(@as(u32, 1));
        try jw.objectField("severity");
        try jw.write("error");
        try jw.objectField("message");
        try jw.write(re.message);
        try jw.endObject();
    }
    try jw.endArray();

    try jw.objectField("files_checked");
    try jw.write(files_checked);
    try jw.objectField("files_failed");
    try jw.write(files_failed);

    try jw.endObject();
    try stdout.writeByte('\n');
}

/// A file that couldn't be read at all (host-IO failure). Carries
/// the synthetic message the JSON renderer emits in place of a
/// pipeline diagnostic.
pub const ReadErrorEntry = struct {
    path: []const u8,
    message: []const u8,
};

/// Sort comparator: by path lex order, then by fused-source
/// offset within the same path. Used by `printMerged`.
pub fn byPathThenIndex(_: void, a: Keyed, b: Keyed) bool {
    const path_cmp = std.mem.order(u8, a.path, b.path);
    if (path_cmp != .eq) return path_cmp == .lt;
    return a.diag.parse_error.index < b.diag.parse_error.index;
}

// ---------- tests ----------

const testing = std.testing;

test "diagnostics: byPathThenIndex sorts by path lex order" {
    const a: Keyed = .{ .diag = mkDiag(0), .path = "a.gas" };
    const b: Keyed = .{ .diag = mkDiag(0), .path = "b.gas" };
    try testing.expect(byPathThenIndex({}, a, b));
    try testing.expect(!byPathThenIndex({}, b, a));
}

test "diagnostics: byPathThenIndex breaks ties on parse_error.index" {
    const a: Keyed = .{ .diag = mkDiag(5), .path = "same.gas" };
    const b: Keyed = .{ .diag = mkDiag(10), .path = "same.gas" };
    try testing.expect(byPathThenIndex({}, a, b));
    try testing.expect(!byPathThenIndex({}, b, a));
}

test "diagnostics: lineColIn 1-indexes lines and columns" {
    const content = "abc\ndef\nghi";
    const r1 = gero.diagnostics_json.lineColIn(content, 0);
    try testing.expectEqual(@as(usize, 1), r1.line);
    try testing.expectEqual(@as(usize, 1), r1.col);

    const r2 = gero.diagnostics_json.lineColIn(content, 4); // first char of "def"
    try testing.expectEqual(@as(usize, 2), r2.line);
    try testing.expectEqual(@as(usize, 1), r2.col);

    const r3 = gero.diagnostics_json.lineColIn(content, 10); // 'i' in "ghi"
    try testing.expectEqual(@as(usize, 3), r3.line);
    try testing.expectEqual(@as(usize, 3), r3.col);
}

test "diagnostics: printJsonReport — empty run" {
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    try printJsonReport(&out.writer, &.{}, &.{}, &.{}, 3, 0);
    try testing.expectEqualStrings(
        "{\"version\":1,\"diagnostics\":[],\"files_checked\":3,\"files_failed\":0}\n",
        out.written(),
    );
}

test "diagnostics: printJsonReport — read-error-only run" {
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    const errs = [_]ReadErrorEntry{.{ .path = "missing.gas", .message = "cannot read (FileNotFound)" }};
    try printJsonReport(&out.writer, &.{}, &.{}, &errs, 1, 1);
    const expected =
        "{\"version\":1,\"diagnostics\":[{\"file\":\"missing.gas\",\"line\":1,\"column\":1,\"severity\":\"error\"," ++
        "\"message\":\"cannot read (FileNotFound)\"}],\"files_checked\":1,\"files_failed\":1}\n";
    try testing.expectEqualStrings(expected, out.written());
}

test "diagnostics: writeDiagnosticJson — code + note both serialized when present" {
    // Build a synthetic SourceMap covering one file so locationOf
    // resolves cleanly.
    var sm: gero.asm_.SourceMap = .{
        .files = .empty,
        .regions = .empty,
        .allocator = testing.allocator,
    };
    defer sm.deinit();
    const path = try testing.allocator.dupeZ(u8, "foo.gas");
    const content = try testing.allocator.dupe(u8, "mov $00, r1\n");
    try sm.files.append(testing.allocator, .{ .path = path, .content = content });
    try sm.regions.append(testing.allocator, .{
        .fused_start = 0,
        .fused_end = @as(u32, @intCast(content.len)),
        .file_id = 0,
        .file_offset = 0,
    });

    const d: gero.asm_.Diagnostic = .{
        .code = .duplicate_label,
        .note = "did you mean `bar`?",
        .parse_error = .{
            .parser = "test",
            .index = 4, // points at `$`
            .message = "undefined symbol",
            .expected = "",
            .actual = "",
            .kind = .semantic,
        },
    };

    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try jw.beginArray();
    try gero.diagnostics_json.writeAsm(&jw, sm, d);
    try jw.endArray();

    const expected =
        "[{\"file\":\"foo.gas\",\"line\":1,\"column\":5,\"severity\":\"error\"," ++
        "\"code\":\"E005\",\"message\":\"undefined symbol\",\"note\":\"did you mean `bar`?\"}]";
    try testing.expectEqualStrings(expected, out.written());
}

fn mkDiag(index: u32) gero.asm_.Diagnostic {
    return .{
        .code = .duplicate_label,
        .parse_error = .{
            .parser = "test",
            .index = index,
            .message = "synthetic",
            .expected = "",
            .actual = "",
            .kind = .semantic,
        },
    };
}

test "printJsonReport: a Gero diagnostic lands in the object's array" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var out = std.Io.Writer.Allocating.fromArrayList(std.testing.allocator, &buf);
    defer out.deinit();

    const source = "let x: i16 = \"hi\"";
    const file: gero.lang.render.FileDiagnostics = .{
        .path = "src/foo.gr",
        .source = source,
        .diagnostics = &.{.{
            .severity = .fatal,
            .code = "E_TYPE_MISMATCH",
            .message = "type mismatch",
            .span = .{ .start = 13, .end = 17 },
        }},
    };
    try printJsonReport(&out.writer, &.{}, &.{file}, &.{}, 1, 1);
    const text = out.writer.buffered();

    // `--format=json` is one object whatever front-end produced the
    // report, so an editor can parse stdout in one step (cli.md §3.9).
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "{\"version\":1"));
    try std.testing.expect(std.mem.indexOf(u8, text, "\"file\":\"src/foo.gr\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"column\":14") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"end_col\":18") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"code\":\"E_TYPE_MISMATCH\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"diagnostics\":[]") == null);
}
