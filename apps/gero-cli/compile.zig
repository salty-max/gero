const std = @import("std");
const gero = @import("gero");
const build_cache = @import("build_cache.zig");
const cli = @import("cli.zig");
const term_mod = @import("term.zig");
const footer = @import("footer.zig");
const manifest_loader = @import("manifest_loader.zig");

/// Run `gero compile <file.gr>` end-to-end:
/// resolve `use "..."` imports → tokenize → parse → typecheck →
/// codegen → write `.gx`. Diagnostics route through
/// `gero.lang.render.pretty` for caret-style output, grouped by
/// origin file via the include-resolver's `SourceMap`.
pub fn execute(
    io: std.Io,
    arena: std.mem.Allocator,
    opts: cli.Options,
    stdout: *std.Io.Writer,
    term: *term_mod.Term,
) !u8 {
    const t_start = std.Io.Timestamp.now(io, .awake);
    const positionals = opts.positional();
    if (positionals.len < 1) {
        try term.err("gero compile: missing .gr file path", .{});
        return 2;
    }
    const src_path = positionals[0];
    const cargo_style: gero.asm_.Style = if (term.color) .ansi else .plain;

    const image = switch (try compileLang(io, arena, src_path, opts.optimize, "gero compile", stdout, term, t_start, null)) {
        .failed => |code| return code,
        .image => |img| img,
        // Only a cached project build can report this; `gero compile`
        // passes no cache.
        .unchanged => unreachable,
    };

    const out_path = resolveOutputPath(io, arena, term, src_path, opts.out, opts.optimize) catch |err| switch (err) {
        error.ManifestFailed => return 3,
        error.CreateDirFailed => return 1,
        else => |e| return e,
    };
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = image }) catch |err| {
        try term.err("gero compile: cannot write {s} ({s})", .{ out_path, @errorName(err) });
        return 1;
    };

    if (!opts.quiet) {
        try stdout.print("{s} ({d} bytes)\n", .{ out_path, image.len });
        try footer.writeFooter(stdout, io, cargo_style, t_start, .ok);
    }

    return 0;
}

/// Either a compiled `.gx` image (arena-owned, so it outlives the
/// pipeline's own buffers) or an exit code whose diagnostics have
/// already been rendered to `stdout`.
pub const LangResult = union(enum) {
    image: []const u8,
    failed: u8,
    /// Every source is what the cache recorded and the output is still
    /// on disk, so there is nothing to rebuild.
    unchanged,
};

/// Drive `.gr` source at `src_path` through include resolution,
/// tokenize, parse, typecheck, and codegen, rendering diagnostics as
/// it goes. Shared by `gero compile` and `gero build` so both report
/// identically; `cmd` names the caller in host-error messages.
/// Where a project's build cache lives and what it was built for.
/// Absent for one-shot compiles, which have no project to cache under.
pub const CacheContext = struct {
    /// Directory holding the index and fragment files.
    dir: []const u8,
    /// Entry def name — different entries lower different code.
    entry: []const u8,
    /// Optimize mode, for the same reason.
    optimize: []const u8,
    /// Path of the artifact a previous build produced. When every
    /// source still matches the cache and this file is present, the
    /// build has nothing to do.
    output: []const u8,
};

