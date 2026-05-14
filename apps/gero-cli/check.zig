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
const manifest_loader = @import("manifest_loader.zig");

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
    const style: gero.asm_.Style = if (term.color) .ansi else .plain;

    var files: std.ArrayList([]const u8) = .empty;
    if (positionals.len == 0) {
        // Project-aware fallback: load gero.toml from cwd or any
        // ancestor and use [build].entry + [test].include as the
        // implicit file list. No manifest → usage error (exit 2)
        // since we have nothing to check.
        const outcome = try manifest_loader.load(io, arena, term, "gero check");
        switch (outcome) {
            .not_found => {
                try term.err("gero check: missing source file or directory path (or run inside a gero project)", .{});
                return 2;
            },
            .failed => return 1,
            .ok => |loaded| {
                var loaded_mut = loaded;
                defer loaded_mut.deinit(arena);
                const entry_path = try manifest_loader.joinUnderRoot(arena, loaded.project_root, loaded.manifest.build.entry);
                try files.append(arena, entry_path);
                manifest_loader.expandIncludes(io, arena, term, "gero check", loaded.project_root, loaded.manifest.test_.include, &files) catch |err| switch (err) {
                    error.LoadFailed => return 1,
                    else => |e| return e,
                };
            },
        }
    } else {
        for (positionals) |path| {
            if (std.mem.endsWith(u8, path, ".gr")) {
                try term.err("gero check: .gr support lands in v0.3 (gero-lang front-end)", .{});
                return 1;
            }
            try collectGasFiles(io, arena, term, path, &files);
        }
    }

    if (files.items.len == 0) {
        try term.err("gero check: no .gas files found in the given paths", .{});
        return 1;
    }

    const single = files.items.len == 1;

    // Pass 1: validate each file. Print per-file ✓ for successes
    // as we go; accumulate failures with their diagnostic context
    // so Pass 2 can render one merged report at the end.
    //
    // Resources allocated through `arena` (FusedSource buffers,
    // ParseTree slices, Codegen image) stay live until the arena
    // resets, so the failures collected here keep their source-map
    // + diagnostic references valid across the loop.
    var pass: usize = 0;
    var failures: std.ArrayList(FileEntry) = .empty;
    for (files.items) |path| {
        const t_phase_start_include = std.Io.Timestamp.now(io, .awake);
        const fused = gero.asm_.resolveIncludes(io, arena, path) catch |err| {
            try term.err("gero check: cannot read {s} ({s})", .{ path, @errorName(err) });
            // Synthesize a single-diagnostic failure so the merged
            // report has something to render. Skipping the failure
            // would mis-count totals.
            try failures.append(arena, .{ .path = path, .info = .read_error });
            continue;
        };
        const t_after_include = std.Io.Timestamp.now(io, .awake);

        if (fused.errors.len > 0) {
            try failures.append(arena, .{
                .path = path,
                .info = .{ .from_pipeline = .{
                    .source_map = fused.source_map,
                    .parse_errors = fused.errors,
                    .codegen_errors = &.{},
                } },
            });
            continue;
        }

        var pt = try gero.asm_.parse(arena, fused.source);
        const t_after_parse = std.Io.Timestamp.now(io, .awake);
        var cg = try gero.asm_.assemble(arena, fused.source, pt, .{});
        const t_after_codegen = std.Io.Timestamp.now(io, .awake);

        if (pt.hasErrors() or cg.hasErrors()) {
            try failures.append(arena, .{
                .path = path,
                .info = .{ .from_pipeline = .{
                    .source_map = fused.source_map,
                    .parse_errors = pt.errors,
                    .codegen_errors = cg.errors,
                } },
            });
            continue;
        }

        pass += 1;
        if (!opts.quiet) {
            try printPass(stdout, style, path, cg, single, opts.verbose, .{
                .include = t_phase_start_include.durationTo(t_after_include).nanoseconds,
                .parse = t_after_include.durationTo(t_after_parse).nanoseconds,
                .codegen = t_after_parse.durationTo(t_after_codegen).nanoseconds,
            });
        }
    }

    // Pass 2: render the merged diagnostic report (if any failure).
    if (failures.items.len > 0) {
        // Read errors render as plain term.err lines (no source-
        // map context to caret-format), so split them off first.
        var pipeline_failures: std.ArrayList(diagnostics.FileFailure) = .empty;
        for (failures.items) |f| switch (f.info) {
            .read_error => {}, // already reported via term.err
            .from_pipeline => |pf| try pipeline_failures.append(arena, pf),
        };
        if (pipeline_failures.items.len > 0) {
            // Separator between the per-file ✓ section (if any
            // success printed above) and the diagnostic block.
            if (!single and !opts.quiet and pass > 0) try stdout.writeByte('\n');
            try diagnostics.printAllFailures(arena, stdout, style, pipeline_failures.items);
        }
    }

    const fail = failures.items.len;
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

/// A per-file failure entry: either a host-IO problem (already
/// surfaced via `term.err`) or a pipeline-level diagnostic set
/// with its source-map context.
const FileEntry = struct {
    path: []const u8,
    info: union(enum) {
        read_error,
        from_pipeline: diagnostics.FileFailure,
    },
};

const PhaseTimings = struct {
    include: i96,
    parse: i96,
    codegen: i96,
};

/// `✓ <path>` line on success. Single-file mode adds the `gero asm`-
/// style stats (`(N bytes, M banks)`) and optional verbose phase
/// timings; multi-file mode keeps it brief so the per-file output
/// stays scannable.
fn printPass(
    stdout: *std.Io.Writer,
    style: gero.asm_.Style,
    src_path: []const u8,
    cg: gero.asm_.Codegen,
    single_mode: bool,
    verbose: bool,
    t: PhaseTimings,
) std.Io.Writer.Error!void {
    if (single_mode) {
        const loaded = gero.vm.parseGx(cg.image) catch unreachable; // allow-strict: codegen just produced these bytes
        try stdout.print("{s}✓ {s}{s}  ({d} bytes, {d} banks)\n", .{
            style.location,
            src_path,
            style.reset,
            cg.image.len,
            loaded.header.bank_count,
        });
        if (verbose) {
            try writePhaseTimings(stdout, style, t);
        }
    } else {
        try stdout.print("{s}✓{s} {s}\n", .{ style.location, style.reset, src_path });
    }
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
        return error.OutOfMemory;
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
