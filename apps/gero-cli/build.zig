/// `gero build` — project-aware compile. Walks the ancestor
/// chain for `gero.toml`, reads `[build]` + `[package]`, runs the
/// asm pipeline against `build.entry`, and writes the resulting
/// `.gx` to `<project_root>/<build.out>/<stem>.gx`, where `<stem>`
/// is `[build].name` if set, else `[package].name`.
///
/// `gero build` is essentially `gero asm` wrapped with manifest
/// resolution + output-path discipline. Reuses every existing
/// asm-pipeline piece (`resolveIncludes` → `parse` → `assemble`).
///
/// Exit codes per cli.md §3.12 + §5:
///   - `0` clean
///   - `1` host IO problem (manifest missing, unreadable, write failed)
///   - `2` usage error (unsupported target override)
///   - `3` manifest parse error or asm pipeline error
const std = @import("std");
const gero = @import("gero");
const cli = @import("cli.zig");
const term_mod = @import("term.zig");
const project = @import("project.zig");
const diagnostics = @import("diagnostics.zig");
const footer = @import("footer.zig");

/// Drive the `gero build` flow against the gero.toml found by
/// ancestor-walk. Caller owns `arena`.
pub fn execute(
    io: std.Io,
    arena: std.mem.Allocator,
    opts: cli.Options,
    stdout: *std.Io.Writer,
    term: *term_mod.Term,
) !u8 {
    const t_start = std.Io.Timestamp.now(io, .awake);
    const positionals = opts.positional();
    if (positionals.len > 0) {
        try term.err("gero build: takes no positional args (entry point comes from gero.toml's [build].entry)", .{});
        return 2;
    }

    const style: gero.asm_.Style = if (term.color) .ansi else .plain;

    // 1. Find + read + parse the manifest.
    const manifest_path = (try project.findManifest(io, arena)) orelse {
        try term.err("gero build: no gero.toml in this directory or any parent (run `gero new` to scaffold, or `gero asm <file>` for single-file mode)", .{});
        return 1;
    };

    const source = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, arena, .unlimited) catch |err| {
        try term.err("gero build: cannot read {s} ({s})", .{ manifest_path, @errorName(err) });
        return 1;
    };

    var manifest = switch (try project.parseWithDiagnostic(arena, source)) {
        .ok => |m| m,
        .err => |diag| {
            try term.err("gero build: {s}:{d}:{d}: {s}", .{ manifest_path, diag.line, diag.col, diag.message() });
            return 3;
        },
    };
    defer manifest.deinit(arena);

    // 2. Target gate. `--target=<vm|gtx-16>` overrides the manifest;
    //    only `vm` is wired in v0.2 — `gtx-16` lights up later.
    const target = opts.target orelse manifest.package.target;
    if (!std.mem.eql(u8, target, "vm")) {
        if (std.mem.eql(u8, target, "gtx-16")) {
            try term.err("gero build: target `gtx-16` is not yet implemented (lights up later — only `vm` works in v0.2)", .{});
        } else {
            try term.err("gero build: unknown target `{s}` (expected `vm` or `gtx-16`)", .{target});
        }
        return 2;
    }

    // 3. Resolve project-relative paths. Output lives under a
    //    per-profile subdir (`out/<optimize>/`) so rebuilding in
    //    release mode doesn't clobber the debug artifact, à la
    //    Cargo's `target/{debug,release}/` layout.
    const project_root = std.fs.path.dirname(manifest_path) orelse "";
    const entry_path = try joinUnderRoot(arena, project_root, manifest.build.entry);
    const out_root = try joinUnderRoot(arena, project_root, manifest.build.out);
    const out_dir = try std.fs.path.join(arena, &.{ out_root, manifest.build.optimize });

    // 4. Ensure the output directory exists. `createDirPath` is
    //    idempotent — creates `out/<optimize>/` plus any missing
    //    parents in one shot.
    std.Io.Dir.cwd().createDirPath(io, out_dir) catch |err| {
        try term.err("gero build: cannot create {s} ({s})", .{ out_dir, @errorName(err) });
        return 1;
    };

    // 5. Asm pipeline against the entry.
    const t_phase_start_include = std.Io.Timestamp.now(io, .awake);
    var fused = gero.asm_.resolveIncludes(io, arena, entry_path) catch |err| {
        try term.err("gero build: cannot read {s} ({s})", .{ entry_path, @errorName(err) });
        return 1;
    };
    defer fused.deinit();
    const t_after_include = std.Io.Timestamp.now(io, .awake);

    if (fused.errors.len > 0) {
        try diagnostics.printSingle(stdout, fused.source_map, fused.errors, style);
        try footer.writeFooter(stdout, io, style, t_start, .failed);
        return 3;
    }

    var pt = try gero.asm_.parse(arena, fused.source);
    defer pt.deinit();
    const t_after_parse = std.Io.Timestamp.now(io, .awake);

    var cg = try gero.asm_.assemble(arena, fused.source, pt, .{
        .debug_symbols = manifest.build.debug_symbols,
    });
    defer cg.deinit();
    const t_after_codegen = std.Io.Timestamp.now(io, .awake);

    if (pt.hasErrors() or cg.hasErrors()) {
        try diagnostics.printAllFailures(arena, stdout, style, &.{
            .{
                .source_map = fused.source_map,
                .parse_errors = pt.errors,
                .codegen_errors = cg.errors,
            },
        });
        try footer.writeFooter(stdout, io, style, t_start, .failed);
        return 3;
    }

    // 6. Write `<out_dir>/<stem>.gx`. Stem is `[build].name` if
    //    set, else `[package].name` — Cargo's `[[bin]].name`
    //    convention so the binary can decouple from the crate.
    const stem = manifest.build.name orelse manifest.package.name;
    const gx_name = try std.fmt.allocPrint(arena, "{s}.gx", .{stem});
    const out_path = try std.fs.path.join(arena, &.{ out_dir, gx_name });
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = cg.image }) catch |err| {
        try term.err("gero build: cannot write {s} ({s})", .{ out_path, @errorName(err) });
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
        try footer.writeFooter(stdout, io, style, t_start, .ok);
    }

    return 0;
}

/// Per-phase timings printed under `--verbose` — mirrors `gero asm`.
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
        try footer.writeDuration(stdout, p.ns);
        try stdout.writeByte('\n');
    }
}

/// Join a manifest-relative path under the project root. The root
/// is `dirname(manifest_path)` — empty when `gero.toml` sits in
/// the cwd. An empty root means "current directory"; we return
/// the bare path so `gero build` from the project root doesn't
/// accumulate spurious `./` prefixes.
pub fn joinUnderRoot(arena: std.mem.Allocator, project_root: []const u8, rel: []const u8) ![]const u8 {
    if (project_root.len == 0) return arena.dupe(u8, rel);
    return std.fs.path.join(arena, &.{ project_root, rel });
}

// ---------- tests ----------

const testing = std.testing;

test "joinUnderRoot: empty root keeps the relative path verbatim" {
    const out = try joinUnderRoot(testing.allocator, "", "src/main.gas");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("src/main.gas", out);
}

test "joinUnderRoot: parent root prefixes correctly" {
    const out = try joinUnderRoot(testing.allocator, "..", "src/main.gas");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("../src/main.gas", out);
}

test "joinUnderRoot: deeper root prefixes correctly" {
    const out = try joinUnderRoot(testing.allocator, "../..", "out/");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("../../out/", out);
}