pub fn compileLang(
    io: std.Io,
    arena: std.mem.Allocator,
    src_path: []const u8,
    optimize: cli.Optimize,
    cmd: []const u8,
    stdout: *std.Io.Writer,
    term: *term_mod.Term,
    t_start: std.Io.Timestamp,
    cache: ?CacheContext,
) !LangResult {
    var fused = gero.lang.resolveUseImports(io, arena, src_path) catch |err| {
        try term.err("{s}: cannot read {s} ({s})", .{ cmd, src_path, @errorName(err) });
        return .{ .failed = 1 };
    };

    defer fused.deinit();

    const style: gero.lang.render.Style = if (term.color) .ansi else .none;
    const cargo_style: gero.asm_.Style = if (term.color) .ansi else .plain;

    if (fused.hasErrors()) {
        try renderIncludeErrors(stdout, arena, fused, style);
        try footer.writeFooter(stdout, io, cargo_style, t_start, .failed);
        return .{ .failed = 3 };
    }

    // Nothing past reading the files can differ when every source is
    // what the cache recorded, so a build with an intact artifact stops
    // here rather than reproducing it.
    const loaded: ?build_cache.Cache = if (cache) |cx|
        build_cache.load(io, arena, cx.dir, cx.entry, cx.optimize)
    else
        null;
    if (cache) |cx| {
        if (loaded) |c| {
            if (build_cache.contentUnchanged(c, &fused) and fileExists(io, cx.output)) {
                return .unchanged;
            }
        }
    }

    var stream = gero.lang.tokenize(arena, fused.source) catch |err| {
        try term.err("{s}: tokenizer failure ({s})", .{ cmd, @errorName(err) });
        return .{ .failed = 1 };
    };
    defer stream.deinit();

    // Each module parses from its own tokens (§5); the shared buffer
    // only supplies the bytes their offsets index into.
    var tree = gero.lang.parseAllModules(arena, fused.source, stream, &fused.source_map) catch |err| {
        try term.err("{s}: parser failure ({s})", .{ cmd, @errorName(err) });
        return .{ .failed = 1 };
    };
    defer tree.deinit();

    var pre_check_diags: std.ArrayList(gero.lang.Diagnostic) = .empty;
    for (stream.errors) |e| try appendParseError(arena, &pre_check_diags, e);
    for (tree.errors) |e| try appendParseError(arena, &pre_check_diags, e);

    if (pre_check_diags.items.len > 0) {
        try renderLangDiagnostics(stdout, arena, fused, pre_check_diags.items, style);
        try footer.writeFooter(stdout, io, cargo_style, t_start, .failed);
        return .{ .failed = 3 };
    }

    // What the previous build left behind decides how much of this one
    // has to run: a module whose text and dependencies' interfaces are
    // unchanged keeps its compiled code and never has its bodies walked.
    var statements_of: std.ArrayList([]const gero.lang.ast.Statement) = .empty;
    for (fused.source_map.files.items, 0..) |_, i| {
        var found: []const gero.lang.ast.Statement = &.{};
        for (tree.modules) |m| {
            if (m.file_id == i) found = m.tree.program.statements;
        }
        try statements_of.append(arena, found);
    }

    const build_plan = try build_cache.plan(arena, loaded, &fused, statements_of.items);

    var checked = gero.lang.typecheckGraph(arena, fused.source, &tree.program, &fused.import_aliases, .{
        .source_map = &fused.source_map,
        .imports = fused.imports,
        .skip_bodies = if (cache != null) build_plan.skip else &.{},
        .cached_arities = if (cache != null) build_plan.arities else &.{},
    }) catch |err| {
        try term.err("{s}: typecheck failure ({s})", .{ cmd, @errorName(err) });
        return .{ .failed = 1 };
    };
    defer checked.deinit();

    if (checked.hasErrors()) {
        try renderLangDiagnostics(stdout, arena, fused, checked.diagnostics, style);
        try footer.writeFooter(stdout, io, cargo_style, t_start, .failed);
        return .{ .failed = 4 };
    }

    var compiled = gero.lang.compile(arena, fused.source, &checked, .{
        .optimize = mapOptimize(optimize),
        .import_aliases = &fused.import_aliases,
        .graph = .{ .source_map = &fused.source_map, .imports = fused.imports },
        .emit_fragments = cache != null,
        .cached_fragments = if (cache != null) build_plan.fragments else &.{},
    }) catch |err| switch (err) {
        error.EntryNotFound => {
            try term.err("{s}: no top-level `def main()` — every program needs an entry point", .{cmd});
            return .{ .failed = 4 };
        },
        else => {
            try term.err("{s}: codegen failure ({s})", .{ cmd, @errorName(err) });
            return .{ .failed = 1 };
        },
    };
    defer compiled.deinit();

    if (compiled.hasErrors()) {
        try renderLangDiagnostics(stdout, arena, fused, compiled.diagnostics, style);
        try footer.writeFooter(stdout, io, cargo_style, t_start, .failed);
        return .{ .failed = 4 };
    }

    // Surface non-fatal warnings (e.g. W_DEAD_TEST) even when
    // the build succeeded.
    if (checked.diagnostics.len > 0) try renderLangDiagnostics(stdout, arena, fused, checked.diagnostics, style);
    if (compiled.diagnostics.len > 0) try renderLangDiagnostics(stdout, arena, fused, compiled.diagnostics, style);

    // Record what this build learned. A cache that fails to write only
    // costs the next build the work it could have skipped, so a failure
    // here is not a build failure.
    if (cache) |cx| {
        const requests = try checked.arityRequests(arena);
        build_cache.store(
            io,
            arena,
            cx.dir,
            cx.entry,
            cx.optimize,
            &fused,
            statements_of.items,
            requests,
            compiled.fragments,
        ) catch {};
    }

    // `compiled` owns the image and frees it on return, so hand the
    // caller an arena copy that outlives this frame.
    return .{ .image = try arena.dupe(u8, compiled.image) };
}

