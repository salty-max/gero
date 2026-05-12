/// `gero asm` — drive the assembler from a `.gas` source file
/// down to a `.gx` image on disk. Includes are resolved through
/// `gero.asm_.resolveIncludes`; parse + codegen run end-to-end;
/// diagnostics print with caret snippets via `formatPretty`.
///
/// Exit code per cli.md §3.1: `0` on success, `3` on parse /
/// assembly error, `1` on host IO problems.
const std = @import("std");
const gero = @import("gero");
const cli = @import("cli.zig");
const term_mod = @import("term.zig");

/// Run the full `gero asm` flow against `opts.positional()[0]`.
/// Caller owns `arena`; everything we allocate is short-lived.
pub fn execute(
    io: std.Io,
    arena: std.mem.Allocator,
    opts: cli.Options,
    stdout: *std.Io.Writer,
    term: *term_mod.Term,
) !u8 {
    const positionals = opts.positional();
    if (positionals.len < 1) {
        try term.err("gero asm: missing .gas file path", .{});
        return 2;
    }
    const src_path = positionals[0];

    var fused = gero.asm_.resolveIncludes(io, arena, src_path) catch |err| {
        try term.err("gero asm: cannot read {s} ({s})", .{ src_path, @errorName(err) });
        return 1;
    };
    defer fused.deinit();

    // Collect diagnostics across every phase so the user sees the
    // full picture in one run. Include errors that can't be
    // recovered from (no fused source = no parse) short-circuit
    // before parse.
    const style: gero.asm_.Style = if (term.color) .ansi else .plain;
    if (fused.errors.len > 0) {
        try printDiagnostics(stdout, fused.source_map, fused.errors, style);
        return 3;
    }

    // Parse always returns a tree (statement-level recovery means
    // `Unknown` nodes stand in for failed statements). We run
    // codegen even when parse surfaced errors so codegen-level
    // diagnostics (E001/E003/E004/E005/E014) for the well-formed
    // statements still surface in the same run.
    var pt = try gero.asm_.parse(arena, fused.source);
    defer pt.deinit();

    var cg = try gero.asm_.assemble(arena, fused.source, pt, .{});
    defer cg.deinit();

    const had_errors = pt.hasErrors() or cg.hasErrors();
    if (had_errors) {
        try printAllDiagnostics(arena, stdout, fused.source_map, pt.errors, cg.errors, style);
        return 3;
    }

    const out_path = try resolveOutputPath(io, arena, src_path, opts.out);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = cg.image }) catch |err| {
        try term.err("gero asm: cannot write {s} ({s})", .{ out_path, @errorName(err) });
        return 1;
    };

    if (!opts.quiet) {
        const loaded = gero.vm.parseGx(cg.image) catch unreachable; // allow-strict: codegen just emitted these bytes — they're well-formed by construction
        try stdout.print("{s} ({d} bytes, {d} banks, debug: {s})\n", .{
            out_path,
            cg.image.len,
            loaded.header.bank_count,
            if (loaded.header.hasDebugSymbols()) "yes" else "no",
        });
    }

    return 0;
}

/// Pretty-print every diagnostic against the fused-source map.
fn printDiagnostics(
    stdout: *std.Io.Writer,
    source_map: gero.asm_.SourceMap,
    errors: []const gero.asm_.Diagnostic,
    style: gero.asm_.Style,
) !void {
    for (errors) |d| try gero.asm_.formatPretty(stdout, source_map, d, style);
}

/// Augment each diagnostic with its resolved file path so we can
/// group + sort by (path, fused_index) — diagnostics from the same
/// file land in one section, sorted by source position.
const KeyedDiag = struct {
    diag: gero.asm_.Diagnostic,
    path: []const u8,
};

