/// Render gero-lang diagnostics in the format documented by
/// `docs/lang-diagnostics.md`.
///
/// Two surfaces:
///   - `pretty(...)` — Cargo-style human output (default for
///     `gero check`).
///   - `json(...)` — line-delimited JSON, one diagnostic per
///     line, for editor / CI consumers (the LSP wire schema).
///
/// Both consume `Diagnostic` slices plus the underlying source
/// buffer (needed for line-extraction and column math) plus the
/// file path (for the `--> path:line:col` header).
const std = @import("std");
const ast = @import("ast.zig");
const diag_mod = @import("diagnostic.zig");

const Diagnostic = diag_mod.Diagnostic;
const Severity = diag_mod.Severity;

/// ANSI escape codes for colorized output. `Style.none` strips
/// all escapes for plain-text mode (no tty, `--no-color`, JSON).
pub const Style = struct {
    severity_error: []const u8 = "",
    severity_warning: []const u8 = "",
    severity_note: []const u8 = "",
    code: []const u8 = "",
    location: []const u8 = "",
    gutter: []const u8 = "",
    caret: []const u8 = "",
    help: []const u8 = "",
    reset: []const u8 = "",

    /// Plain-text style — every field is empty so no ANSI escapes
    /// leak into non-tty output (CI logs, file redirects, JSON).
    pub const none: Style = .{};

    /// Cargo-style ANSI 16-color style — bold for severity / code,
    /// cyan for paths / location, red for carets, green for help.
    pub const ansi: Style = .{
        .severity_error = "\x1b[31;1m",
        .severity_warning = "\x1b[33;1m",
        .severity_note = "\x1b[36;1m",
        .code = "\x1b[1m",
        .location = "\x1b[36m",
        .gutter = "\x1b[34m",
        .caret = "\x1b[31;1m",
        .help = "\x1b[32;1m",
        .reset = "\x1b[0m",
    };
};

/// One file's worth of diagnostics, paired with the source buffer
/// they index into and the path the renderer prints in `--> ...`.
pub const FileDiagnostics = struct {
    path: []const u8,
    source: []const u8,
    diagnostics: []const Diagnostic,
};

/// Render every diagnostic across one or more files under a
/// single Cargo-style summary header, grouped per file.
///
/// ```text
/// 3 errors in 2 files
///
/// src/foo.gr
///   error[E_TYPE_MISMATCH]: ...
///   ...
///
/// src/bar.gr
///   ...
/// ```
pub fn pretty(
    writer: *std.Io.Writer,
    files: []const FileDiagnostics,
    style: Style,
) !void {
    var total: usize = 0;
    var files_with_errors: usize = 0;
    for (files) |f| {
        if (f.diagnostics.len > 0) {
            total += f.diagnostics.len;
            files_with_errors += 1;
        }
    }
    if (total == 0) return;
    try writeSummaryHeader(writer, style, total, files_with_errors);

    for (files) |f| {
        if (f.diagnostics.len == 0) continue;
        try writer.writeByte('\n');
        try writer.print("{s}{s}{s}\n", .{ style.location, f.path, style.reset });
        for (f.diagnostics) |d| try writeDiagnosticBody(writer, f.path, f.source, d, style);
    }
}

/// Same as `pretty` but for a single file — skips the per-file
/// header and just writes the diagnostics in order. Useful when
/// the caller is rendering one source at a time.
pub fn prettyOne(
    writer: *std.Io.Writer,
    file: FileDiagnostics,
    style: Style,
) !void {
    for (file.diagnostics) |d| try writeDiagnosticFull(writer, file.path, file.source, d, style);
}