fn mapOptimize(cli_opt: cli.Optimize) gero.lang.Optimize {
    return switch (cli_opt) {
        .debug => .debug,
        .release => .release,
        .size => .size,
    };
}

/// Translate a knit lexer / parser `ParseError` into the lang's
/// `Diagnostic` shape so it renders through the same caret path
/// as typecheck / codegen errors.
fn appendParseError(
    arena: std.mem.Allocator,
    out: *std.ArrayList(gero.lang.Diagnostic),
    e: anytype,
) !void {
    // safety: ParseError.index fits in u32 — bounded by file size.
    const idx: u32 = @intCast(e.index);
    try out.append(arena, .{
        .severity = .fatal,
        .code = e.expected orelse "E_SYNTAX_GENERIC",
        .message = try arena.dupe(u8, e.message),
        .span = .{ .start = idx, .end = idx },
    });
}

/// Render lang diagnostics through `gero.lang.render.pretty`,
/// translating each diagnostic's fused-source span back into a
/// per-file local span via the `SourceMap`. Diagnostics group
/// by file so each file's snippets render under its own
/// `--> path:line:col` header.
fn renderLangDiagnostics(
    stdout: *std.Io.Writer,
    arena: std.mem.Allocator,
    fused: gero.lang.FusedSource,
    diags: []const gero.lang.Diagnostic,
    style: gero.lang.render.Style,
) !void {
    // Map file_id → list of locally-spanned diagnostics.
    var per_file: std.AutoHashMapUnmanaged(u16, std.ArrayList(gero.lang.Diagnostic)) = .{};
    defer per_file.deinit(arena);

    for (diags) |d| {
        const lookup = fused.source_map.lookup(d.span.start) orelse continue;
        const file_id = findFileId(fused.source_map, lookup.file) orelse continue;
        const end_local = blk: {
            if (fused.source_map.lookup(d.span.end)) |end_loc| {
                if (std.mem.eql(u8, end_loc.file.path, lookup.file.path)) break :blk end_loc.file_offset;
            }
            // End offset crossed a file boundary — clamp to start.
            break :blk lookup.file_offset;
        };
        var local = d;
        local.span = .{ .start = lookup.file_offset, .end = end_local };
        if (d.secondary.len > 0) {
            local.secondary = try translateSecondary(arena, fused.source_map, lookup.file, d.secondary);
        }
        const gop = try per_file.getOrPut(arena, file_id);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, local);
    }

    var files: std.ArrayList(gero.lang.render.FileDiagnostics) = .empty;
    var it = per_file.iterator();
    while (it.next()) |entry| {
        const file = fused.source_map.files.items[entry.key_ptr.*];
        try files.append(arena, .{
            .path = file.path,
            .source = file.content,
            .diagnostics = entry.value_ptr.items,
        });
    }

    try gero.lang.render.pretty(stdout, files.items, style);
}

fn findFileId(map: gero.lang.SourceMap, file: gero.lang.FileInfo) ?u16 {
    for (map.files.items, 0..) |f, i| {
        if (std.mem.eql(u8, f.path, file.path)) return @intCast(i);
    }
    return null;
}

fn translateSecondary(
    arena: std.mem.Allocator,
    map: gero.lang.SourceMap,
    primary_file: gero.lang.FileInfo,
    secondary: []const gero.lang.SpanLabel,
) ![]gero.lang.SpanLabel {
    var kept: std.ArrayList(gero.lang.SpanLabel) = .empty;
    for (secondary) |s| {
        const lookup = map.lookup(s.span.start) orelse continue;
        // Only keep secondaries that land in the same file as
        // the primary span — cross-file secondaries don't render
        // cleanly with the current renderer.
        if (!std.mem.eql(u8, lookup.file.path, primary_file.path)) continue;
        const end_local: u32 = blk: {
            if (map.lookup(s.span.end)) |e| {
                if (std.mem.eql(u8, e.file.path, primary_file.path)) break :blk e.file_offset;
            }
            break :blk lookup.file_offset;
        };
        try kept.append(arena, .{
            .span = .{ .start = lookup.file_offset, .end = end_local },
            .message = s.message,
            .decoration = s.decoration,
        });
    }
    return try kept.toOwnedSlice(arena);
}

