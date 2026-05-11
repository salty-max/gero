/// `include` resolution phase — walks the asm source graph,
/// fusing tokens from every reachable file into one stream the
/// downstream parser can consume directly. Splice is textual per
/// asm spec §2.2 (each `include` emits the target's tokens every
/// time — NASM tradition). Cycle detection bounds runaway
/// recursion (E012); depth cap (E013) guards pathological graphs;
/// missing target (E015) is a per-include diagnostic.
const std = @import("std");
const knit = @import("knit");
const core = knit.core;
const lexer = @import("lexer.zig");

const Io = std.Io;
const Dir = Io.Dir;

/// Hard cap on the include chain depth — bounds recursion so a
/// pathological graph can't blow the stack.
const max_include_depth: u8 = 32;

/// 16 MiB ceiling on an individual `.gas` file. Real source is
/// orders of magnitude smaller; this guards against
/// runaway file descriptors / accidental binary reads.
const max_file_size: usize = 16 * 1024 * 1024;

/// One source file in the fused image — canonicalized path plus
/// raw content. `FileTable` owns both buffers. `path` is
/// sentinel-terminated because `realPathFileAlloc` returns
/// `[:0]u8` and we need to keep the sentinel info for the
/// allocator to free the right size on `deinit`.
pub const FileInfo = struct {
    path: [:0]const u8,
    content: []const u8,
};

/// Indexed registry of every file pulled into the build. Token
/// `file_id` fields point here. Errors are also keyed by file_id
/// so the formatter can derive the right line/col.
pub const FileTable = struct {
    files: std.ArrayList(FileInfo),
    allocator: std.mem.Allocator,

    /// Free every owned path + content buffer and the backing list.
    pub fn deinit(self: *FileTable) void {
        for (self.files.items) |f| {
            self.allocator.free(f.path);
            self.allocator.free(f.content);
        }
        self.files.deinit(self.allocator);
    }

    /// Look up the FileInfo for a given file_id. Caller's job to
    /// pass a valid id (in `[0, files.len)`).
    pub fn get(self: FileTable, id: u16) FileInfo {
        return self.files.items[id];
    }

    fn append(self: *FileTable, path: [:0]const u8, content: []const u8) !u16 {
        // safety: FileTable is build-once, append-only; u16 caps
        // the count at 65k files which is far above any sane
        // assembly project.
        const id: u16 = @intCast(self.files.items.len);
        try self.files.append(self.allocator, .{ .path = path, .content = content });
        return id;
    }
};

/// Diagnostic with its originating file pinned. Wraps the raw
/// `knit.ParseError` so downstream formatting can resolve the
/// `<file>:<line>:<col>` prefix.
pub const Diagnostic = struct {
    file_id: u16,
    parse_error: core.ParseError,
};

/// Output of `resolveIncludes` — everything the parser needs to
/// see a single project as one stream.
pub const FusedSource = struct {
    file_table: FileTable,
    tokens: []lexer.Token,
    errors: []Diagnostic,
    allocator: std.mem.Allocator,

    /// Release the file table, token buffer, and diagnostics list.
    pub fn deinit(self: *FusedSource) void {
        self.file_table.deinit();
        self.allocator.free(self.tokens);
        self.allocator.free(self.errors);
    }

    /// `true` when at least one diagnostic was recorded during resolution.
    pub fn hasErrors(self: FusedSource) bool {
        return self.errors.len > 0;
    }
};

/// Mutable working state threaded through every recursive call.
const Context = struct {
    io: Io,
    allocator: std.mem.Allocator,
    file_table: *FileTable,
    tokens: *std.ArrayList(lexer.Token),
    errors: *std.ArrayList(Diagnostic),
    /// Canonical paths currently being resolved — cycle detection.
    /// Entries reference path strings owned by `file_table` (each
    /// entry is the canonical path that's been registered there
    /// for the duration of its recursive call).
    in_progress: *std.ArrayList([:0]const u8),
};

