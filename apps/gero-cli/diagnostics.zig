/// Shared diagnostic-printing helpers for the CLI subcommands.
/// Both `gero asm` and `gero check` produce the same per-file
/// grouped output with caret snippets — this module owns that
/// rendering so the surface stays in one place.
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
        for (f.parse_errors, 0..) |d, i| keyed[i] = .{ .diag = d, .path = pathOf(f.source_map, d) };
        for (f.codegen_errors, 0..) |d, j| keyed[f.parse_errors.len + j] = .{ .diag = d, .path = pathOf(f.source_map, d) };
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

/// Look up the file path the diagnostic points into. Falls back
/// to `<unknown>` when the source-map miss (shouldn't normally
/// happen in practice).
pub fn pathOf(source_map: gero.asm_.SourceMap, d: gero.asm_.Diagnostic) []const u8 {
    // @as: ParseError indexes fit in u32 — bounded by max_file_size (16 MiB) per include.zig.
    const offset: u32 = @as(u32, @intCast(d.parse_error.index));
    if (source_map.lookup(offset)) |loc| return loc.file.path;
    return "<unknown>";
}

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
