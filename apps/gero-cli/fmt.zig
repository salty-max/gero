/// `gero fmt` — canonical formatter for `.gas` and `.gr` source.
/// Parses the file directly (without resolving includes for asm),
/// re-emits through the language-specific canonical printer, and
/// either writes in-place or reports `--check` diffs.
///
/// Exit codes per cli.md §3.8 + §5:
///   - `0` every file is canonical (or was just made canonical)
///   - `1` host IO problem
///   - `2` usage error
///   - `3` parse error in source
///   - `8` `--check` mode and at least one file would change
///
/// Dispatch by extension: `.gas` → `gero.asm_.printProgram`,
/// `.gr` → `gero.lang.print`. Stdin mode is asm-only for now.
///
/// Notes
/// -----
/// The parser is invoked **without** `resolveIncludes`, so the file
/// is formatted as-written — `include "..."` lines round-trip
/// verbatim (the parser surfaces them as `unknown` statements, the
/// printer source-slices them back). Cross-file validation is the
/// job of `gero check`, not `gero fmt`.
const std = @import("std");
const gero = @import("gero");
const cli = @import("cli.zig");
const term_mod = @import("term.zig");
const footer = @import("footer.zig");
const manifest_loader = @import("manifest_loader.zig");
const project = @import("project.zig");

/// Per-file outcome.
const Outcome = enum {
    /// File was already canonical (`--check` or normal mode).
    unchanged,
    /// File needed reformatting; in normal mode it was rewritten
    /// in place, in `--check` mode the diff was recorded.
    would_change,
    /// Parse error before we could format — diagnostic was emitted.
    parse_error,
};

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

    // `--stdin` is mutually exclusive with positional paths AND with
    // the project-aware manifest fallback. Routes to a separate
    // formatter that reads stdin, writes stdout, never touches the
    // disk, and never consults `gero.toml`. Exit codes per cli.md
    // §3.8: 0 (formatted / canonical), 8 (--check would-modify),
    // 3 (parse error), 2 (usage).
    if (opts.stdin) {
        if (positionals.len > 0) {
            try term.err("gero fmt: --stdin is mutually exclusive with positional paths", .{});
            return 2;
        }
        return try formatStdin(io, arena, stdout, term, style, opts.check);
    }

    // Always try to load gero.toml — both [fmt] overrides and the
    // implicit file list (when no positionals are passed) come
    // from the manifest. `not_found` is normal (single-file CLI
    // use case); `failed` means a read/parse error was already
    // printed.
    var print_options: gero.asm_.PrintOptions = gero.asm_.default_print_options;
    var manifest_files: ?[]const []const u8 = null;
    {
        const outcome = try manifest_loader.load(io, arena, term, "gero fmt");
        switch (outcome) {
            .not_found => {},
            .failed => return 1,
            .ok => |loaded| {
                var loaded_mut = loaded;
                defer loaded_mut.deinit(arena);
                print_options = printOptionsFromManifest(loaded.manifest.fmt);
                if (positionals.len == 0) {
                    var files_buf: std.ArrayList([]const u8) = .empty;
                    const entry_path = try manifest_loader.joinUnderRoot(arena, loaded.project_root, loaded.manifest.build.entry);
                    try files_buf.append(arena, entry_path);
                    manifest_loader.expandIncludes(io, arena, term, "gero fmt", loaded.project_root, loaded.manifest.test_.include, &files_buf) catch |err| switch (err) {
                        error.LoadFailed => return 1,
                        else => |e| return e,
                    };
                    manifest_files = try files_buf.toOwnedSlice(arena);
                }
            },
        }
    }

    var files: std.ArrayList([]const u8) = .empty;
    if (positionals.len == 0) {
        if (manifest_files) |mf| {
            try files.appendSlice(arena, mf);
        } else {
            try term.err("gero fmt: missing source file or directory path (or run inside a gero project)", .{});
            return 2;
        }
    } else {
        for (positionals) |path| {
            try collectSourceFiles(io, arena, term, path, &files);
        }
    }
    if (files.items.len == 0) {
        try term.err("gero fmt: no .gas or .gr files found in the given paths", .{});
        return 1;
    }

    const single = files.items.len == 1;

    var unchanged: usize = 0;
    var changed: usize = 0;
    var parse_failed: usize = 0;
    for (files.items) |path| {
        const outcome = blk: {
            if (std.mem.endsWith(u8, path, ".gr")) {
                break :blk formatOneGr(io, arena, stdout, term, style, path, opts.check, single, opts.quiet) catch |err| {
                    try term.err("gero fmt: cannot read/write {s} ({s})", .{ path, @errorName(err) });
                    return 1;
                };
            }
            break :blk formatOne(io, arena, stdout, term, style, path, opts.check, single, opts.quiet, print_options) catch |err| {
                try term.err("gero fmt: cannot read/write {s} ({s})", .{ path, @errorName(err) });
                return 1;
            };
        };
        switch (outcome) {
            .unchanged => unchanged += 1,
            .would_change => changed += 1,
            .parse_error => parse_failed += 1,
        }
    }

    if (!single and !opts.quiet) {
        try writeSummary(stdout, style, unchanged, changed, parse_failed, opts.check);
    }
    if (!opts.quiet) {
        const final_outcome: footer.Outcome = if (parse_failed > 0 or (opts.check and changed > 0)) .failed else .ok;
        try footer.writeFooter(stdout, io, style, t_start, final_outcome);
    }

    if (parse_failed > 0) return 3;
    if (opts.check and changed > 0) return 8;
    return 0;
}