/// Resolve `root_path` and every file it includes (transitively)
/// into a single fused token stream. Diagnostics are collected,
/// not thrown — caller drains `.errors` to see all problems.
///
/// Returns an allocator error only if the build can't even start
/// (root file can't be read, OOM, etc.). All include-time
/// problems (cycle, depth, missing target) show up as
/// `Diagnostic`s on the returned `FusedSource`.
pub fn resolveIncludes(
    io: Io,
    allocator: std.mem.Allocator,
    root_path: []const u8,
) !FusedSource {
    var file_table: FileTable = .{ .files = .empty, .allocator = allocator };
    errdefer file_table.deinit();

    var tokens: std.ArrayList(lexer.Token) = .empty;
    errdefer tokens.deinit(allocator);

    var errors: std.ArrayList(Diagnostic) = .empty;
    errdefer errors.deinit(allocator);

    var in_progress: std.ArrayList([:0]const u8) = .empty;
    defer in_progress.deinit(allocator);

    var ctx = Context{
        .io = io,
        .allocator = allocator,
        .file_table = &file_table,
        .tokens = &tokens,
        .errors = &errors,
        .in_progress = &in_progress,
    };

    try resolveOne(&ctx, root_path, null, 0, 0, 0);

    return .{
        .file_table = file_table,
        .tokens = try tokens.toOwnedSlice(allocator),
        .errors = try errors.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

fn resolveOne(
    ctx: *Context,
    requested: []const u8,
    base_dir: ?[]const u8,
    depth: u8,
    include_site_file_id: u16,
    include_site_offset: usize,
) !void {
    if (depth > max_include_depth) {
        try ctx.errors.append(ctx.allocator, .{
            .file_id = include_site_file_id,
            .parse_error = core.parseError(
                "include",
                include_site_offset,
                "include depth exceeds 32 — likely runaway recursion",
                .{ .expected = "shorter include chain", .kind = .semantic },
            ),
        });
        return;
    }

    // Resolve requested to an absolute path (relative-to base_dir
    // or absolute-as-given). We can't use realpath directly on a
    // relative path because realpath's behavior depends on the
    // process cwd, and we want predictable resolution rooted at
    // the including file's directory.
    const absolute = if (std.fs.path.isAbsolute(requested))
        try ctx.allocator.dupe(u8, requested)
    else if (base_dir) |dir|
        try std.fs.path.join(ctx.allocator, &.{ dir, requested })
    else
        try std.fs.path.join(ctx.allocator, &.{ ".", requested });
    defer ctx.allocator.free(absolute);

    // Canonicalize so symlinks / `..` / `.` segments / casing
    // converge to the same key for dedup + cycle detection.
    // realPathFileAlloc returns a null-terminated owned slice; we
    // keep ownership of it through to the file_table.append below.
    const canonical = Dir.cwd().realPathFileAlloc(ctx.io, absolute, ctx.allocator) catch |err| switch (err) {
        error.FileNotFound => {
            try ctx.errors.append(ctx.allocator, .{
                .file_id = include_site_file_id,
                .parse_error = core.parseError(
                    "include",
                    include_site_offset,
                    "include target file not found",
                    .{
                        .expected = "existing .gas file",
                        .actual = requested,
                        .kind = .semantic,
                    },
                ),
            });
            return;
        },
        else => return err,
    };

    // Cycle: same path currently being resolved further up the
    // chain. Borrowing the canonical path string is safe because
    // every in_progress entry points into file_table-owned memory.
    for (ctx.in_progress.items) |p| {
        if (std.mem.eql(u8, p, canonical)) {
            try ctx.errors.append(ctx.allocator, .{
                .file_id = include_site_file_id,
                .parse_error = core.parseError(
                    "include",
                    include_site_offset,
                    "include cycle detected",
                    .{
                        .expected = "non-cyclic include graph",
                        .actual = requested,
                        .kind = .semantic,
                    },
                ),
            });
            ctx.allocator.free(canonical);
            return;
        }
    }

    // Read the file. On success, ownership of `content` transfers
    // to the file_table.
    const content = Dir.cwd().readFileAlloc(ctx.io, canonical, ctx.allocator, Io.Limit.limited(max_file_size)) catch |err| {
        ctx.allocator.free(canonical);
        return err;
    };

    const file_id = ctx.file_table.append(canonical, content) catch |err| {
        ctx.allocator.free(canonical);
        ctx.allocator.free(content);
        return err;
    };

    try ctx.in_progress.append(ctx.allocator, canonical);
    defer _ = ctx.in_progress.pop();

    var ts = try lexer.tokenize(ctx.allocator, content);
    defer ts.deinit();

    var i: usize = 0;
    var prev_was_newline = true; // start-of-file counts as a statement boundary
    while (i < ts.tokens.len) : (i += 1) {
        const t = ts.tokens[i];
        if (t.kind == .eof) break;

        const is_stmt_start = prev_was_newline;
        prev_was_newline = (t.kind == .newline);

        if (is_stmt_start and t.kind == .ident) {
            const ident_lex = content[t.start..t.end];
            if (std.mem.eql(u8, ident_lex, "include")) {
                if (i + 1 < ts.tokens.len and ts.tokens[i + 1].kind == .string) {
                    const path_tok = ts.tokens[i + 1];
                    const raw = content[path_tok.start..path_tok.end];
                    // Strip the surrounding quote bytes. Escape
                    // processing in include paths is out of scope
                    // for v0.1 — file system paths in practice
                    // don't need it.
                    const path_str = raw[1 .. raw.len - 1];

                    const this_dir = std.fs.path.dirname(canonical) orelse ".";

                    try resolveOne(
                        ctx,
                        path_str,
                        this_dir,
                        depth + 1,
                        file_id,
                        t.start,
                    );

                    // Skip the consumed `include "path"` pair plus
                    // the trailing newline if present, so the
                    // include statement doesn't leak through into
                    // the fused stream.
                    i += 1; // skip the string
                    if (i + 1 < ts.tokens.len and ts.tokens[i + 1].kind == .newline) {
                        i += 1;
                    }
                    prev_was_newline = true;
                    continue;
                }
                // Malformed: `include` without a following string.
                // Let the parser surface the syntax error — emit
                // the ident as a regular token below.
            }
        }

        var copied = t;
        copied.file_id = file_id;
        try ctx.tokens.append(ctx.allocator, copied);
    }

    // Lexer errors from this file get tagged with our file_id so
    // the formatter resolves them back to the right source.
    for (ts.errors) |e| {
        try ctx.errors.append(ctx.allocator, .{ .file_id = file_id, .parse_error = e });
    }
}

/// Format one `Diagnostic` as `<path>:<line>:<col>: <message>` —
/// the minimum prefix asm spec §8 mandates. The full multi-error
/// + caret-snippet treatment lives in #37 (`error formatting via
/// knit`); this helper is just enough to test that include
/// errors reference the right file.
pub fn formatDiagnostic(
    writer: anytype,
    file_table: FileTable,
    err: Diagnostic,
) !void {
    const file = file_table.get(err.file_id);
    const lc = computeLineCol(file.content, err.parse_error.index);
    try writer.print("{s}:{d}:{d}: {s}\n", .{ file.path, lc.line, lc.col, err.parse_error.message });
}

const LineCol = struct { line: usize, col: usize };

fn computeLineCol(source: []const u8, offset: usize) LineCol {
    var line: usize = 1;
    var col: usize = 1;
    var i: usize = 0;
    const end = @min(offset, source.len);
    while (i < end) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .col = col };
}
