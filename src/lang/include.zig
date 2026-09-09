const std = @import("std");
const include_paths = @import("../include_paths.zig");

const Io = std.Io;
const Dir = Io.Dir;

const max_include_depth: u8 = 32;
const max_file_size: usize = 16 * 1024 * 1024;

/// `use X as Y from "./mod"` bindings collected while fusing: the
/// alias `Y` mapped to the real exported name `X`. A quoted-path
/// import inlines the module's source flat, so the alias has no
/// declaration of its own — front-ends resolve `Y` to `X` through
/// this table. Keys/values borrow the fused source buffer.
pub const ImportAliases = std.StringHashMapUnmanaged([]const u8);

/// One source file's metadata. Files dedupe by canonical path
/// inside `SourceMap`; a module referenced multiple times shares
/// one entry, several `Region`s pointing into it.
pub const FileInfo = struct {
    path: [:0]const u8,
    content: []const u8,
};

/// Contiguous fused-source byte range mapped back to a slice of
/// one original file. A file with N `use "..."` lines produces
/// N+1 regions (between each directive).
pub const Region = struct {
    fused_start: u32,
    fused_end: u32,
    file_id: u16,
    file_offset: u32,
};

/// One `use` edge in the module graph: `from` names the file whose
/// `use` directive pulled `to` in. Recorded even when the target was
/// already fused by an earlier `use`, so a diamond still shows both
/// importers.
pub const ImportEdge = struct {
    from: u16,
    to: u16,
};

