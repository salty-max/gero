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
const diagnostics = @import("diagnostics.zig");

/// Run the full `gero asm` flow against `opts.positional()[0]`.
/// Caller owns `arena`; everything we allocate is short-lived.
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
        try term.err("gero asm: missing .gas file path", .{});
        return 2;
    }
    const src_path = positionals[0];

    const t_phase_start_include = std.Io.Timestamp.now(io, .awake);
    var fused = gero.asm_.resolveIncludes(io, arena, src_path) catch |err| {
        try term.err("gero asm: cannot read {s} ({s})", .{ src_path, @errorName(err) });
        return 1;
    };
    defer fused.deinit();
    const t_after_include = std.Io.Timestamp.now(io, .awake);

    // Collect diagnostics across every phase so the user sees the
    // full picture in one run. Include errors that can't be
    // recovered from (no fused source = no parse) short-circuit
    // before parse.
    const style: gero.asm_.Style = if (term.color) .ansi else .plain;
    if (fused.errors.len > 0) {
        try diagnostics.printSingle(stdout, fused.source_map, fused.errors, style);
        try writeFooter(stdout, io, style, t_start, .failed);
        return 3;
    }

    // Parse always returns a tree (statement-level recovery means
    // `Unknown` nodes stand in for failed statements). We run
    // codegen even when parse surfaced errors so codegen-level
    // diagnostics (E001/E003/E004/E005/E014) for the well-formed
    // statements still surface in the same run.
    var pt = try gero.asm_.parse(arena, fused.source);
    defer pt.deinit();
    const t_after_parse = std.Io.Timestamp.now(io, .awake);

    var cg = try gero.asm_.assemble(arena, fused.source, pt, .{});
    defer cg.deinit();
    const t_after_codegen = std.Io.Timestamp.now(io, .awake);

    const had_errors = pt.hasErrors() or cg.hasErrors();
    if (had_errors) {
        try diagnostics.printMerged(arena, stdout, fused.source_map, pt.errors, cg.errors, style);
        try writeFooter(stdout, io, style, t_start, .failed);
        return 3;
    }

    const out_path = try resolveOutputPath(io, arena, src_path, opts.out);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = cg.image }) catch |err| {
        try term.err("gero asm: cannot write {s} ({s})", .{ out_path, @errorName(err) });
        return 1;
    };
    const t_after_write = std.Io.Timestamp.now(io, .awake);

    if (!opts.quiet) {
        const loaded = gero.vm.parseGx(cg.image) catch unreachable; // allow-strict: codegen just emitted these bytes — they're well-formed by construction
        try stdout.print("{s} ({d} bytes, {d} banks, debug: {s})\n", .{
            out_path,
            cg.image.len,
            loaded.header.bank_count,
            if (loaded.header.hasDebugSymbols()) "yes" else "no",
        });
        if (opts.verbose) {
            try writePhaseTimings(stdout, style, .{
                .include = t_phase_start_include.durationTo(t_after_include).nanoseconds,
                .parse = t_after_include.durationTo(t_after_parse).nanoseconds,
                .codegen = t_after_parse.durationTo(t_after_codegen).nanoseconds,
                .write = t_after_codegen.durationTo(t_after_write).nanoseconds,
            });
        }
        try writeFooter(stdout, io, style, t_start, .ok);
    }

    return 0;
}

const PhaseTimings = struct {
    include: i96,
    parse: i96,
    codegen: i96,
    write: i96,
};

fn writePhaseTimings(stdout: *std.Io.Writer, style: gero.asm_.Style, t: PhaseTimings) !void {
    const phases = [_]struct { label: []const u8, ns: i96 }{
        .{ .label = "    include", .ns = t.include },
        .{ .label = "    parse  ", .ns = t.parse },
        .{ .label = "    codegen", .ns = t.codegen },
        .{ .label = "    write  ", .ns = t.write },
    };
    for (phases) |p| {
        try stdout.print("{s}{s}{s} ", .{ style.gutter, p.label, style.reset });
        try writeDuration(stdout, p.ns);
        try stdout.writeByte('\n');
    }
}

/// Whether `gero asm` produced a `.gx` or bailed on errors.
const Outcome = enum { ok, failed };

/// Cargo-style footer with elapsed wall time.
///
/// ```text
///     Finished in 12.3 ms
///     Failed in 4.1 ms
/// ```
fn writeFooter(stdout: *std.Io.Writer, io: std.Io, style: gero.asm_.Style, t_start: std.Io.Timestamp, outcome: Outcome) !void {
    const t_end = std.Io.Timestamp.now(io, .awake);
    const elapsed_ns: i96 = t_start.durationTo(t_end).nanoseconds;
    const label = switch (outcome) {
        .ok => "    Finished in ",
        .failed => "    Failed in ",
    };
    const label_style = switch (outcome) {
        .ok => style.location, // bold — same as path headers
        .failed => style.code, // red — same as [Exxx]
    };
    try stdout.print("{s}{s}{s}", .{ label_style, label, style.reset });
    try writeDuration(stdout, elapsed_ns);
    try stdout.writeByte('\n');
}

fn writeDuration(stdout: *std.Io.Writer, ns: i96) !void {
    const ns_per_ms: i96 = std.time.ns_per_ms;
    const ns_per_s: i96 = std.time.ns_per_s;
    if (ns >= ns_per_s) {
        // safety: caller passes a non-negative duration; the cast
        //         to u64 just lets {d} format unsigned without the
        //         leading-sign business that confuses the spec.
        const whole: u64 = @intCast(@divFloor(ns, ns_per_s));
        const tenths: u64 = @intCast(@divFloor(@mod(ns, ns_per_s), ns_per_ms * 100));
        try stdout.print("{d}.{d} s", .{ whole, tenths });
    } else if (ns >= ns_per_ms) {
        // @as: see above — non-negative ns by construction.
        const whole: u64 = @intCast(@divFloor(ns, ns_per_ms));
        const tenths: u64 = @intCast(@divFloor(@mod(ns, ns_per_ms), 100_000));
        try stdout.print("{d}.{d} ms", .{ whole, tenths });
    } else {
        try stdout.writeAll("< 1 ms");
    }
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
