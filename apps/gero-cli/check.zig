/// `gero check` — validate one or more `.gas` sources through the
/// full assembler pipeline (resolveIncludes → parse → codegen)
/// without writing any `.gx`. Positional args can be individual
/// files or directories (walked recursively for `*.gas`). Editor-
/// LSP-style use case + CI gate.
///
/// Exit codes per cli.md §3.9 + §5:
///   - `0` clean (every file passed)
///   - `1` host IO problem (file missing, unreadable, etc.)
///   - `2` usage error (missing positional)
///   - `4` ≥ 1 diagnostic from any file
///
/// `.gr` positional paths dispatch to a "not yet implemented" stub
/// until the gero-lang front-end lands in v0.3 (#7). Directory
/// walks ignore `.gr` extensions entirely until then.
const std = @import("std");
const gero = @import("gero");
const cli = @import("cli.zig");
const term_mod = @import("term.zig");
const diagnostics = @import("diagnostics.zig");
const footer = @import("footer.zig");

/// Drive `gero check` end-to-end against `opts.positional()`.
/// Caller owns `arena`; every allocation is short-lived.
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
        try term.err("gero check: missing source file or directory path", .{});
        return 2;
    }

    const style: gero.asm_.Style = if (term.color) .ansi else .plain;

    // Resolve every positional into a flat list of `.gas` files.
    // `.gr` positionals short-circuit with the v0.3 stub before
    // any walking happens.
    var files: std.ArrayList([]const u8) = .empty;
    for (positionals) |path| {
        if (std.mem.endsWith(u8, path, ".gr")) {
            try term.err("gero check: .gr support lands in v0.3 (gero-lang front-end)", .{});
            return 1;
        }
        try collectGasFiles(io, arena, term, path, &files);
    }

    if (files.items.len == 0) {
        try term.err("gero check: no .gas files found in the given paths", .{});
        return 1;
    }

    const single = files.items.len == 1;

    var pass: usize = 0;
    var fail: usize = 0;
    for (files.items) |path| {
        const ok = try checkOne(io, arena, opts, stdout, term, style, path, single);
        if (ok) pass += 1 else fail += 1;
    }

    // Multi-file summary line — single-file mode already shows the
    // rich `✓ <path> (N bytes, M banks)` line per file, no need.
    if (!single and !opts.quiet) {
        const pass_noun: []const u8 = if (pass == 1) "file" else "files";
        const fail_noun: []const u8 = if (fail == 1) "failure" else "failures";
        try stdout.print(
            "\n{s}check:{s} {d} {s} passed, {d} {s}\n",
            .{ style.location, style.reset, pass, pass_noun, fail, fail_noun },
        );
    }
    if (!opts.quiet) {
        try footer.writeFooter(stdout, io, style, t_start, if (fail > 0) .failed else .ok);
    }
    return if (fail > 0) 4 else 0;
}

/// Resolve `path` into 0+ `.gas` entries appended to `out`. A
/// directory is walked recursively; a regular file is appended as-
/// is. Anything else (broken link, special file) emits a host IO
/// error and propagates up.
fn collectGasFiles(
    io: std.Io,
    arena: std.mem.Allocator,
    term: *term_mod.Term,
    path: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| {
        try term.err("gero check: cannot stat {s} ({s})", .{ path, @errorName(err) });
        return error.OutOfMemory; // funnel to the only allocator error caller handles
    };
    if (stat.kind == .directory) {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
            try term.err("gero check: cannot open dir {s} ({s})", .{ path, @errorName(err) });
            return error.OutOfMemory;
        };
        defer dir.close(io);
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".gas")) continue;
            const full = try std.fs.path.join(arena, &.{ path, entry.path });
            try out.append(arena, full);
        }
    } else if (stat.kind == .file) {
        try out.append(arena, try arena.dupe(u8, path));
    } else {
        try term.err("gero check: {s} is neither a file nor a directory", .{path});
        return error.OutOfMemory;
    }
}

/// Validate one `.gas` file. Returns `true` on clean check,
/// `false` if any diagnostic was emitted. `single_mode` controls
/// the per-file output verbosity: rich `(N bytes, M banks)` +
/// optional per-phase timings when `true`, brief `✓ <path>` /
/// diagnostic when `false`.
fn checkOne(
    io: std.Io,
    arena: std.mem.Allocator,
    opts: cli.Options,
    stdout: *std.Io.Writer,
    term: *term_mod.Term,
    style: gero.asm_.Style,
    src_path: []const u8,
    single_mode: bool,
) !bool {
    const t_phase_start_include = std.Io.Timestamp.now(io, .awake);
    var fused = gero.asm_.resolveIncludes(io, arena, src_path) catch |err| {
        try term.err("gero check: cannot read {s} ({s})", .{ src_path, @errorName(err) });
        return false;
    };
    defer fused.deinit();
    const t_after_include = std.Io.Timestamp.now(io, .awake);

    if (fused.errors.len > 0) {
        try stdout.print("{s}✗{s} {s}\n", .{ style.code, style.reset, src_path });
        try diagnostics.printSingle(stdout, fused.source_map, fused.errors, style);
        return false;
    }

    var pt = try gero.asm_.parse(arena, fused.source);
    defer pt.deinit();
    const t_after_parse = std.Io.Timestamp.now(io, .awake);

    var cg = try gero.asm_.assemble(arena, fused.source, pt, .{});
    defer cg.deinit();
    const t_after_codegen = std.Io.Timestamp.now(io, .awake);

    if (pt.hasErrors() or cg.hasErrors()) {
        try stdout.print("{s}✗{s} {s}\n", .{ style.code, style.reset, src_path });
        try diagnostics.printMerged(arena, stdout, fused.source_map, pt.errors, cg.errors, style);
        return false;
    }

    if (!opts.quiet) {
        if (single_mode) {
            const loaded = gero.vm.parseGx(cg.image) catch unreachable; // allow-strict: codegen just produced these bytes
            try stdout.print("{s}✓ {s}{s}  ({d} bytes, {d} banks)\n", .{
                style.location,
                src_path,
                style.reset,
                cg.image.len,
                loaded.header.bank_count,
            });
            if (opts.verbose) {
                try writePhaseTimings(stdout, style, .{
                    .include = t_phase_start_include.durationTo(t_after_include).nanoseconds,
                    .parse = t_after_include.durationTo(t_after_parse).nanoseconds,
                    .codegen = t_after_parse.durationTo(t_after_codegen).nanoseconds,
                });
            }
        } else {
            try stdout.print("{s}✓{s} {s}\n", .{ style.location, style.reset, src_path });
        }
    }
    return true;
}

const PhaseTimings = struct {
    include: i96,
    parse: i96,
    codegen: i96,
};

fn writePhaseTimings(
    stdout: *std.Io.Writer,
    style: gero.asm_.Style,
    t: PhaseTimings,
) std.Io.Writer.Error!void {
    const phases = [_]struct { label: []const u8, ns: i96 }{
        .{ .label = "    include", .ns = t.include },
        .{ .label = "    parse  ", .ns = t.parse },
        .{ .label = "    codegen", .ns = t.codegen },
    };
    for (phases) |p| {
        try stdout.print("{s}{s}{s} ", .{ style.gutter, p.label, style.reset });
        try footer.writeDuration(stdout, p.ns);
        try stdout.writeByte('\n');
    }
}