/// Resolves a fused-source offset back to `(file, file_offset)`.
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

    /// Which file a fused offset belongs to. Cheaper than `lookup`
    /// when only the module identity is wanted — resolution asks this
    /// of every top-level declaration.
    pub fn fileIdAt(self: SourceMap, fused_offset: u32) ?u16 {
        for (self.regions.items) |r| {
            if (fused_offset >= r.fused_start and fused_offset < r.fused_end) return r.file_id;
        }
        return null;
    }

    /// File id for an already-interned canonical path, or `null` when
    /// the path hasn't been seen.
    pub fn findFileId(self: SourceMap, path: []const u8) ?u16 {
        for (self.files.items, 0..) |f, i| {
            // safety: file count is bounded by the include-depth walk; fits u16.
            if (std.mem.eql(u8, f.path, path)) return @intCast(i);
        }
        return null;
    }

    /// Find which file + offset `fused_offset` resolves to.
    /// `null` when the offset is outside every region.
    pub fn lookup(self: SourceMap, fused_offset: u32) ?Located {
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

    fn intern(
        self: *SourceMap,
        caller_path: [:0]const u8,
        caller_content: []const u8,
    ) !u16 {
        for (self.files.items, 0..) |f, i| {
            if (std.mem.eql(u8, f.path, caller_path)) {
                self.allocator.free(caller_path);
                self.allocator.free(caller_content);
                // safety: file_id fits in u16; runaway include graphs hit max_include_depth long before this overflows.
                return @intCast(i);
            }
        }
        // safety: file_id fits in u16; bounded by max_include_depth.
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

/// Result of resolving a fused offset back to its origin file.
pub const Located = struct {
    file: FileInfo,
    file_offset: u32,
};

/// Reason an `IncludeError` fired.
pub const IncludeErrorKind = enum {
    cycle,
    depth_exceeded,
    not_found,
    /// `use X as Y` and `use Z as Y` bind the same alias `Y` to two
    /// different targets.
    duplicate_alias,
    /// The target resolved to a file spelled differently — a
    /// case-insensitive filesystem answering a request whose spelling
    /// does not match. Refused, so a program that compiles on one host
    /// compiles on every host.
    case_mismatch,
};

/// The `E_USE_*` code a kind renders as, per lang-diagnostics.md.
///
/// Lives here rather than at each call site: the CLI reports these
/// from two places and the codes are a documented contract, so one
/// spelling of them is the point.
pub fn includeErrorCode(kind: IncludeErrorKind) []const u8 {
    return switch (kind) {
        .cycle => "E_USE_CYCLE",
        .depth_exceeded => "E_USE_DEPTH",
        .not_found => "E_USE_NOT_FOUND",
        .duplicate_alias => "E_USE_DUPLICATE_ALIAS",
        .case_mismatch => "E_USE_CASE_MISMATCH",
    };
}

/// The user-facing text for one include error. Caller owns the result.
pub fn includeErrorMessage(
    allocator: std.mem.Allocator,
    kind: IncludeErrorKind,
    requested: []const u8,
) std.mem.Allocator.Error![]u8 {
    return switch (kind) {
        .cycle => std.fmt.allocPrint(allocator, "`use` cycle detected on `{s}`", .{requested}),
        .depth_exceeded => std.fmt.allocPrint(allocator, "`use` depth exceeds 32 on `{s}` — likely runaway recursion", .{requested}),
        .not_found => std.fmt.allocPrint(allocator, "`use` target file not found: `{s}`", .{requested}),
        .duplicate_alias => std.fmt.allocPrint(allocator, "import alias `{s}` is bound to two different targets", .{requested}),
        .case_mismatch => std.fmt.allocPrint(allocator, "`use` target `{s}` is spelled differently on disk — this filesystem ignores case, another will not", .{requested}),
    };
}

/// One error from the include-resolution phase. Carries the
/// fused-source offset of the offending `use` directive so the
/// CLI can render with caret context.
pub const IncludeError = struct {
    kind: IncludeErrorKind,
    /// Fused-source offset of the `use` directive that triggered
    /// the error.
    site_offset: u32,
    /// Path the user requested (verbatim, no resolution).
    requested: []const u8,
};

/// `resolveUseImports` output. Caller owns the buffers — call
/// `deinit` once done.
pub const FusedSource = struct {
    /// File id of the file resolution started from. Tools that care
    /// about one module's own declarations — rather than everything
    /// its imports dragged in — start here.
    entry_module: u16 = 0,
    /// Reachable files' contents concatenated in dependency
    /// order, with `use "..."` lines elided.
    source: []const u8,
    source_map: SourceMap,
    errors: []IncludeError,
    /// `use X as Y from "./mod"` alias bindings (`Y` → `X`).
    import_aliases: ImportAliases,
    /// Module graph: one entry per `use` directive, naming the file
    /// that declared it and the file it pulled in. Resolution reads
    /// this to decide which modules a given module can see.
    imports: []const ImportEdge,
    allocator: std.mem.Allocator,

    /// Release the fused buffer, source map, and errors list.
    pub fn deinit(self: *FusedSource) void {
        self.allocator.free(self.source);
        self.source_map.deinit();
        for (self.errors) |e| self.allocator.free(e.requested);
        self.allocator.free(self.errors);
        // Keys/values borrow the source buffers — only free the table.
        self.import_aliases.deinit(self.allocator);
        self.allocator.free(self.imports);
    }

    /// `true` when at least one include-phase error was recorded.
    pub fn hasErrors(self: FusedSource) bool {
        return self.errors.len > 0;
    }
};

/// Errors surfaced through the result `union` rather than the
/// error set: cycle / depth / not-found.
/// Host failures (OOM, I/O) propagate through the error union.
pub const ResolveError = Dir.RealPathFileAllocError || Dir.ReadFileAllocError;

/// Unsaved buffer contents, keyed by canonical absolute path. A file
/// listed here is taken from memory instead of from disk, so a
/// language server resolves a `use` graph against what the editor
/// shows rather than against what was last saved.
pub const Overlay = std.StringHashMapUnmanaged([]const u8);

/// Where a resolver finds the files a `use` graph names.
pub const Source = union(enum) {
    /// The host filesystem, with `overlay` shadowing it for buffers an
    /// editor holds unsaved.
    disk: struct { io: Io, overlay: ?*const Overlay },
    /// The set **is** the filesystem. A name it does not hold is
    /// not-found, and nothing is read from disk — which is what a
    /// browser host has, and what makes resolution closed: a path
    /// escaping the set is a diagnostic, never a fetch.
    virtual: *const Overlay,
};

/// Which path grammar this run's files are addressed by.
fn pathKind(ctx: *const Context) include_paths.Kind {
    return switch (ctx.source) {
        .disk => .host,
        .virtual => .virtual,
    };
}

const Context = struct {
    source: Source,
    allocator: std.mem.Allocator,
    fused: *std.ArrayList(u8),
    source_map: *SourceMap,
    errors: *std.ArrayList(IncludeError),
    in_progress: *std.ArrayList([]const u8),
    /// Canonical paths already fused. A file's symbols enter the
    /// program once no matter how many `use` sites reach it — a
    /// second emission would re-declare its top-level decls.
    emitted: *std.ArrayList([]const u8),
    /// `use X as Y from "./mod"` aliases, collected as each import
    /// directive is elided (the alias has no inlined declaration).
    import_aliases: *ImportAliases,
    imports: *std.ArrayList(ImportEdge),
};

/// Resolve every `use "./path"` reachable from `root_path` into
/// a fused source buffer. Quoted-path imports load the named
/// file; bare-ident imports (`use mem`) are left in source as-is
/// — they bind to compiler-recognized stdlib modules at
/// typecheck time.
pub fn resolveUseImports(
    io: Io,
    allocator: std.mem.Allocator,
    root_path: []const u8,
) ResolveError!FusedSource {
    return resolveUseImportsOverlaid(io, allocator, root_path, null);
}

/// `resolveUseImports`, reading any file listed in `overlay` from
/// memory instead of disk. Everything else is identical, so a server
/// answering about unsaved edits and `gero check` answering about the
/// saved tree run the same resolution.
pub fn resolveUseImportsOverlaid(
    io: Io,
    allocator: std.mem.Allocator,
    root_path: []const u8,
    overlay: ?*const Overlay,
) ResolveError!FusedSource {
    return resolveUseImportsFrom(allocator, root_path, .{ .disk = .{ .io = io, .overlay = overlay } });
}

/// Resolve a `use` graph entirely within `files`, with no filesystem.
/// A name the set does not hold is a not-found diagnostic rather than
/// a read, so resolution cannot reach outside what the caller supplied.
pub fn resolveUseImportsVirtual(
    allocator: std.mem.Allocator,
    root_name: []const u8,
    files: *const Overlay,
) ResolveError!FusedSource {
    return resolveUseImportsFrom(allocator, root_name, .{ .virtual = files });
}

/// The resolver both entry points share. `source` decides where files
/// come from; everything else — cycles, include-once, the source map,
/// alias collection — is identical either way.
pub fn resolveUseImportsFrom(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    source: Source,
) ResolveError!FusedSource {
    var fused: std.ArrayList(u8) = .empty;
    errdefer fused.deinit(allocator);

    var source_map: SourceMap = .{
        .files = .empty,
        .regions = .empty,
        .allocator = allocator,
    };
    errdefer source_map.deinit();

    var errors: std.ArrayList(IncludeError) = .empty;
    errdefer {
        for (errors.items) |e| allocator.free(e.requested);
        errors.deinit(allocator);
    }

    var in_progress: std.ArrayList([]const u8) = .empty;
    defer in_progress.deinit(allocator);

    var emitted: std.ArrayList([]const u8) = .empty;
    defer emitted.deinit(allocator);

    var import_aliases: ImportAliases = .{};
    errdefer import_aliases.deinit(allocator);

    var imports: std.ArrayList(ImportEdge) = .empty;
    errdefer imports.deinit(allocator);

    var ctx = Context{
        .source = source,
        .allocator = allocator,
        .fused = &fused,
        .source_map = &source_map,
        .errors = &errors,
        .in_progress = &in_progress,
        .emitted = &emitted,
        .import_aliases = &import_aliases,
        .imports = &imports,
    };

    const root_id = try resolveOne(&ctx, root_path, null, 0, 0);

    return .{
        .source = try fused.toOwnedSlice(allocator),
        .entry_module = root_id orelse 0,
        .source_map = source_map,
        .errors = try errors.toOwnedSlice(allocator),
        .import_aliases = import_aliases,
        .imports = try imports.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

fn resolveOne(
    ctx: *Context,
    requested: []const u8,
    base_dir: ?[]const u8,
    depth: u8,
    site_offset: u32,
) ResolveError!?u16 {
    if (depth > max_include_depth) {
        try recordError(ctx, .depth_exceeded, site_offset, requested);
        return null;
    }

    // Append `.gr` when missing so `use "./util"` resolves to
    // `util.gr`. Absolute paths pass through unchanged when
    // already qualified.
    var owned_requested: ?[]const u8 = null;
    defer if (owned_requested) |o| ctx.allocator.free(o);
    const with_ext: []const u8 = if (std.mem.endsWith(u8, requested, ".gr"))
        requested
    else blk: {
        owned_requested = try std.fmt.allocPrint(ctx.allocator, "{s}.gr", .{requested});
        break :blk owned_requested.?;
    };

    // The virtual set is addressed by POSIX-shaped keys on every
    // host; joining with a backslash would miss every one of them.
    const kind = pathKind(ctx);
    const absolute = if (include_paths.isAbsolute(kind, with_ext))
        try ctx.allocator.dupe(u8, with_ext)
    else if (base_dir) |dir|
        try include_paths.join(kind, ctx.allocator, &.{ dir, with_ext })
    else
        try include_paths.join(kind, ctx.allocator, &.{ ".", with_ext });
    defer ctx.allocator.free(absolute);

    const canonical = (try canonicalize(ctx, absolute)) orelse {
        try recordError(ctx, .not_found, site_offset, requested);
        return null;
    };
    // Only a relative request resolved against a parent: an absolute
    // path is the user's own, and may legitimately traverse a symlink
    // whose real name differs (`/tmp` is `/private/tmp` on macOS). The
    // portability hazard is the spelling written in source text.
    const check_spelling = base_dir != null and !include_paths.isAbsolute(pathKind(ctx), with_ext);
    if (check_spelling and !include_paths.spellingMatches(pathKind(ctx), with_ext, canonical)) {
        ctx.allocator.free(canonical);
        try recordError(ctx, .case_mismatch, site_offset, requested);
        return null;
    }

    // Cycle check first — a file in `emitted` is also in `in_progress`
    // mid-recursion, so a cyclic re-entry must be caught here before the
    // include-once short-circuit below masks it.
    for (ctx.in_progress.items) |p| {
        if (std.mem.eql(u8, p, canonical)) {
            try recordError(ctx, .cycle, site_offset, requested);
            ctx.allocator.free(canonical);
            return null;
        }
    }

    // Include-once: already fused via an earlier `use` — its decls are
    // in scope, so a second emission would redefine them. The
    // directive's sentinel region (appended by the caller) still
    // anchors any diagnostic.
    for (ctx.emitted.items) |p| {
        if (std.mem.eql(u8, p, canonical)) {
            // Already fused, but the importer still gains the edge —
            // a diamond means both files can see this module.
            const existing = ctx.source_map.findFileId(canonical);
            ctx.allocator.free(canonical);
            return existing;
        }
    }

    const content = readContent(ctx, canonical) catch |err| {
        ctx.allocator.free(canonical);
        return err;
    };

    const file_id = ctx.source_map.intern(canonical, content) catch |err| {
        ctx.allocator.free(canonical);
        ctx.allocator.free(content);
        return err;
    };

    const file = ctx.source_map.files.items[file_id];

    // Mark before recursing so a diamond (two paths to one file)
    // emits it once; `in_progress` still catches true cycles.
    try ctx.emitted.append(ctx.allocator, file.path);

    try ctx.in_progress.append(ctx.allocator, file.path);
    defer _ = ctx.in_progress.pop();

    try processSource(ctx, file.content, file.path, file_id, depth);
    return file_id;
}

/// Walk one file: copy non-`use` lines into the fused buffer,
/// recursing on each `use "..."`. Lines containing `--` comments
/// or string literals are scanned carefully so directives inside
/// strings or comments don't get matched.
/// This file's text: the editor's unsaved buffer when one is
/// overlaid, otherwise what is on disk. Always allocator-owned, since
/// `SourceMap.intern` takes ownership either way.
fn readContent(ctx: *Context, canonical: []const u8) ResolveError![]u8 {
    switch (ctx.source) {
        .disk => |d| {
            // unreachable: a freestanding build never constructs `.disk`,
            // and the comptime guard keeps this arm out of that build.
            if (comptime !hasFilesystem()) unreachable;
            if (d.overlay) |ov| {
                if (ov.get(canonical)) |buffered| return ctx.allocator.dupe(u8, buffered);
            }
            return Dir.cwd().readFileAlloc(d.io, canonical, ctx.allocator, Io.Limit.limited(max_file_size));
        },
        // `canonicalize` already proved the set holds it.
        .virtual => |files| return ctx.allocator.dupe(u8, files.get(canonical).?),
    }
}

/// The name a file is known by once resolved, or `null` when it does
/// not exist. On disk that is its real path; in a virtual set it is the
/// requested path with `.` and `..` folded out, since the set's keys
/// are already the canonical names.
/// How this target turns a path into a file's identity.
///
/// Identity is what the include graph is keyed on: two spellings of
/// one file have to canonicalize equal, or the diamond case splices
/// twice and the depth limit never terminates.
///
/// - `realpath` — the filesystem answers. Symlinks and `..` collapse,
///   and aliasing is detected.
/// - `lexical` — wasi, whose filesystem is preopened directories with
///   no `realpath`. `.` and `..` collapse textually; two paths that
///   reach one file through a symlink read as two files.
/// - `none` — freestanding has no filesystem at all, so the `.disk`
///   arm is compiled out rather than merely unused. Zig analyzes both
///   arms of a runtime switch, so an ordinary `if` would not do.
const Canonicalization = enum { realpath, lexical, none };

const canonicalization: Canonicalization = switch (@import("builtin").target.os.tag) {
    .freestanding => .none,
    .wasi => .lexical,
    else => .realpath,
};

fn hasFilesystem() bool {
    return canonicalization != .none;
}

/// Whether `path`'s parent directory holds an entry spelled exactly
/// like its basename.
///
/// A case-insensitive volume answers `access("Utils.gas")` for a file
/// named `utils.gas`, which is the trap the spelling rule exists to
/// close. Listing the directory is the only way to see the name the
/// filesystem actually stored.
fn namedExactly(io: Io, path: []const u8) !bool {
    const name = std.fs.path.basenamePosix(path);
    if (name.len == 0) return false;
    const parent = std.fs.path.dirnamePosix(path) orelse ".";

    var dir = Dir.cwd().openDir(io, parent, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch return false) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

fn canonicalize(ctx: *Context, absolute: []const u8) ResolveError!?[:0]u8 {
    switch (ctx.source) {
        .disk => |d| {
            // unreachable: a freestanding build never constructs `.disk`,
            // and the comptime guard keeps this arm out of that build.
            if (comptime canonicalization == .none) unreachable;
            if (comptime canonicalization == .lexical) {
                const normalized = try std.fs.path.resolvePosix(ctx.allocator, &.{absolute});
                defer ctx.allocator.free(normalized);
                // Lexical normalization echoes the spelling it was
                // given, so unlike `realpath` it cannot report either
                // "missing" or "spelled differently" on its own. The
                // directory answers both: an entry has to exist under
                // exactly this name.
                if (!(try namedExactly(d.io, normalized))) return null;
                return try ctx.allocator.dupeZ(u8, normalized);
            }
            return Dir.cwd().realPathFileAlloc(d.io, absolute, ctx.allocator) catch |err| switch (err) {
                error.FileNotFound => null,
                else => err,
            };
        },
        .virtual => |files| {
            const normalized = try std.fs.path.resolvePosix(ctx.allocator, &.{absolute});
            // A leading slash is an artifact of resolving against no
            // cwd; the set's names have none.
            const trimmed = std.mem.trimStart(u8, normalized, "/");
            if (files.contains(trimmed)) {
                const owned = try ctx.allocator.dupeZ(u8, trimmed);
                ctx.allocator.free(normalized);
                return owned;
            }
            ctx.allocator.free(normalized);
            return null;
        },
    }
}

fn processSource(
    ctx: *Context,
    content: []const u8,
    canonical: [:0]const u8,
    file_id: u16,
    depth: u8,
) ResolveError!void {
    var seg_file_start: u32 = 0;
    var seg_fused_start: u32 = @intCast(ctx.fused.items.len);

    var i: usize = 0;
    while (i < content.len) {
        const line_start = i;
        var in_string = false;
        var comment_at: ?usize = null;
        while (i < content.len and content[i] != '\n') : (i += 1) {
            const b = content[i];
            if (in_string) {
                if (b == '\\' and i + 1 < content.len) {
                    i += 1;
                } else if (b == '"') {
                    in_string = false;
                }
                continue;
            }
            if (b == '"') {
                in_string = true;
            } else if (b == '-' and i + 1 < content.len and content[i + 1] == '-') {
                // gero-lang line comment — skip the rest of the line.
                comment_at = i;
                while (i < content.len and content[i] != '\n') : (i += 1) {}
                break;
            }
        }
        const line_end = i;
        const line = content[line_start..line_end];
        // `use` detection + alias capture run on the code portion only,
        // so a `from` / `as` inside a trailing comment isn't parsed as
        // part of the directive.
        const code = content[line_start .. comment_at orelse line_end];

        if (matchUseQuotedLine(code)) |target| {
            // The directive is about to be elided; capture any `as`
            // aliases first, since the inlined module carries no
            // declaration for them. The fused length here equals the
            // sentinel offset appended below, so a duplicate-alias
            // diagnostic maps back to this `use` line.
            try collectAliases(ctx, code, @intCast(ctx.fused.items.len));
            const seg_file_end: u32 = @intCast(line_start);
            if (seg_file_end > seg_file_start) {
                try ctx.source_map.appendRegion(
                    seg_fused_start,
                    @intCast(ctx.fused.items.len),
                    file_id,
                    seg_file_start,
                );
            }
            // 1-byte sentinel for the directive position so any
            // error attached to the `use` line has a mappable
            // fused offset.
            const sentinel_start: u32 = @intCast(ctx.fused.items.len);
            try ctx.fused.append(ctx.allocator, '\n');
            try ctx.source_map.appendRegion(
                sentinel_start,
                sentinel_start + 1,
                file_id,
                @intCast(line_start),
            );
            const this_dir = include_paths.dirname(pathKind(ctx), canonical) orelse ".";
            if (try resolveOne(ctx, target, this_dir, depth + 1, sentinel_start)) |target_id| {
                try ctx.imports.append(ctx.allocator, .{ .from = file_id, .to = target_id });
            }
            const after_newline = if (i < content.len) i + 1 else i;
            seg_file_start = @intCast(after_newline);
            seg_fused_start = @intCast(ctx.fused.items.len);
            i = after_newline;
            continue;
        }

        try ctx.fused.appendSlice(ctx.allocator, line);
        if (i < content.len) try ctx.fused.append(ctx.allocator, '\n');
        if (i < content.len) i += 1;
    }

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

fn recordError(
    ctx: *Context,
    kind: IncludeErrorKind,
    site_offset: u32,
    requested: []const u8,
) !void {
    try ctx.errors.append(ctx.allocator, .{
        .kind = kind,
        .site_offset = site_offset,
        .requested = try ctx.allocator.dupe(u8, requested),
    });
}

/// If `line` is a `use "path"` directive, return the path
/// (without quotes). Otherwise `null`. Bare-ident `use math` and
/// the selective form `use foo from "./bar"` don't match — the
/// quoted-path form is what triggers file resolution. Selective
/// imports (`use a, b from "./bar"`) DO match — we strip
/// everything up to `from` first and apply the same quoted-path
/// rule on the right.
/// Index of a whitespace-delimited keyword `kw` (`from` / `as`) in
/// `s`, or null. Unlike a `" kw "` substring search this matches tab-
/// as well as space-separated tokens, and won't fire inside a longer
/// word (`class`, `fromage`).
fn findKeyword(s: []const u8, kw: []const u8) ?usize {
    var i: usize = 0;
    while (i + kw.len <= s.len) : (i += 1) {
        if (!std.mem.eql(u8, s[i .. i + kw.len], kw)) continue;
        const before_ws = i == 0 or s[i - 1] == ' ' or s[i - 1] == '\t';
        const after = i + kw.len;
        const after_ws = after >= s.len or s[after] == ' ' or s[after] == '\t';
        if (before_ws and after_ws) return i;
    }
    return null;
}

fn matchUseQuotedLine(line: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    const kw = "use";
    if (i + kw.len > line.len) return null;
    if (!std.mem.eql(u8, line[i .. i + kw.len], kw)) return null;
    i += kw.len;
    if (i >= line.len or (line[i] != ' ' and line[i] != '\t')) return null;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    // Skip past `<items> from` if a selective import is present.
    if (findKeyword(line[i..], "from")) |from_off| {
        i += from_off + "from".len;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    }
    if (i >= line.len or line[i] != '"') return null;
    const path_start = i + 1;
    var j = path_start;
    while (j < line.len and line[j] != '"') : (j += 1) {}
    if (j >= line.len) return null;
    const path_end = j;
    var k = j + 1;
    while (k < line.len and (line[k] == ' ' or line[k] == '\t')) k += 1;
    // Trailing content allowed only if it's a comment.
    if (k < line.len and !(k + 1 < line.len and line[k] == '-' and line[k + 1] == '-')) return null;
    return line[path_start..path_end];
}

/// Record `Y → X` for every `X as Y` item in a selective directive
/// `use <items> from "path"`. The whole-module form `use "path"` has
/// no items, so nothing is recorded. Name/alias slices borrow `line`
/// (interned source, stable for the fuse). A repeated alias key takes
/// the last binding.
fn collectAliases(ctx: *Context, line: []const u8, site_offset: u32) ResolveError!void {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    const kw = "use";
    if (i + kw.len > line.len or !std.mem.eql(u8, line[i .. i + kw.len], kw)) return;
    i += kw.len;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    // Aliases only appear in the selective form, ahead of `from`.
    const from_off = findKeyword(line[i..], "from") orelse return;
    const items = line[i .. i + from_off];

    var it = std.mem.splitScalar(u8, items, ',');
    while (it.next()) |raw| {
        const item = std.mem.trim(u8, raw, " \t");
        const as_off = findKeyword(item, "as") orelse continue;
        const name = std.mem.trim(u8, item[0..as_off], " \t");
        const alias = std.mem.trim(u8, item[as_off + "as".len ..], " \t");
        if (name.len == 0 or alias.len == 0) continue;
        const gop = try ctx.import_aliases.getOrPut(ctx.allocator, alias);
        // Re-binding the same alias to the same target is a harmless
        // repeat; to a different one is an ambiguous import.
        if (gop.found_existing and !std.mem.eql(u8, gop.value_ptr.*, name)) {
            try recordError(ctx, .duplicate_alias, site_offset, alias);
        }
        gop.value_ptr.* = name;
    }
}

// ---------- tests ----------

const testing = std.testing;

test "include/matchUseQuotedLine: bare `use math` does not match" {
    try testing.expect(matchUseQuotedLine("use math") == null);
}

test "include/matchUseQuotedLine: `use \"./util\"` returns ./util" {
    try testing.expectEqualStrings("./util", matchUseQuotedLine("use \"./util\"").?);
}

test "include/matchUseQuotedLine: selective `use foo from \"./bar\"`" {
    try testing.expectEqualStrings("./bar", matchUseQuotedLine("use foo from \"./bar\"").?);
}

test "include/matchUseQuotedLine: trailing `--` comment is allowed" {
    try testing.expectEqualStrings("./util", matchUseQuotedLine("use \"./util\"  -- core helpers").?);
}

test "include/matchUseQuotedLine: trailing non-comment garbage rejects" {
    try testing.expect(matchUseQuotedLine("use \"./util\" let x = 0") == null);
}
