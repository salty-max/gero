const std = @import("std");
const asm_ = @import("asm.zig");
const lang = @import("lang.zig");

/// A diagnostic's resolved position in the file it came from.
pub const Location = struct {
    path: []const u8,
    line: usize,
    column: usize,
};

/// 1-based (line, column) of `file_offset` within `content`.
pub fn lineColIn(content: []const u8, file_offset: u32) struct { line: usize, col: usize } {
    var line: usize = 1;
    var col: usize = 1;
    var i: usize = 0;
    while (i < content.len and i < file_offset) : (i += 1) {
        if (content[i] == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .col = col };
}

/// Source path `d` originated in, resolved through the fused map.
pub fn pathOf(source_map: asm_.SourceMap, d: asm_.Diagnostic) []const u8 {
    // safety: a fused-buffer index, bounded well under 4 GiB.
    const at: u32 = @intCast(d.parse_error.index);
    if (source_map.lookup(at)) |loc| return loc.file.path;
    return "";
}

/// Resolve `d` to a path and a 1-based position.
pub fn locationOf(source_map: asm_.SourceMap, d: asm_.Diagnostic) Location {
    // safety: a fused-buffer index, bounded well under 4 GiB.
    const at: u32 = @intCast(d.parse_error.index);
    if (source_map.lookup(at)) |loc| {
        const pos = lineColIn(loc.file.content, loc.file_offset);
        return .{ .path = loc.file.path, .line = pos.line, .column = pos.col };
    }
    return .{ .path = "", .line = 1, .column = 1 };
}

/// Write one asm diagnostic as a JSON object.
///
/// This and `writeLang` are the shape `lang-diagnostics.md` §9
/// specifies, and they live in the library rather than in a command so
/// every producer emits the same object. A terminal, an editor, and
/// the browser playground must agree on an error's wording, code, and
/// span; a second implementation is how they stop agreeing.
pub fn writeAsm(
    jw: *std.json.Stringify,
    source_map: asm_.SourceMap,
    d: asm_.Diagnostic,
) !void {
    const loc = locationOf(source_map, d);
    try jw.beginObject();
    try jw.objectField("file");
    try jw.write(loc.path);
    try jw.objectField("line");
    try jw.write(loc.line);
    try jw.objectField("column");
    try jw.write(loc.column);
    try jw.objectField("severity");
    try jw.write("error");
    if (d.code) |c| {
        try jw.objectField("code");
        try jw.write(c.shortLabel());
    }
    try jw.objectField("message");
    try jw.write(d.parse_error.message);
    if (d.note) |n| {
        try jw.objectField("note");
        try jw.write(n);
    }
    try jw.endObject();
}

/// Write one Gero diagnostic as a JSON object.
pub fn writeLang(
    jw: *std.json.Stringify,
    file: lang.render.FileDiagnostics,
    d: lang.Diagnostic,
) !void {
    const start = lang.render.lineColAt(file.source, d.span.start);
    const end = lang.render.lineColAt(file.source, d.span.end);
    try jw.beginObject();
    try jw.objectField("file");
    try jw.write(file.path);
    try jw.objectField("line");
    try jw.write(start.line);
    try jw.objectField("column");
    try jw.write(start.col);
    try jw.objectField("end_line");
    try jw.write(end.line);
    try jw.objectField("end_col");
    try jw.write(end.col);
    try jw.objectField("severity");
    try jw.write(switch (d.severity) {
        .fatal => "error",
        .warning => "warning",
        .note => "note",
    });
    try jw.objectField("code");
    try jw.write(d.code);
    try jw.objectField("message");
    try jw.write(d.message);
    if (d.help) |h| {
        try jw.objectField("note");
        try jw.write(h);
    }
    try jw.endObject();
}
