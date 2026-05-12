/// `include` resolution — source-level. Walks the include graph
/// from a root `.gas` file, concatenates every reachable file's
/// content into one buffer the unified parser can chew on
/// without needing to do its own file I/O. Splice is textual per
/// asm spec §2.2 — every `include` emits the target's bytes
/// every time.
///
/// The fused source carries a `SourceMap` sidecar so diagnostics
/// raised by the downstream parser (which sees only the fused
/// buffer) can be resolved back to `(file, line, col)`. Same
/// E012 / E013 / E015 surface as the previous token-level
/// implementation, just attached to source byte ranges.
const std = @import("std");
const knit = @import("knit");
const core = knit.core;

const Io = std.Io;
const Dir = Io.Dir;

const max_include_depth: u8 = 32;
const max_file_size: usize = 16 * 1024 * 1024;

/// One source file's metadata — owned canonical path + raw
/// content. Files are deduplicated by canonical path inside the
/// `SourceMap`; a file included multiple times shares one
/// `FileInfo` entry, with several `Region`s referencing it.
pub const FileInfo = struct {
    path: [:0]const u8,
    content: []const u8,
};

/// Contiguous byte range in the fused source, mapped back to a
/// segment of one original file. A file with N elided `include`
/// directives produces N+1 regions (one between each include).
pub const Region = struct {
    fused_start: u32,
    fused_end: u32,
    file_id: u16,
    /// Where in `file.content` the bytes at `fused_start` come from.
    file_offset: u32,
};

/// Resolves a global offset in the fused buffer back to a
/// `(file, file_offset)` pair. Built up incrementally during
/// resolution.
pub const SourceMap = struct {
    files: std.ArrayList(FileInfo),
    regions: std.ArrayList(Region),
    allocator: std.mem.Allocator,

    /// Release every owned path + content buffer and the lists.
    pub fn deinit(self: *SourceMap) void {
        for (self.files.items) |f| {
            self.allocator.free(f.path);
            self.allocator.free(f.content);
        }
        self.files.deinit(self.allocator);
        self.regions.deinit(self.allocator);
    }

    /// Find which file + offset `fused_offset` resolves to.
    /// Returns `null` if the offset falls outside every region
    /// (shouldn't happen for well-formed inputs).
    pub fn lookup(self: SourceMap, fused_offset: u32) ?Located {
        // Linear scan — fine while file counts stay small;
        // upgrade to binary search if profiling shows a hot spot.
        for (self.regions.items) |r| {
            if (fused_offset >= r.fused_start and fused_offset < r.fused_end) {
                const file = self.files.items[r.file_id];
                return .{
                    .file = file,
                    .file_offset = r.file_offset + (fused_offset - r.fused_start),
                };
            }
        }
        return null;
    }

    /// Look up or register a file by canonical path. On a cache
    /// hit `caller_path` is freed (we already own a copy);
    /// likewise `caller_content`. On a miss the buffers are
    /// adopted and the new `file_id` is returned.
    fn intern(
        self: *SourceMap,
        caller_path: [:0]const u8,
        caller_content: []const u8,
    ) !u16 {
        for (self.files.items, 0..) |f, i| {
            if (std.mem.eql(u8, f.path, caller_path)) {
                self.allocator.free(caller_path);
                self.allocator.free(caller_content);
                // safety: file_id fits in u16 (see comment on FileInfo).
                return @intCast(i);
            }
        }
        // safety: file_id fits in u16 — runaway include graphs hit
        // `max_include_depth` long before this overflows.
        const id: u16 = @intCast(self.files.items.len);
        try self.files.append(self.allocator, .{
            .path = caller_path,
            .content = caller_content,
        });
        return id;
    }

    fn appendRegion(
        self: *SourceMap,
        fused_start: u32,
        fused_end: u32,
        file_id: u16,
        file_offset: u32,
    ) !void {
        try self.regions.append(self.allocator, .{
            .fused_start = fused_start,
            .fused_end = fused_end,
            .file_id = file_id,
            .file_offset = file_offset,
        });
    }
};

