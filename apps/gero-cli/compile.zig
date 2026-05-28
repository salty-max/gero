const std = @import("std");
const gero = @import("gero");
const cli = @import("cli.zig");
const term_mod = @import("term.zig");
const footer = @import("footer.zig");

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

    var fused = gero.lang.resolveUseImports(io, arena, src_path) catch |err| {
        try term.err("gero compile: cannot read {s} ({s})", .{ src_path, @errorName(err) });
        return 1;
    };
    defer fused.deinit();

    const style: gero.lang.render.Style = if (term.color) .ansi else .none;
    const cargo_style: gero.asm_.Style = if (term.color) .ansi else .plain;

    if (fused.hasErrors()) {
        try renderIncludeErrors(stdout, arena, fused, style);
        try footer.writeFooter(stdout, io, cargo_style, t_start, .failed);
        return 3;
    }

    var stream = gero.lang.tokenize(arena, fused.source) catch |err| {
        try term.err("gero compile: tokenizer failure ({s})", .{@errorName(err)});
        return 1;
    };
    defer stream.deinit();

    var tree = gero.lang.parse(arena, fused.source, stream) catch |err| {
        try term.err("gero compile: parser failure ({s})", .{@errorName(err)});
        return 1;
    };
    defer tree.deinit();

    var pre_check_diags: std.ArrayList(gero.lang.Diagnostic) = .empty;
    for (stream.errors) |e| try appendParseError(arena, &pre_check_diags, e);
    for (tree.errors) |e| try appendParseError(arena, &pre_check_diags, e);

    if (pre_check_diags.items.len > 0) {
        try renderLangDiagnostics(stdout, arena, fused, pre_check_diags.items, style);
        try footer.writeFooter(stdout, io, cargo_style, t_start, .failed);
        return 3;
    }

    var checked = gero.lang.typecheck(arena, fused.source, &tree.program) catch |err| {
        try term.err("gero compile: typecheck failure ({s})", .{@errorName(err)});
        return 1;
    };
    defer checked.deinit();

    if (checked.hasErrors()) {
        try renderLangDiagnostics(stdout, arena, fused, checked.diagnostics, style);
        try footer.writeFooter(stdout, io, cargo_style, t_start, .failed);
        return 4;
    }

    var compiled = gero.lang.compile(arena, fused.source, &checked, .{
        .optimize = mapOptimize(opts.optimize),
    }) catch |err| switch (err) {
        error.EntryNotFound => {
            try term.err("gero compile: no top-level `def main()` — every program needs an entry point", .{});
            return 4;
        },
        else => {
            try term.err("gero compile: codegen failure ({s})", .{@errorName(err)});
            return 1;
        },
    };
    defer compiled.deinit();

    if (compiled.hasErrors()) {
        try renderLangDiagnostics(stdout, arena, fused, compiled.diagnostics, style);
        try footer.writeFooter(stdout, io, cargo_style, t_start, .failed);
        return 4;
    }

    // Surface non-fatal warnings (e.g. W_DEAD_TEST) even when
    // the build succeeded.
    if (checked.diagnostics.len > 0) try renderLangDiagnostics(stdout, arena, fused, checked.diagnostics, style);
    if (compiled.diagnostics.len > 0) try renderLangDiagnostics(stdout, arena, fused, compiled.diagnostics, style);

    const out_path = try resolveOutputPath(io, arena, src_path, opts.out);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = compiled.image }) catch |err| {
        try term.err("gero compile: cannot write {s} ({s})", .{ out_path, @errorName(err) });
        return 1;
    };

    if (!opts.quiet) {
        try stdout.print("{s} ({d} bytes)\n", .{ out_path, compiled.image.len });
        try footer.writeFooter(stdout, io, cargo_style, t_start, .ok);
    }

    return 0;
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
        const code: []const u8 = switch (e.kind) {
            .cycle => "E_USE_CYCLE",
            .depth_exceeded => "E_USE_DEPTH",
            .not_found => "E_USE_NOT_FOUND",
        };
        const msg = switch (e.kind) {
            .cycle => try std.fmt.allocPrint(arena, "`use` cycle detected on `{s}`", .{e.requested}),
            .depth_exceeded => try std.fmt.allocPrint(arena, "`use` depth exceeds 32 on `{s}` — likely runaway recursion", .{e.requested}),
            .not_found => try std.fmt.allocPrint(arena, "`use` target file not found: `{s}`", .{e.requested}),
        };
        try diags_list.append(arena, .{
            .severity = .fatal,
            .code = code,
            .message = msg,
            .span = .{ .start = e.site_offset, .end = e.site_offset },
        });
    }
    try renderLangDiagnostics(stdout, arena, fused, diags_list.items, style);
}

/// Resolve the `.gx` output path from `--out` plus the source.
fn resolveOutputPath(
    io: std.Io,
    arena: std.mem.Allocator,
    src_path: []const u8,
    out_opt: ?[]const u8,
) ![]const u8 {
    const base = try gxBasename(arena, src_path);
    if (out_opt) |out| {
        if (isDirLike(io, out)) {
            return std.fs.path.join(arena, &.{ out, base });
        }
        return arena.dupe(u8, out);
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
