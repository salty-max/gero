const std = @import("std");
const gero = @import("gero");
const cli = @import("cli.zig");
const term_mod = @import("term.zig");
const project = @import("project.zig");
const diagnostics = @import("diagnostics.zig");
const footer = @import("footer.zig");
const compile = @import("compile.zig");
const build_cache = @import("build_cache.zig");

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
    //    only `vm` is wired today — `gtx-16` is a downstream target.
    const target = opts.target orelse manifest.package.target;
    if (!std.mem.eql(u8, target, "vm")) {
        if (std.mem.eql(u8, target, "gtx-16")) {
            try term.err("gero build: target `gtx-16` is not yet implemented (only `vm` is currently wired)", .{});
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

    // 5. Pick the front-end from the entry's extension. A `.gr`
    //    entry runs the lang pipeline (§7.1 — one `.gr` plus the
    //    `use` graph it reaches); anything else is asm.
    if (std.mem.endsWith(u8, entry_path, ".gr")) {
        return buildLang(io, arena, opts, stdout, term, .{
            .entry_path = entry_path,
            .out_dir = out_dir,
            .out_root = out_root,
            .manifest = manifest,
            .t_start = t_start,
        });
    }

    // 6. Asm pipeline against the entry.
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
        .source_map = &fused.source_map,
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

    // 7. Write `<out_dir>/<stem>.gx`. Stem is `[build].name` if
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

/// Inputs the `.gr` build path needs from `execute`, which has
/// already resolved the manifest and created the output directory.
const LangBuild = struct {
    entry_path: []const u8,
    out_dir: []const u8,
    /// Project output root, above the per-profile dirs.
    out_root: []const u8,
    manifest: project.Manifest,
    t_start: std.Io.Timestamp,
};

/// `gero build` against a `.gr` entry. Shares `gero compile`'s
/// pipeline so diagnostics read identically between the two, then
/// writes to the manifest-derived path rather than a sibling default.
fn buildLang(
    io: std.Io,
    arena: std.mem.Allocator,
    opts: cli.Options,
    stdout: *std.Io.Writer,
    term: *term_mod.Term,
    b: LangBuild,
) !u8 {
    const cargo_style: gero.asm_.Style = if (term.color) .ansi else .plain;

    const stem = b.manifest.build.name orelse b.manifest.package.name;
    const gx_name = try std.fmt.allocPrint(arena, "{s}.gx", .{stem});
    const out_path = try std.fs.path.join(arena, &.{ b.out_dir, gx_name });

    // The cache lives beside the profile output dirs rather than inside
    // one, so switching profiles doesn't discard the other's record.
    const cache_dir = try std.fs.path.join(arena, &.{ b.out_root, build_cache.dir_name });
    const image = switch (try compile.compileLang(
        io,
        arena,
        b.entry_path,
        opts.optimize,
        "gero build",
        stdout,
        term,
        b.t_start,
        .{
            .dir = cache_dir,
            .entry = b.manifest.build.entry,
            // The mode that actually reaches codegen, which `--optimize`
            // can override the manifest with.
            .optimize = @tagName(opts.optimize),
            .output = out_path,
        },
    )) {
        .failed => |code| return code,
        .image => |img| img,
        .unchanged => {
            if (!opts.quiet) {
                try stdout.print("{s} (unchanged)\n", .{out_path});
                try footer.writeFooter(stdout, io, cargo_style, b.t_start, .ok);
            }
            return 0;
        },
    };

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = image }) catch |err| {
        try term.err("gero build: cannot write {s} ({s})", .{ out_path, @errorName(err) });
        return 1;
    };

    if (!opts.quiet) {
        try stdout.print("{s} ({d} bytes)\n", .{ out_path, image.len });
        try footer.writeFooter(stdout, io, cargo_style, b.t_start, .ok);
    }
    return 0;
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

test "build: a `.gr` entry routes to the lang front-end" {
    // The extension is the whole dispatch rule, so pin it directly —
    // an entry that ends in `.gr` must not reach the asm pipeline.
    try std.testing.expect(std.mem.endsWith(u8, "src/main.gr", ".gr"));
    try std.testing.expect(!std.mem.endsWith(u8, "src/main.gas", ".gr"));
}

test "build: a `.gr` stem still comes from the manifest, not the source name" {
    // `<out>/<[build].name ?? [package].name>.gx` — the entry file's
    // own stem never names the artifact.
    const with_override: ?[]const u8 = "cart";
    const package_name: []const u8 = "demo";
    const stem = with_override orelse package_name;
    try std.testing.expectEqualStrings("cart", stem);

    const no_override: ?[]const u8 = null;
    const stem2 = no_override orelse package_name;
    try std.testing.expectEqualStrings("demo", stem2);
}