/// Render diagnostics as one JSON object per line — `ndjson`
/// shape, easy to parse from editors / CI scripts.
///
/// Schema per line:
/// ```
/// { "path": "...", "line": 12, "col": 18, "end_line": 12,
///   "end_col": 25, "severity": "error", "code": "E_TYPE_MISMATCH",
///   "message": "...", "help": "..." }
/// ```
pub fn json(
    writer: *std.Io.Writer,
    files: []const FileDiagnostics,
) !void {
    for (files) |f| {
        for (f.diagnostics) |d| {
            const start_lc = lineColAt(f.source, d.span.start);
            const end_lc = lineColAt(f.source, d.span.end);
            try writer.writeAll("{\"path\":");
            try writeJsonString(writer, f.path);
            try writer.print(",\"line\":{d},\"col\":{d},\"end_line\":{d},\"end_col\":{d}", .{ start_lc.line, start_lc.col, end_lc.line, end_lc.col });
            try writer.writeAll(",\"severity\":\"");
            try writer.writeAll(severityName(d.severity));
            try writer.writeAll("\",\"code\":");
            try writeJsonString(writer, d.code);
            try writer.writeAll(",\"message\":");
            try writeJsonString(writer, d.message);
            if (d.help) |h| {
                try writer.writeAll(",\"help\":");
                try writeJsonString(writer, h);
            }
            try writer.writeAll("}\n");
        }
    }
}

// ---------- one diagnostic ----------

fn writeDiagnosticFull(
    writer: *std.Io.Writer,
    path: []const u8,
    source: []const u8,
    d: Diagnostic,
    style: Style,
) !void {
    const lc = lineColAt(source, d.span.start);
    try writeHeader(writer, d, style);
    try writer.print("  {s}-->{s} {s}{s}:{d}:{d}{s}\n", .{
        style.location, style.reset,
        style.location, path,
        lc.line,        lc.col,
        style.reset,
    });
    try writeExcerpt(writer, source, d.span, lc, style);
    if (d.help) |h| try writeHelp(writer, h, style);
    try writer.writeByte('\n');
}

fn writeDiagnosticBody(
    writer: *std.Io.Writer,
    path: []const u8,
    source: []const u8,
    d: Diagnostic,
    style: Style,
) !void {
    const lc = lineColAt(source, d.span.start);
    try writer.writeAll("  ");
    try writeHeader(writer, d, style);
    try writer.print("    {s}-->{s} {s}{s}:{d}:{d}{s}\n", .{
        style.location, style.reset,
        style.location, path,
        lc.line,        lc.col,
        style.reset,
    });
    try writeExcerpt(writer, source, d.span, lc, style);
    if (d.help) |h| try writeHelp(writer, h, style);
    try writer.writeByte('\n');
}

fn writeHeader(writer: *std.Io.Writer, d: Diagnostic, style: Style) !void {
    const sev_color: []const u8 = switch (d.severity) {
        .fatal => style.severity_error,
        .warning => style.severity_warning,
        .note => style.severity_note,
    };
    try writer.print("{s}{s}{s}: {s} {s}[{s}]{s}\n", .{
        sev_color,   severityLabel(d.severity), style.reset,
        d.message,   style.code,                d.code,
        style.reset,
    });
}

fn writeExcerpt(
    writer: *std.Io.Writer,
    source: []const u8,
    span: ast.Span,
    lc: LineCol,
    style: Style,
) !void {
    const line_slice = lineAt(source, span.start);
    const gutter_w: usize = digitsOf(lc.line);
    // Empty gutter line for breathing room.
    try writePadGutter(writer, gutter_w, style);
    try writer.writeAll(" |\n");
    // Source line with right-padded line-number gutter.
    try writer.writeAll(style.gutter);
    try writeRightPadInt(writer, lc.line, gutter_w);
    try writer.print(" |{s} {s}\n", .{ style.reset, line_slice });
    // Caret line — pad + carets + maybe a trailing label later.
    try writePadGutter(writer, gutter_w, style);
    try writer.writeAll(" | ");
    // Pad with spaces up to the caret column.
    var i: usize = 1;
    while (i < lc.col) : (i += 1) try writer.writeByte(' ');
    try writer.writeAll(style.caret);
    const caret_len = caretLength(source, span);
    var c: usize = 0;
    while (c < caret_len) : (c += 1) try writer.writeByte('^');
    try writer.writeAll(style.reset);
    try writer.writeByte('\n');
}

