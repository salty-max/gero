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
/// until the gero-lang front-end ships. Directory walks ignore
/// `.gr` extensions entirely until then.
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
            try collectSourceFiles(io, arena, term, path, &files);
        }
    }

    if (files.items.len == 0) {
        try term.err("gero check: no .gas or .gr files found in the given paths", .{});
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
    //
    // JSON-format mode suppresses all per-file output during the
    // loop (✓ lines, read-error stderr) and emits a single JSON
    // object after the loop. Host-IO failures get captured as
    // ReadErrorEntry rows so they show up in the JSON.
    const json_mode = opts.format == .json;
    var read_errors: std.ArrayList(diagnostics.ReadErrorEntry) = .empty;
    var pass: usize = 0;
    var failures: std.ArrayList(FileEntry) = .empty;
    var gr_failures: std.ArrayList(GrFailure) = .empty;
    for (files.items) |path| {
        // `.gr` files route through the gero-lang pipeline. Failures
        // collect into `gr_failures` and render via
        // `gero.lang.render.pretty` after the loop.
        if (std.mem.endsWith(u8, path, ".gr")) {
            const res = try checkOneGr(io, arena, path);
            if (res.diagnostics.len == 0 and res.parse_errors.len == 0 and !res.read_error) {
                pass += 1;
                if (!opts.quiet and !json_mode) try printPassGr(stdout, style, path, single);
            } else if (res.read_error) {
                if (!json_mode) try term.err("gero check: cannot read {s}", .{path});
                try failures.append(arena, .{ .path = path, .info = .read_error });
            } else {
                try gr_failures.append(arena, .{ .path = path, .source = res.source, .parse_errors = res.parse_errors, .diagnostics = res.diagnostics });
            }
            continue;
        }
        const t_phase_start_include = std.Io.Timestamp.now(io, .awake);
        const fused = gero.asm_.resolveIncludes(io, arena, path) catch |err| {
            const err_name = @errorName(err);
            if (json_mode) {
                const msg = try std.fmt.allocPrint(arena, "cannot read ({s})", .{err_name});
                try read_errors.append(arena, .{ .path = path, .message = msg });
            } else {
                try term.err("gero check: cannot read {s} ({s})", .{ path, err_name });
            }
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
        if (!opts.quiet and !json_mode) {
            try printPass(stdout, style, path, cg, single, opts.verbose, .{
                .include = t_phase_start_include.durationTo(t_after_include).nanoseconds,
                .parse = t_after_include.durationTo(t_after_parse).nanoseconds,
                .codegen = t_after_parse.durationTo(t_after_codegen).nanoseconds,
            });
        }
    }

    const fail = failures.items.len + gr_failures.items.len;

    // JSON mode emits one object covering every diagnostic + read
    // error, then exits. No human-readable header / summary / footer.
    if (json_mode) {
        var pipeline_failures: std.ArrayList(diagnostics.FileFailure) = .empty;
        for (failures.items) |f| switch (f.info) {
            .read_error => {}, // surfaced via read_errors list instead
            .from_pipeline => |pf| try pipeline_failures.append(arena, pf),
        };
        try diagnostics.printJsonReport(stdout, pipeline_failures.items, read_errors.items, files.items.len, fail);
        // Append lang diagnostics as ndjson lines on the same
        // stdout — consumers parse line-by-line.
        if (gr_failures.items.len > 0) {
            var lang_files: std.ArrayList(gero.lang.render.FileDiagnostics) = .empty;
            for (gr_failures.items) |gf| try lang_files.append(arena, .{
                .path = gf.path,
                .source = gf.source,
                .diagnostics = gf.diagnostics,
            });
            try gero.lang.render.json(stdout, lang_files.items);
        }
        return if (fail > 0 or gr_failures.items.len > 0) 4 else 0;
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

    // Pass 2b: render lang-side diagnostics.
    if (gr_failures.items.len > 0) {
        if (!single and !opts.quiet and (pass > 0 or failures.items.len > 0)) try stdout.writeByte('\n');
        var lang_files: std.ArrayList(gero.lang.render.FileDiagnostics) = .empty;
        for (gr_failures.items) |gf| try lang_files.append(arena, .{
            .path = gf.path,
            .source = gf.source,
            .diagnostics = gf.diagnostics,
        });
        const lang_style: gero.lang.render.Style = if (term.color) .ansi else .none;
        try gero.lang.render.pretty(stdout, lang_files.items, lang_style);
    }

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

/// One `.gr` file's diagnostic context — source bytes + combined
/// parser + typechecker diagnostics, ready for
/// `gero.lang.render.pretty` / `.json`.
const GrFailure = struct {
    path: []const u8,
    source: []const u8,
    parse_errors: []const u8 = "", // placeholder field — kept for symmetry
    diagnostics: []gero.lang.Diagnostic,
};

/// Result of running parse + typecheck on one `.gr` source.
const GrCheckResult = struct {
    source: []const u8,
    parse_errors: []const u8 = "",
    diagnostics: []gero.lang.Diagnostic,
    read_error: bool = false,
};

/// Read + tokenize + parse + typecheck one `.gr` file. Parser
/// diagnostics are folded into the returned slice as lang
/// `Diagnostic`s with `E_SYNTAX_GENERIC` codes (the parser code
/// retrofit lands as a follow-up).
fn checkOneGr(
    io: std.Io,
    arena: std.mem.Allocator,
    path: []const u8,
) !GrCheckResult {
    const src = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch {
        return .{ .source = "", .diagnostics = &.{}, .read_error = true };
    };

    const stream = try gero.lang.tokenize(arena, src);
    // Tokenizer / parser errors travel through the same lang.Diagnostic
    // shape so the renderer surfaces them in the canonical layout.
    // The lexer + parser populate `expected` with the stable
    // `E_SYNTAX_*` code (see `docs/lang-diagnostics.md`); we fall
    // back to a generic code only when an emission site predates
    // the retrofit.
    var combined: std.ArrayList(gero.lang.Diagnostic) = .empty;
    for (stream.errors) |e| {
        try combined.append(arena, .{
            .severity = .fatal,
            .code = e.expected orelse "E_SYNTAX_GENERIC",
            // safety: ParseError.index fits in u32 — bounded by file size.
            .message = try arena.dupe(u8, e.message),
            .span = .{ .start = @intCast(e.index), .end = @intCast(e.index) },
        });
    }

    const tree = try gero.lang.parse(arena, src, stream);
    for (tree.errors) |e| {
        try combined.append(arena, .{
            .severity = .fatal,
            .code = e.expected orelse "E_SYNTAX_GENERIC",
            // safety: ParseError.index fits in u32 — bounded by file size.
            .message = try arena.dupe(u8, e.message),
            .span = .{ .start = @intCast(e.index), .end = @intCast(e.index) },
        });
    }

    // Only typecheck when parsing succeeded — otherwise the AST
    // shape can't carry semantic information.
    if (tree.errors.len == 0) {
        const checked = try gero.lang.typecheck(arena, src, &tree.program);
        for (checked.diagnostics) |d| try combined.append(arena, d);
    }

    return .{
        .source = src,
        .diagnostics = try combined.toOwnedSlice(arena),
    };
}

fn printPassGr(
    stdout: *std.Io.Writer,
    style: gero.asm_.Style,
    src_path: []const u8,
    single_mode: bool,
) std.Io.Writer.Error!void {
    if (single_mode) {
        try stdout.print("{s}✓ {s}{s}\n", .{ style.location, src_path, style.reset });
    } else {
        try stdout.print("{s}✓{s} {s}\n", .{ style.location, style.reset, src_path });
    }
}

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

/// Resolve `path` into 0+ source entries appended to `out`. A
/// directory is walked recursively; both `.gas` and `.gr` files are
/// collected. A regular file is appended as-is. Anything else
/// (broken link, special file) emits a host IO error.
fn collectSourceFiles(
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
            if (!std.mem.endsWith(u8, entry.path, ".gas") and
                !std.mem.endsWith(u8, entry.path, ".gr")) continue;
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