/// Translate the manifest's `[fmt]` shape into the printer's
/// `PrintOptions`. Same fields one-to-one; `HexCase` is a
/// disjoint enum so we map per-variant.
pub fn printOptionsFromManifest(fmt: project.Manifest.Fmt) gero.asm_.PrintOptions {
    return .{
        .indent = fmt.indent,
        .comment_column = fmt.comment_column,
        .align_kv = fmt.align_kv,
        .hex_case = switch (fmt.hex_case) {
            .upper => .upper,
            .lower => .lower,
            .preserve => .preserve,
        },
    };
}

/// `--stdin` mode: read source from stdin, run the canonical
/// printer, write the result to stdout. `check_mode` flips behavior
/// to exit 8 (no stdout) when the input would reformat.
///
/// The manifest's `[fmt]` overrides are **not** consulted — stdin
/// mode has no project root context. Always uses compile-time
/// defaults.
///
/// Diagnostics on stderr in plain `<line>:<col>: <message>` form
/// (no file path — there is no file). Stdout stays reserved for
/// formatted bytes so editors can pipe it directly.
fn formatStdin(
    io: std.Io,
    arena: std.mem.Allocator,
    stdout: *std.Io.Writer,
    term: *term_mod.Term,
    style: gero.asm_.Style,
    check_mode: bool,
) !u8 {
    _ = style;

    // 16 MiB ceiling matches src/asm/include.zig::max_file_size.
    const max_stdin_bytes: usize = 16 * 1024 * 1024;
    var read_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &read_buf);
    const src = stdin_reader.interface.allocRemaining(arena, .limited(max_stdin_bytes)) catch |err| {
        try term.err("gero fmt: cannot read stdin ({s})", .{@errorName(err)});
        return 1;
    };

    var pt = try gero.asm_.parse(arena, src);

    var real_errors: std.ArrayList(gero.asm_.Diagnostic) = .empty;
    for (pt.errors) |d| {
        if (!errorIsFromIncludeLine(src, d)) try real_errors.append(arena, d);
    }
    if (real_errors.items.len > 0) {
        // No file path → plain `<line>:<col>: <message>` on stderr.
        for (real_errors.items) |d| {
            // @as: ParseError.index fits in u32 — bounded by max_stdin_bytes.
            const lc = lineColAt(src, @as(u32, @intCast(d.parse_error.index)));
            try term.err("{d}:{d}: {s}", .{ lc.line, lc.col, d.parse_error.message });
        }
        return 3;
    }

    var allocating = std.Io.Writer.Allocating.init(arena);
    try gero.asm_.printProgram(&allocating.writer, &pt.program, src, gero.asm_.default_print_options);
    const formatted = allocating.written();

    if (check_mode) {
        // Canonical → exit 0 silent; otherwise exit 8, also silent.
        return if (std.mem.eql(u8, src, formatted)) 0 else 8;
    }

    try stdout.writeAll(formatted);
    return 0;
}