/// Result of resolving a fused offset back to its origin.
pub const Located = struct {
    file: FileInfo,
    file_offset: u32,
};

/// Diagnostic carrying a fused-buffer byte offset (inside
/// `parse_error.index`). Use `SourceMap.lookup` to resolve.
/// `code` is set for semantic errors that map to asm spec §8's
/// E001..E016 list; generic syntax errors leave it `null`.
pub const Diagnostic = struct {
    parse_error: core.ParseError,
    code: ?ErrorCode = null,
};

/// Asm spec §8 error codes. Numerical IDs match the spec's
/// `E001..E016` table — `@intFromEnum(ErrorCode.unknown_mnemonic) == 1`.
pub const ErrorCode = enum(u8) {
    /// E001: unknown mnemonic.
    unknown_mnemonic = 1,
    /// E002: operand count mismatch.
    operand_count_mismatch = 2,
    /// E003: operand type mismatch (no opcode for this combination).
    operand_type_mismatch = 3,
    /// E004: undefined symbol.
    undefined_symbol = 4,
    /// E005: duplicate label.
    duplicate_label = 5,
    /// E006: hex literal out of range.
    hex_out_of_range = 6,
    /// E007: address out of range.
    addr_out_of_range = 7,
    /// E008: reserved opcode used.
    reserved_opcode = 8,
    /// E009: division by zero in compile-time expression.
    div_by_zero = 9,
    /// E010: unknown escape sequence in string or char literal.
    unknown_escape = 10,
    /// E011: unterminated string literal.
    unterminated_string = 11,
    /// E012: `include` cycle detected.
    include_cycle = 12,
    /// E013: `include` depth exceeds 32.
    include_depth_exceeded = 13,
    /// E014: backward `org` would overlap already-emitted bytes.
    backward_org = 14,
    /// E015: `include` target file not found.
    include_not_found = 15,
    /// E016: char literal must be exactly one byte.
    char_literal_size = 16,

    /// Map a lexer-level `ParseError.message` to the asm spec §8
    /// code, or `null` when the message isn't one of the four
    /// lex-level categories that map to E-codes (E006 / E010 /
    /// E011 / E016). Substring match — the lexer messages are
    /// stable strings; keep this lookup close to the enum so
    /// drift is easy to spot.
    pub fn fromLexerMessage(message: []const u8) ?ErrorCode {
        if (std.mem.indexOf(u8, message, "hex literal exceeds 4 digits") != null) return .hex_out_of_range;
        if (std.mem.indexOf(u8, message, "unterminated string literal") != null) return .unterminated_string;
        if (std.mem.indexOf(u8, message, "unknown escape sequence") != null) return .unknown_escape;
        if (std.mem.indexOf(u8, message, "empty char literal") != null) return .char_literal_size;
        if (std.mem.indexOf(u8, message, "char literal must be exactly one byte") != null) return .char_literal_size;
        if (std.mem.indexOf(u8, message, "unterminated char literal") != null) return .char_literal_size;
        return null;
    }

    /// Render as `E001`..`E016`. Caller owns nothing — the
    /// returned slice has static storage.
    pub fn shortLabel(self: ErrorCode) []const u8 {
        // Map by value rather than a giant switch to keep the
        // function tiny. The runtime cost is one switch + four
        // bytes of formatted output.
        return switch (self) {
            .unknown_mnemonic => "E001",
            .operand_count_mismatch => "E002",
            .operand_type_mismatch => "E003",
            .undefined_symbol => "E004",
            .duplicate_label => "E005",
            .hex_out_of_range => "E006",
            .addr_out_of_range => "E007",
            .reserved_opcode => "E008",
            .div_by_zero => "E009",
            .unknown_escape => "E010",
            .unterminated_string => "E011",
            .include_cycle => "E012",
            .include_depth_exceeded => "E013",
            .backward_org => "E014",
            .include_not_found => "E015",
            .char_literal_size => "E016",
        };
    }
};

