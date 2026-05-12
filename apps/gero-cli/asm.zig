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

    if (fused.errors.len > 0) {
        try printDiagnostics(stdout, fused.source_map, fused.errors);
        return 3;
    }

    var pt = try gero.asm_.parse(arena, fused.source);
    defer pt.deinit();
    if (pt.hasErrors()) {
        try printDiagnostics(stdout, fused.source_map, pt.errors);
        return 3;
    }

    var cg = try gero.asm_.assemble(arena, fused.source, pt, .{});
    defer cg.deinit();
    if (cg.hasErrors()) {
        try printDiagnostics(stdout, fused.source_map, cg.errors);
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
) !void {
    for (errors) |d| try gero.asm_.formatPretty(stdout, source_map, d);
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