fn formatOne(
    io: std.Io,
    arena: std.mem.Allocator,
    stdout: *std.Io.Writer,
    term: *term_mod.Term,
    style: gero.asm_.Style,
    path: []const u8,
    check_mode: bool,
    single: bool,
    quiet: bool,
    print_options: gero.asm_.PrintOptions,
) !Outcome {
    const src = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);

    var pt = try gero.asm_.parse(arena, src);

    // The parser emits a spurious diagnostic for every `include
    // "..."` line because string literals aren't a valid operand
    // shape — but parser recovery still produces an `unknown`
    // statement covering the whole line, which the printer source-
    // slices back verbatim. Filter those false positives so fmt
    // can round-trip include-using files cleanly. Genuine syntax
    // errors stay surfaced.
    var real_errors: std.ArrayList(gero.asm_.Diagnostic) = .empty;
    for (pt.errors) |d| {
        if (!errorIsFromIncludeLine(src, d)) try real_errors.append(arena, d);
    }
    if (real_errors.items.len > 0) {
        try printParseErrors(stdout, style, path, src, real_errors.items);
        return .parse_error;
    }

    // Re-emit through the canonical printer, then compare bytes
    // against the source. Equal → already canonical.
    var allocating = std.Io.Writer.Allocating.init(arena);
    try gero.asm_.printProgram(&allocating.writer, &pt.program, src, print_options);
    const formatted = allocating.written();

    if (std.mem.eql(u8, src, formatted)) {
        if (!quiet) try stdout.print("{s}✓{s} {s}\n", .{ style.location, style.reset, path });
        _ = single;
        return .unchanged;
    }

    if (check_mode) {
        try stdout.print("{s}✗{s} {s} (would reformat)\n", .{ style.code, style.reset, path });
        return .would_change;
    }

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = formatted }) catch |err| {
        try term.err("gero fmt: cannot write {s} ({s})", .{ path, @errorName(err) });
        return err;
    };
    if (!quiet) try stdout.print("{s}↻{s} {s} (reformatted)\n", .{ style.gutter, style.reset, path });
    return .would_change;
}

/// Resolve `path` into 0+ `.gas` entries appended to `out`.
/// Mirrors the same helper in `check.zig` (split into a shared
/// module later if more commands grow it).
/// `.gr` variant of `formatOne`. Parses via `gero.lang`, re-emits
/// through `gero.lang.print`, and writes back / reports a diff.
/// Diagnostics on stderr use the same plain `<path>:<line>:<col>:
/// <message>` shape as the asm path (the rich diagnostic renderer
/// in `docs/lang-diagnostics.md` is a follow-up issue).
fn formatOneGr(
    io: std.Io,
    arena: std.mem.Allocator,
    stdout: *std.Io.Writer,
    term: *term_mod.Term,
    style: gero.asm_.Style,
    path: []const u8,
    check_mode: bool,
    single: bool,
    quiet: bool,
) !Outcome {
    const src = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);

    var stream = try gero.lang.tokenize(arena, src);
    defer stream.deinit();
    if (stream.hasErrors()) {
        for (stream.errors) |d| {
            // @as: ParseError.index fits in u32 — bounded by file size.
            const lc = lineColAt(src, @as(u32, @intCast(d.index)));
            try term.err("{s}:{d}:{d}: {s}", .{ path, lc.line, lc.col, d.message });
        }
        return .parse_error;
    }

    var tree = try gero.lang.parse(arena, src, stream);
    defer tree.deinit();
    if (tree.errors.len > 0) {
        for (tree.errors) |d| {
            const lc = lineColAt(src, @as(u32, @intCast(d.index)));
            try term.err("{s}:{d}:{d}: {s}", .{ path, lc.line, lc.col, d.message });
        }
        return .parse_error;
    }

    var allocating = std.Io.Writer.Allocating.init(arena);
    try gero.lang.print(&allocating.writer, &tree.program, src);
    const formatted = allocating.written();

    if (std.mem.eql(u8, src, formatted)) {
        if (!quiet) try stdout.print("{s}✓{s} {s}\n", .{ style.location, style.reset, path });
        _ = single;
        return .unchanged;
    }

    if (check_mode) {
        try stdout.print("{s}✗{s} {s} (would reformat)\n", .{ style.code, style.reset, path });
        return .would_change;
    }

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = formatted }) catch |err| {
        try term.err("gero fmt: cannot write {s} ({s})", .{ path, @errorName(err) });
        return err;
    };
    if (!quiet) try stdout.print("{s}↻{s} {s} (reformatted)\n", .{ style.gutter, style.reset, path });
    return .would_change;
}

fn collectSourceFiles(
    io: std.Io,
    arena: std.mem.Allocator,
    term: *term_mod.Term,
    path: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| {
        try term.err("gero fmt: cannot stat {s} ({s})", .{ path, @errorName(err) });
        return error.OutOfMemory;
    };
    if (stat.kind == .directory) {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
            try term.err("gero fmt: cannot open dir {s} ({s})", .{ path, @errorName(err) });
            return error.OutOfMemory;
        };
        defer dir.close(io);
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const is_gas = std.mem.endsWith(u8, entry.path, ".gas");
            const is_gr = std.mem.endsWith(u8, entry.path, ".gr");
            if (!is_gas and !is_gr) continue;
            const full = try std.fs.path.join(arena, &.{ path, entry.path });
            try out.append(arena, full);
        }
    } else if (stat.kind == .file) {
        try out.append(arena, try arena.dupe(u8, path));
    } else {
        try term.err("gero fmt: {s} is neither a file nor a directory", .{path});
        return error.OutOfMemory;
    }
}