/// Output of `resolveIncludes` — fused source + file map + errors.
pub const FusedSource = struct {
    /// Reachable files' contents concatenated in include order,
    /// with `include` directive lines themselves elided.
    source: []const u8,
    source_map: SourceMap,
    errors: []Diagnostic,
    allocator: std.mem.Allocator,

    /// Release the fused buffer, file map, and diagnostics list.
    pub fn deinit(self: *FusedSource) void {
        self.allocator.free(self.source);
        self.source_map.deinit();
        self.allocator.free(self.errors);
    }

    /// `true` when at least one diagnostic was recorded during resolution.
    pub fn hasErrors(self: FusedSource) bool {
        return self.errors.len > 0;
    }
};

/// Error set returned by recursive resolution. Surface-level
/// diagnostics (cycle / depth / missing) go through
/// `ctx.errors`; this set is for hard failures (OOM, I/O).
pub const ResolveError = Dir.RealPathFileAllocError || Dir.ReadFileAllocError;

const Context = struct {
    io: Io,
    allocator: std.mem.Allocator,
    fused: *std.ArrayList(u8),
    source_map: *SourceMap,
    errors: *std.ArrayList(Diagnostic),
    /// Canonical paths currently being resolved — cycle detection.
    /// Strings reference paths owned by `source_map.files`.
    in_progress: *std.ArrayList([]const u8),
};