/// Merge parse + codegen diagnostics, group by file, sort each
/// group by fused-source offset, print a summary header + one
/// section per file. `<unknown>` (rare — source-map miss) groups
/// last under a single bucket.
fn printAllDiagnostics(
    arena: std.mem.Allocator,
    stdout: *std.Io.Writer,
    source_map: gero.asm_.SourceMap,
    parse_errors: []const gero.asm_.Diagnostic,
    codegen_errors: []const gero.asm_.Diagnostic,
    style: gero.asm_.Style,
) !void {
    const total = parse_errors.len + codegen_errors.len;
    const keyed = try arena.alloc(KeyedDiag, total);
    for (parse_errors, 0..) |d, i| keyed[i] = .{ .diag = d, .path = pathOf(source_map, d) };
    for (codegen_errors, 0..) |d, j| keyed[parse_errors.len + j] = .{ .diag = d, .path = pathOf(source_map, d) };
    std.mem.sort(KeyedDiag, keyed, {}, byPathThenIndex);

    // Count distinct files for the summary header.
    var file_count: usize = 0;
    var prev_path: []const u8 = "";
    for (keyed) |k| {
        if (!std.mem.eql(u8, k.path, prev_path)) {
            file_count += 1;
            prev_path = k.path;
        }
    }
    try writeSummaryHeader(stdout, style, total, file_count);

    // Emit per-file sections: blank line + `<path>:` header for
    // each new file, then each diagnostic body (no path prefix).
    prev_path = "";
    for (keyed) |k| {
        if (!std.mem.eql(u8, k.path, prev_path)) {
            try stdout.writeByte('\n');
            try stdout.print("{s}{s}{s}\n", .{ style.location, k.path, style.reset });
            prev_path = k.path;
        }
        try gero.asm_.formatPrettyBody(stdout, source_map, k.diag, style);
    }
}

fn writeSummaryHeader(stdout: *std.Io.Writer, style: gero.asm_.Style, errors: usize, files: usize) !void {
    const error_noun: []const u8 = if (errors == 1) "error" else "errors";
    const file_noun: []const u8 = if (files == 1) "file" else "files";
    // Reuse Style.code for the count label so it pops in red like
    // the per-line [Exxx] markers.
    try stdout.print("{s}{d} {s}{s} in {d} {s}\n", .{ style.code, errors, error_noun, style.reset, files, file_noun });
}

fn pathOf(source_map: gero.asm_.SourceMap, d: gero.asm_.Diagnostic) []const u8 {
    // @as: ParseError indexes fit in u32 — bounded by max_file_size (16 MiB).
    const offset: u32 = @as(u32, @intCast(d.parse_error.index));
    if (source_map.lookup(offset)) |loc| return loc.file.path;
    return "<unknown>";
}

fn byPathThenIndex(_: void, a: KeyedDiag, b: KeyedDiag) bool {
    const path_cmp = std.mem.order(u8, a.path, b.path);
    if (path_cmp != .eq) return path_cmp == .lt;
    return a.diag.parse_error.index < b.diag.parse_error.index;
}

/// Resolve the `.gx` output path from `--out` plus the source.
/// `--out` may be unset (defaults to `<basename>.gx` next to the
/// source), an existing directory (`<dir>/<basename>.gx`), or a
/// concrete file path (used verbatim, duped into `arena`).
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

/// `foo/bar.gas` → owned `"bar.gx"`. If the input already ends
/// in `.gx` we keep its basename; otherwise we strip whatever
/// extension is there and append `.gx`.
fn gxBasename(arena: std.mem.Allocator, src_path: []const u8) ![]const u8 {
    const file = std.fs.path.basename(src_path);
    if (std.mem.endsWith(u8, file, ".gx")) return arena.dupe(u8, file);
    const stem = if (std.mem.lastIndexOfScalar(u8, file, '.')) |dot| file[0..dot] else file;
    return std.fmt.allocPrint(arena, "{s}.gx", .{stem});
}

/// True when `path` resolves to a directory on disk, or syntactically
/// ends with a path separator (covers the `-o build/` shape even
/// when `build/` doesn't exist yet — though we don't auto-create).
fn isDirLike(io: std.Io, path: []const u8) bool {
    if (endsWithSep(path)) return true;
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .directory;
}

/// Trailing-separator check pulled out for unit testability — the
/// stat path needs real IO so we can't cover it in pure tests.
fn endsWithSep(path: []const u8) bool {
    return path.len > 0 and (path[path.len - 1] == '/' or path[path.len - 1] == std.fs.path.sep);
}

// ---------- tests ----------

const testing = std.testing;

test "asm: gxBasename drops directory + swaps extension" {
    const out = try gxBasename(testing.allocator, "src/foo.gas");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("foo.gx", out);
}

test "asm: gxBasename keeps an existing .gx basename verbatim" {
    const out = try gxBasename(testing.allocator, "build/foo.gx");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("foo.gx", out);
}

test "asm: gxBasename appends .gx when no extension is present" {
    const out = try gxBasename(testing.allocator, "noext");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("noext.gx", out);
}

test "asm: endsWithSep recognizes trailing slash" {
    try testing.expect(endsWithSep("build/"));
    try testing.expect(!endsWithSep("build"));
    try testing.expect(!endsWithSep(""));
}
