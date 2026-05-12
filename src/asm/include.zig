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
pub const Diagnostic = struct {
    parse_error: core.ParseError,
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

/// Format one `Diagnostic` as `<path>:<line>:<col>: <message>`.
/// Resolves the diagnostic's fused-source offset via the
/// `SourceMap`. The full multi-error + caret-snippet treatment
/// lives in #37.
pub fn formatDiagnostic(
    writer: anytype,
    source_map: SourceMap,
    err: Diagnostic,
) !void {
    // safety: ParseError indexes fit in u32 — our sources are
    // bounded by max_file_size (16 MiB).
    const offset: u32 = @intCast(err.parse_error.index);
    if (source_map.lookup(offset)) |loc| {
        const lc = computeLineCol(loc.file.content, loc.file_offset);
        try writer.print("{s}:{d}:{d}: {s}\n", .{ loc.file.path, lc.line, lc.col, err.parse_error.message });
    } else {
        try writer.print("<unknown>:0:{d}: {s}\n", .{ offset, err.parse_error.message });
    }
}

const LineCol = struct { line: u32, col: u32 };

fn computeLineCol(content: []const u8, target: u32) LineCol {
    var line: u32 = 1;
    var col: u32 = 1;
    var i: usize = 0;
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