/// Walk the include graph from `root_path` and produce a single
/// fused source string + a `SourceMap` that resolves fused
/// offsets back to `(file, line, col)`.
pub fn resolveIncludes(
    io: Io,
    allocator: std.mem.Allocator,
    root_path: []const u8,
) ResolveError!FusedSource {
    var fused: std.ArrayList(u8) = .empty;
    errdefer fused.deinit(allocator);

    var source_map: SourceMap = .{
        .files = .empty,
        .regions = .empty,
        .allocator = allocator,
    };
    errdefer source_map.deinit();

    var errors: std.ArrayList(Diagnostic) = .empty;
    errdefer errors.deinit(allocator);

    var in_progress: std.ArrayList([]const u8) = .empty;
    defer in_progress.deinit(allocator);

    var ctx = Context{
        .io = io,
        .allocator = allocator,
        .fused = &fused,
        .source_map = &source_map,
        .errors = &errors,
        .in_progress = &in_progress,
    };

    try resolveOne(&ctx, root_path, null, 0, 0);

    return .{
        .source = try fused.toOwnedSlice(allocator),
        .source_map = source_map,
        .errors = try errors.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

fn resolveOne(
    ctx: *Context,
    requested: []const u8,
    base_dir: ?[]const u8,
    depth: u8,
    include_site_offset: u32,
) ResolveError!void {
    if (depth > max_include_depth) {
        try ctx.errors.append(ctx.allocator, .{
            .code = .include_depth_exceeded,
            .parse_error = core.parseError(
                "include",
                include_site_offset,
                "include depth exceeds 32 — likely runaway recursion",
                .{ .expected = "shorter include chain", .kind = .semantic },
            ),
        });
        return;
    }

    const absolute = if (std.fs.path.isAbsolute(requested))
        try ctx.allocator.dupe(u8, requested)
    else if (base_dir) |dir|
        try std.fs.path.join(ctx.allocator, &.{ dir, requested })
    else
        try std.fs.path.join(ctx.allocator, &.{ ".", requested });
    defer ctx.allocator.free(absolute);

    const canonical = Dir.cwd().realPathFileAlloc(ctx.io, absolute, ctx.allocator) catch |err| switch (err) {
        error.FileNotFound => {
            try ctx.errors.append(ctx.allocator, .{
                .code = .include_not_found,
                .parse_error = core.parseError(
                    "include",
                    include_site_offset,
                    "include target file not found",
                    .{ .expected = "existing .gas file", .actual = requested, .kind = .semantic },
                ),
            });
            return;
        },
        else => return err,
    };

    for (ctx.in_progress.items) |p| {
        if (std.mem.eql(u8, p, canonical)) {
            try ctx.errors.append(ctx.allocator, .{
                .code = .include_cycle,
                .parse_error = core.parseError(
                    "include",
                    include_site_offset,
                    "include cycle detected",
                    .{ .expected = "non-cyclic include graph", .actual = requested, .kind = .semantic },
                ),
            });
            ctx.allocator.free(canonical);
            return;
        }
    }

    // Read content; ownership of (canonical, content) transfers to source_map.intern.
    const content = Dir.cwd().readFileAlloc(ctx.io, canonical, ctx.allocator, Io.Limit.limited(max_file_size)) catch |err| {
        ctx.allocator.free(canonical);
        return err;
    };

    const file_id = ctx.source_map.intern(canonical, content) catch |err| {
        ctx.allocator.free(canonical);
        ctx.allocator.free(content);
        return err;
    };

    // Re-fetch the interned file's content slice (the buffer
    // we passed in may have been freed if it duplicates an
    // earlier file). After intern, the canonical FileInfo owns
    // the live copy.
    const file = ctx.source_map.files.items[file_id];

    try ctx.in_progress.append(ctx.allocator, file.path);
    defer _ = ctx.in_progress.pop();

    try processSource(ctx, file.content, file.path, file_id, depth);
}

/// Walk one file's content, copying non-include lines into the
/// fused buffer (emitting a `Region` per contiguous segment of
/// kept bytes) and recursing on `include "..."` directives.
fn processSource(
    ctx: *Context,
    content: []const u8,
    canonical: [:0]const u8,
    file_id: u16,
    depth: u8,
) ResolveError!void {
    // The current "open segment" — bytes from `seg_file_start` in
    // the original file that have been (or will be) appended to
    // the fused buffer starting at `seg_fused_start`. Closed +
    // a region recorded when we hit an include or end-of-file.
    var seg_file_start: u32 = 0;
    var seg_fused_start: u32 = @intCast(ctx.fused.items.len);

    var i: usize = 0;
    while (i < content.len) {
        const line_start = i;
        var in_string = false;
        while (i < content.len and content[i] != '\n') : (i += 1) {
            const b = content[i];
            if (in_string) {
                if (b == '\\' and i + 1 < content.len) {
                    i += 1; // skip the escaped byte
                } else if (b == '"') {
                    in_string = false;
                }
                continue;
            }
            if (b == '"') {
                in_string = true;
            } else if (b == ';') {
                while (i < content.len and content[i] != '\n') : (i += 1) {}
                break;
            }
        }
        const line_end = i;
        const line = content[line_start..line_end];

        if (matchIncludeLine(line)) |target| {
            // Close the current segment up to (but not including)
            // the include line.
            const seg_file_end: u32 = @intCast(line_start);
            if (seg_file_end > seg_file_start) {
                try ctx.source_map.appendRegion(
                    seg_fused_start,
                    @intCast(ctx.fused.items.len),
                    file_id,
                    seg_file_start,
                );
            }
            // Emit a 1-byte sentinel (a newline) for the include
            // directive itself so the include site has a position
            // in the fused buffer that maps back to the right
            // file. Without it, an error attached to the include
            // (E012 / E013 / E015) has no Region to resolve.
            const sentinel_start: u32 = @intCast(ctx.fused.items.len);
            try ctx.fused.append(ctx.allocator, '\n');
            try ctx.source_map.appendRegion(
                sentinel_start,
                sentinel_start + 1,
                file_id,
                @intCast(line_start),
            );
            const this_dir = std.fs.path.dirname(canonical) orelse ".";
            try resolveOne(ctx, target, this_dir, depth + 1, sentinel_start);
            // Advance past the include directive's newline (if any).
            const after_newline = if (i < content.len) i + 1 else i;
            seg_file_start = @intCast(after_newline);
            seg_fused_start = @intCast(ctx.fused.items.len);
            i = after_newline;
            continue;
        }

        // Non-include line: append it + its newline to fused.
        try ctx.fused.appendSlice(ctx.allocator, line);
        if (i < content.len) try ctx.fused.append(ctx.allocator, '\n');
        // Advance past the newline.
        if (i < content.len) i += 1;
    }

    // Close the final segment.
    const seg_file_end: u32 = @intCast(content.len);
    if (seg_file_end > seg_file_start) {
        try ctx.source_map.appendRegion(
            seg_fused_start,
            @intCast(ctx.fused.items.len),
            file_id,
            seg_file_start,
        );
    }
}

/// If `line` is an `include "path"` directive, return the path
/// (without surrounding quotes). Otherwise `null`. Leading
/// whitespace is skipped; trailing whitespace + `;`-comments
/// are tolerated. Intentionally lenient about the directive's
/// grammar — full validation is the parser's job.
fn matchIncludeLine(line: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    const kw = "include";
    if (i + kw.len > line.len) return null;
    if (!std.mem.eql(u8, line[i .. i + kw.len], kw)) return null;
    i += kw.len;
    if (i >= line.len or (line[i] != ' ' and line[i] != '\t')) return null;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i >= line.len or line[i] != '"') return null;
    const path_start = i + 1;
    var j = path_start;
    while (j < line.len and line[j] != '"') : (j += 1) {}
    if (j >= line.len) return null;
    const path_end = j;
    var k = j + 1;
    while (k < line.len and (line[k] == ' ' or line[k] == '\t')) k += 1;
    if (k < line.len and line[k] != ';') return null;
    return line[path_start..path_end];
}

/// ANSI escape strings the formatter wraps around the colored
/// pieces of a diagnostic. `Style.plain` emits no escapes; the
/// CLI flips to `Style.ansi` when stderr is a TTY.
pub const Style = struct {
    /// Wraps the `path:line:col` prefix.
    location: []const u8 = "",
    /// Wraps the `[Exxx]` error code.
    code: []const u8 = "",
    /// Wraps the gutter (line-number column + `|` separator).
    gutter: []const u8 = "",
    /// Wraps the caret `^` under the offending column.
    caret: []const u8 = "",
    /// Reset escape, emitted after every wrapped piece.
    reset: []const u8 = "",

    /// No ANSI escapes — default for tests + non-TTY output.
    pub const plain: Style = .{};

    /// Standard ANSI palette: bold location, red `[Exxx]`, dim
    /// gutter, red caret.
    pub const ansi: Style = .{
        .location = "\x1b[1m",
        .code = "\x1b[1;31m",
        .gutter = "\x1b[2m",
        .caret = "\x1b[1;31m",
        .reset = "\x1b[0m",
    };
};

/// Format one `Diagnostic` as
/// `<path>:<line>:<col>: [<code>] <message>`. The `[Exxx]` prefix
/// is included only when the diagnostic carries an `ErrorCode`
/// (semantic errors per asm spec §8); plain syntax errors emit
/// no bracketed code.
pub fn formatDiagnostic(
    writer: anytype,
    source_map: SourceMap,
    err: Diagnostic,
    style: Style,
) !void {
    // safety: ParseError indexes fit in u32 — our sources are
    // bounded by max_file_size (16 MiB).
    const offset: u32 = @intCast(err.parse_error.index);
    if (source_map.lookup(offset)) |loc| {
        const lc = computeLineCol(loc.file.content, loc.file_offset);
        try writeHeader(writer, loc.file.path, lc, err, style);
    } else {
        try writer.print("{s}<unknown>:0:{d}{s}: ", .{ style.location, offset, style.reset });
        if (err.code) |c| {
            try writer.print("{s}[{s}]{s} ", .{ style.code, c.shortLabel(), style.reset });
        }
        try writer.print("{s}\n", .{err.parse_error.message});
    }
}

/// Pretty-format one `Diagnostic` with a caret snippet:
///
/// ```text
/// <path>:<line>:<col>: [E004] undefined symbol
///   3 | jmp missing
///     |     ^
/// ```
///
/// The snippet shows the offending source line, with a caret
/// underneath the column the diagnostic points at. Falls back to
/// the plain `formatDiagnostic` shape when the source-map lookup
/// fails.
pub fn formatPretty(
    writer: anytype,
    source_map: SourceMap,
    err: Diagnostic,
    style: Style,
) !void {
    // safety: ParseError indexes fit in u32 — our sources are
    // bounded by max_file_size (16 MiB).
    const offset: u32 = @intCast(err.parse_error.index);
    const loc = source_map.lookup(offset) orelse {
        return formatDiagnostic(writer, source_map, err, style);
    };
    const lc = computeLineCol(loc.file.content, loc.file_offset);
    try writeHeader(writer, loc.file.path, lc, err, style);
    try writeCaretSnippet(writer, loc.file.content, loc.file_offset, lc, style);
}

/// Same as `formatPretty` but without the leading `<path>:` —
/// emits `<line>:<col>: [Exxx] <msg>` plus the caret snippet.
/// Use this when the caller prints a path section header itself
/// and wants per-file grouping (e.g. multiple errors from one
/// included file).
pub fn formatPrettyBody(
    writer: anytype,
    source_map: SourceMap,
    err: Diagnostic,
    style: Style,
) !void {
    // safety: ParseError indexes fit in u32 — our sources are
    // bounded by max_file_size (16 MiB).
    const offset: u32 = @intCast(err.parse_error.index);
    const loc = source_map.lookup(offset) orelse {
        // No source-map info — fall back to the full path-bearing
        // shape so the user still sees something useful.
        return formatDiagnostic(writer, source_map, err, style);
    };
    const lc = computeLineCol(loc.file.content, loc.file_offset);
    try writer.print("{s}{d}:{d}{s}: ", .{ style.location, lc.line, lc.col, style.reset });
    if (err.code) |c| {
        try writer.print("{s}[{s}]{s} ", .{ style.code, c.shortLabel(), style.reset });
    }
    try writer.print("{s}\n", .{err.parse_error.message});
    try writeCaretSnippet(writer, loc.file.content, loc.file_offset, lc, style);
}

/// `<path>:<line>:<col>: [Exxx] <message>` header line, shared
/// between `formatDiagnostic` and `formatPretty`.
fn writeHeader(
    writer: anytype,
    path: []const u8,
    lc: LineCol,
    err: Diagnostic,
    style: Style,
) !void {
    try writer.print("{s}{s}:{d}:{d}{s}: ", .{ style.location, path, lc.line, lc.col, style.reset });
    if (err.code) |c| {
        try writer.print("{s}[{s}]{s} ", .{ style.code, c.shortLabel(), style.reset });
    }
    try writer.print("{s}\n", .{err.parse_error.message});
}

/// Two lines: the source line with line-number gutter + the
/// caret line under the offending column. Shared between
/// `formatPretty` and `formatPrettyBody`.
fn writeCaretSnippet(
    writer: anytype,
    content: []const u8,
    target_offset: u32,
    lc: LineCol,
    style: Style,
) !void {
    const line_slice = lineAt(content, target_offset);
    // Right-align the gutter so the caret column math stays simple.
    try writer.print("{s}{d: >4} |{s} {s}\n", .{ style.gutter, lc.line, style.reset, line_slice });
    try writer.print("{s}     |{s} ", .{ style.gutter, style.reset });
    var pad: u32 = 1;
    while (pad < lc.col) : (pad += 1) try writer.writeByte(' ');
    try writer.print("{s}^{s}\n", .{ style.caret, style.reset });
}

const LineCol = struct { line: u32, col: u32 };

fn computeLineCol(content: []const u8, target: u32) LineCol {
    var line: u32 = 1;
    var col: u32 = 1;
    var i: usize = 0;
    // @as: widen u32 file offset to usize for the slice-length comparison.
    const end = @min(@as(usize, target), content.len);
    while (i < end) : (i += 1) {
        if (content[i] == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .col = col };
}

/// Return the slice of `content` that holds the line containing
/// `target` (file-relative byte offset). Trailing `\n` is excluded.
fn lineAt(content: []const u8, target: u32) []const u8 {
    // @as: widen u32 file offset to usize for slice indexing.
    const t = @min(@as(usize, target), content.len);
    var start: usize = t;
    while (start > 0 and content[start - 1] != '\n') start -= 1;
    var end: usize = t;
    while (end < content.len and content[end] != '\n') end += 1;
    return content[start..end];
}