/// Plain `<path>:<line>:<col>: <message>` parse-error report.
/// No caret style — building a SourceMap for a non-include-resolved
/// file isn't worth the complexity. `gero check` does the caret
/// version against the full include graph.
fn printParseErrors(
    stdout: *std.Io.Writer,
    style: gero.asm_.Style,
    path: []const u8,
    src: []const u8,
    errors: []const gero.asm_.Diagnostic,
) !void {
    for (errors) |d| {
        // @as: ParseError.index is `usize`; widening to u32 for the
        //      lineCol scan is safe — file size capped at 16 MiB.
        const lc = lineColAt(src, @as(u32, @intCast(d.parse_error.index)));
        try stdout.print("{s}{s}:{d}:{d}{s}: {s}\n", .{
            style.location,
            path,
            lc.line,
            lc.col,
            style.reset,
            d.parse_error.message,
        });
    }
}

/// True when the diagnostic at `d.parse_error.index` points into
/// a source line whose first non-whitespace tokens are `include`.
/// The parser flags every `include "..."` as a spurious diagnostic
/// because string-literal operands aren't part of the instruction
/// grammar; for fmt we ignore those since the unknown-statement
/// recovery preserves the line via source-slice.
fn errorIsFromIncludeLine(src: []const u8, d: gero.asm_.Diagnostic) bool {
    // @as: ParseError.index fits in u32 — file size capped at 16 MiB.
    var i: usize = @as(u32, @intCast(d.parse_error.index));
    while (i > 0 and src[i - 1] != '\n') i -= 1;
    while (i < src.len and (src[i] == ' ' or src[i] == '\t')) i += 1;
    const kw = "include";
    return i + kw.len <= src.len and std.mem.eql(u8, src[i .. i + kw.len], kw);
}

const LineCol = struct { line: usize, col: usize };

fn lineColAt(src: []const u8, index: u32) LineCol {
    var line: usize = 1;
    var col: usize = 1;
    var i: usize = 0;
    // @as: ParseError index fits in u32 — bounded by max_file_size.
    const target: usize = @as(usize, index);
    while (i < src.len and i < target) : (i += 1) {
        if (src[i] == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .col = col };
}

fn writeSummary(
    stdout: *std.Io.Writer,
    style: gero.asm_.Style,
    unchanged: usize,
    changed: usize,
    parse_failed: usize,
    check_mode: bool,
) !void {
    const change_verb: []const u8 = if (check_mode) "would reformat" else "reformatted";
    try stdout.print(
        "\n{s}fmt:{s} {d} unchanged, {d} {s}",
        .{ style.location, style.reset, unchanged, changed, change_verb },
    );
    if (parse_failed > 0) {
        try stdout.print(", {d} parse failed", .{parse_failed});
    }
    try stdout.writeByte('\n');
}

// ---------- tests ----------

const testing = std.testing;

test "fmt: lineColAt counts lines + cols from byte offset" {
    const src = "line1\nline2\nline3";
    try testing.expectEqual(LineCol{ .line = 1, .col = 1 }, lineColAt(src, 0));
    try testing.expectEqual(LineCol{ .line = 1, .col = 6 }, lineColAt(src, 5));
    try testing.expectEqual(LineCol{ .line = 2, .col = 1 }, lineColAt(src, 6));
    try testing.expectEqual(LineCol{ .line = 3, .col = 3 }, lineColAt(src, 14));
}

test "fmt: errorIsFromIncludeLine recognizes include directives" {
    const src =
        \\const X = $10
        \\
        \\include "foo.gas"
        \\  include "bar.gas"
        \\not_an_include "x"
    ;

    const at_include = mkDiag(15); // points into the `include` line
    try testing.expect(errorIsFromIncludeLine(src, at_include));

    const at_indented_include = mkDiag(33); // points into "  include"
    try testing.expect(errorIsFromIncludeLine(src, at_indented_include));

    const at_other = mkDiag(53); // points into "not_an_include"
    try testing.expect(!errorIsFromIncludeLine(src, at_other));

    const at_const = mkDiag(0); // points into "const X"
    try testing.expect(!errorIsFromIncludeLine(src, at_const));
}

fn mkDiag(index: u32) gero.asm_.Diagnostic {
    return .{
        .code = .duplicate_label,
        .parse_error = .{
            .parser = "test",
            .index = index,
            .message = "synthetic",
            .expected = "",
            .actual = "",
            .kind = .semantic,
        },
    };
}