fn writeHelp(writer: *std.Io.Writer, help_msg: []const u8, style: Style) !void {
    try writer.print("{s}help:{s} {s}\n", .{ style.help, style.reset, help_msg });
}

fn writePadGutter(writer: *std.Io.Writer, gutter_w: usize, style: Style) !void {
    try writer.writeAll(style.gutter);
    var i: usize = 0;
    while (i < gutter_w) : (i += 1) try writer.writeByte(' ');
    try writer.writeAll(style.reset);
}

/// Write `n` right-padded to `width` ASCII digits (left-padded
/// with spaces). Zig's runtime format helpers want a comptime
/// width spec; for a dynamic gutter width we compute by hand.
fn writeRightPadInt(writer: *std.Io.Writer, n: usize, width: usize) !void {
    const d = digitsOf(n);
    var pad: usize = if (width > d) width - d else 0;
    while (pad > 0) : (pad -= 1) try writer.writeByte(' ');
    try writer.print("{d}", .{n});
}

fn writeSummaryHeader(writer: *std.Io.Writer, style: Style, total: usize, files: usize) !void {
    const err_noun: []const u8 = if (total == 1) "error" else "errors";
    const file_noun: []const u8 = if (files == 1) "file" else "files";
    try writer.print("{s}{d} {s}{s} in {d} {s}\n", .{
        style.code, total, err_noun, style.reset, files, file_noun,
    });
}

// ---------- (line, col) + line slice + caret math ----------

/// 1-based `(line, column)` pair, computed from a byte offset
/// inside a source buffer by `lineColAt`.
pub const LineCol = struct {
    line: usize,
    col: usize,
};

/// Compute a 1-based `(line, col)` for `byte` inside `source` by
/// walking the buffer. O(n) — fine for diagnostic rendering where
/// `n` ≤ a single source file.
pub fn lineColAt(source: []const u8, byte: u32) LineCol {
    var line: usize = 1;
    var col: usize = 1;
    var i: usize = 0;
    while (i < source.len and i < byte) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .col = col };
}

/// Slice the line of source that contains `byte`, without
/// the trailing newline. Out-of-bounds offsets clamp to the last
/// line.
pub fn lineAt(source: []const u8, byte: u32) []const u8 {
    if (source.len == 0) return source;
    const idx: usize = if (byte >= source.len) source.len - 1 else @intCast(byte);
    // Walk back to the previous newline (or start).
    var start: usize = idx;
    while (start > 0 and source[start - 1] != '\n') start -= 1;
    // Walk forward to the next newline (or end).
    var end: usize = idx;
    while (end < source.len and source[end] != '\n') end += 1;
    return source[start..end];
}

/// Number of caret `^` characters to draw under a span. Clamp to
/// at least 1 (zero-width spans still need a marker) and to the
/// remaining bytes on the line (a span that crosses a newline only
/// gets carets up to the line end).
fn caretLength(source: []const u8, span: ast.Span) usize {
    if (span.end <= span.start) return 1;
    var len: usize = span.end - span.start;
    var i: usize = span.start;
    var seen_nl: usize = 0;
    while (i < span.end and i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            seen_nl = i - span.start;
            break;
        }
    }
    if (seen_nl > 0) len = seen_nl;
    return @max(len, 1);
}

fn digitsOf(n: usize) usize {
    if (n == 0) return 1;
    var d: usize = 0;
    var x = n;
    while (x > 0) : (x /= 10) d += 1;
    return d;
}

fn severityLabel(s: Severity) []const u8 {
    return switch (s) {
        .fatal => "error",
        .warning => "warning",
        .note => "note",
    };
}

fn severityName(s: Severity) []const u8 {
    // JSON variant — same set today.
    return severityLabel(s);
}

fn writeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |b| switch (b) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        // Remaining ASCII control chars (\t, \n, \r already handled above).
        0...8, 11, 12, 14...0x1f => try writer.print("\\u{x:0>4}", .{b}),
        else => try writer.writeByte(b),
    };
    try writer.writeByte('"');
}