fn renderIncludeErrors(
    stdout: *std.Io.Writer,
    arena: std.mem.Allocator,
    fused: gero.lang.FusedSource,
    style: gero.lang.render.Style,
) !void {
    var diags_list: std.ArrayList(gero.lang.Diagnostic) = .empty;
    for (fused.errors) |e| {
        const code = gero.lang.includeErrorCode(e.kind);
        const msg = try gero.lang.includeErrorMessage(arena, e.kind, e.requested);
        try diags_list.append(arena, .{
            .severity = .fatal,
            .code = code,
            .message = msg,
            .span = .{ .start = e.site_offset, .end = e.site_offset },
        });
    }
    try renderLangDiagnostics(stdout, arena, fused, diags_list.items, style);
}

/// Resolve the `.gx` output path. Precedence:
/// 1. `--out <path>` — explicit user flag wins.
/// 2. `gero.toml` in the cwd's ancestor chain — `<root>/<[build].out>/<optimize>/<basename>.gx`.
/// 3. Sibling default — next to the source.
///
/// Returns `error.ManifestFailed` (after printing via `term`) when
/// a manifest exists but is unreadable / malformed — silently
/// falling back to the sibling default in that case would mask the
/// real configuration error.
fn resolveOutputPath(
    io: std.Io,
    arena: std.mem.Allocator,
    term: *term_mod.Term,
    src_path: []const u8,
    out_opt: ?[]const u8,
    cli_optimize: cli.Optimize,
) ![]const u8 {
    const base = try gxBasename(arena, src_path);
    if (out_opt) |out| {
        if (isDirLike(io, out)) {
            return std.fs.path.join(arena, &.{ out, base });
        }
        return arena.dupe(u8, out);
    }
    switch (try manifest_loader.load(io, arena, term, "gero compile")) {
        .ok => |loaded| {
            var manifest = loaded.manifest;
            defer manifest.deinit(arena);
            const out_root = try manifest_loader.joinUnderRoot(arena, loaded.project_root, manifest.build.out);
            // CLI's `--optimize` overrides the manifest's
            // `[build].optimize` — explicit user intent at the
            // call site beats the project default.
            const opt_name: []const u8 = switch (cli_optimize) {
                .debug => "debug",
                .release => "release",
                .size => "size",
            };
            const out_dir = try std.fs.path.join(arena, &.{ out_root, opt_name });
            // Create the per-profile dir up front. `createDirPath`
            // is idempotent and only walked for the manifest layout
            // — `--out` paths stay the user's responsibility.
            std.Io.Dir.cwd().createDirPath(io, out_dir) catch |err| {
                try term.err("gero compile: cannot create {s} ({s})", .{ out_dir, @errorName(err) });
                return error.CreateDirFailed;
            };
            return try std.fs.path.join(arena, &.{ out_dir, base });
        },
        .not_found => {},
        .failed => return error.ManifestFailed,
    }
    const dir = std.fs.path.dirname(src_path) orelse "";
    if (dir.len == 0) return base;
    return std.fs.path.join(arena, &.{ dir, base });
}

fn gxBasename(arena: std.mem.Allocator, src_path: []const u8) ![]const u8 {
    const file = std.fs.path.basename(src_path);
    if (std.mem.endsWith(u8, file, ".gx")) return arena.dupe(u8, file);
    const stem = if (std.mem.lastIndexOfScalar(u8, file, '.')) |dot| file[0..dot] else file;
    return std.fmt.allocPrint(arena, "{s}.gx", .{stem});
}

fn isDirLike(io: std.Io, path: []const u8) bool {
    if (endsWithSep(path)) return true;
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .directory;
}

fn endsWithSep(path: []const u8) bool {
    return path.len > 0 and (path[path.len - 1] == '/' or path[path.len - 1] == std.fs.path.sep);
}

// ---------- tests ----------

const testing = std.testing;

test "compile: gxBasename swaps extension" {
    const out = try gxBasename(testing.allocator, "src/main.gr");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("main.gx", out);
}

test "compile: gxBasename keeps `.gx` verbatim" {
    const out = try gxBasename(testing.allocator, "out/main.gx");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("main.gx", out);
}

test "compile: gxBasename appends `.gx` when no extension" {
    const out = try gxBasename(testing.allocator, "scratch");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("scratch.gx", out);
}

/// `true` when `path` names a file that can be opened.
fn fileExists(io: std.Io, path: []const u8) bool {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}
