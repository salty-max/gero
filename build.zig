const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ----- Library module + artifact ---------------------------------------

    const knit_dep = b.dependency("knit", .{ .target = target, .optimize = optimize });
    const knit_mod = knit_dep.module("knit");

    const gero_mod = b.addModule("gero", .{
        .root_source_file = b.path("src/gero.zig"),
        .target = target,
        .optimize = optimize,
    });
    gero_mod.addImport("knit", knit_mod);

    const lib = b.addLibrary(.{
        .name = "gero",
        .root_module = gero_mod,
    });
    b.installArtifact(lib);

    // ----- CLI binary ------------------------------------------------------

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-cli/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_mod.addImport("gero", gero_mod);

    const cli_exe = b.addExecutable(.{
        .name = "gero",
        .root_module = cli_mod,
    });
    b.installArtifact(cli_exe);

    // Tests embedded in the CLI source — wire them into `zig build test`.
    const cli_test = b.addTest(.{
        .name = "test-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/gero-cli/cli.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_cmd_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-cli/run.zig"),
        .target = target,
        .optimize = optimize,
    });
    run_cmd_mod.addImport("gero", gero_mod);
    const run_cmd_test = b.addTest(.{
        .name = "test-cli-run",
        .root_module = run_cmd_mod,
    });
    const term_test = b.addTest(.{
        .name = "test-cli-term",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/gero-cli/term.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const info_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-cli/info.zig"),
        .target = target,
        .optimize = optimize,
    });
    info_mod.addImport("gero", gero_mod);
    const info_test = b.addTest(.{
        .name = "test-cli-info",
        .root_module = info_mod,
    });
    const asm_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-cli/asm.zig"),
        .target = target,
        .optimize = optimize,
    });
    asm_mod.addImport("gero", gero_mod);
    const asm_test = b.addTest(.{
        .name = "test-cli-asm",
        .root_module = asm_mod,
    });

    // ----- Format ----------------------------------------------------------

    const fmt = b.addFmt(.{
        .paths = &.{ "src", "tests", "apps", "build.zig" },
        .check = false,
    });
    b.step("fmt", "Format every .zig file in place").dependOn(&fmt.step);

    const fmt_check = b.addFmt(.{
        .paths = &.{ "src", "tests", "apps", "build.zig" },
        .check = true,
    });
    b.step("fmt-check", "Check formatting without writing").dependOn(&fmt_check.step);

    // ----- Test discovery --------------------------------------------------
    //
    // Walk tests/ at build time and collect every *.test.zig. Each one becomes
    // its own test artifact, importing `gero` (the library module) and
    // `util` (test helpers in tests/util.zig).

    const test_files = collectTestFiles(b);

    // ----- Native tests, default optimize ----------------------------------

    const test_step = b.step("test", "Run native tests");
    test_step.dependOn(&b.addRunArtifact(cli_test).step);
    test_step.dependOn(&b.addRunArtifact(run_cmd_test).step);
    test_step.dependOn(&b.addRunArtifact(term_test).step);
    test_step.dependOn(&b.addRunArtifact(info_test).step);
    test_step.dependOn(&b.addRunArtifact(asm_test).step);
    for (test_files) |rel| {
        const t = makeTest(b, gero_mod, rel, target, optimize);
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // ----- Native tests in every release mode (CI matrix) ------------------

    const test_modes_step = b.step("test-modes", "Run native tests in every release mode");
    const modes = [_]std.builtin.OptimizeMode{ .Debug, .ReleaseSafe, .ReleaseFast, .ReleaseSmall };
    for (modes) |mode| {
        const mode_name = @tagName(mode);
        const mode_step = b.step(
            b.fmt("test-{s}", .{mode_name}),
            b.fmt("Run native tests in {s} mode", .{mode_name}),
        );
        for (test_files) |rel| {
            const t = makeTest(b, gero_mod, rel, target, mode);
            const run = b.addRunArtifact(t);
            mode_step.dependOn(&run.step);
            test_modes_step.dependOn(&run.step);
        }
    }

    // ----- Cross-target compile-only tests ---------------------------------

    const test_all = b.step("test-all", "Native run + compile-only on extra targets");
    for (test_files) |rel| {
        const t = makeTest(b, gero_mod, rel, target, optimize);
        test_all.dependOn(&b.addRunArtifact(t).step);
    }

    const extra_targets: []const std.Target.Query = if (builtin.os.tag == .macos)
        &.{
            .{ .cpu_arch = .x86_64, .os_tag = .linux },
            .{ .cpu_arch = .aarch64, .os_tag = .macos },
            .{ .cpu_arch = .x86_64, .os_tag = .windows },
            .{ .cpu_arch = .aarch64, .os_tag = .windows },
            .{ .cpu_arch = .wasm32, .os_tag = .wasi },
        }
    else
        &.{
            .{ .cpu_arch = .x86_64, .os_tag = .linux },
            .{ .cpu_arch = .x86_64, .os_tag = .windows },
            .{ .cpu_arch = .aarch64, .os_tag = .windows },
            .{ .cpu_arch = .wasm32, .os_tag = .wasi },
        };
    for (extra_targets) |tq| {
        const cross_target = b.resolveTargetQuery(tq);
        for (test_files) |rel| {
            const t = makeTest(b, gero_mod, rel, cross_target, optimize);
            test_all.dependOn(&t.step);
        }
    }

    // ----- Lint scripts ----------------------------------------------------

    const check_imports = b.addSystemCommand(&.{ "bash", "scripts/check-imports.sh" });
    b.step("imports", "Forbid @import past one parent").dependOn(&check_imports.step);

    const check_unused = b.addSystemCommand(&.{ "bash", "scripts/check-unused.sh" });
    b.step("unused", "Detect unused public exports").dependOn(&check_unused.step);

    const check_strict = b.addSystemCommand(&.{ "bash", "scripts/check-strict.sh" });
    b.step("strict", "Forbid anyerror, *anyopaque in pub APIs, unjustified casts").dependOn(&check_strict.step);

    const check_mirror = b.addSystemCommand(&.{ "bash", "scripts/check-mirror.sh" });
    b.step("mirror", "Verify every src module has its mirror test").dependOn(&check_mirror.step);

    const check_test_alloc = b.addSystemCommand(&.{ "bash", "scripts/check-testing-allocator.sh" });
    b.step("testing-allocator", "Require std.testing.allocator in alloc-touching tests").dependOn(&check_test_alloc.step);

    const check_docs = b.addSystemCommand(&.{ "bash", "scripts/check-docs.sh" });
    b.step("docs", "Require /// doc comments on every public declaration").dependOn(&check_docs.step);

    const check_naming = b.addSystemCommand(&.{ "bash", "scripts/check-naming.sh" });
    b.step("naming", "Enforce PascalCase for type-returning fns, camelCase otherwise").dependOn(&check_naming.step);

    const lint_step = b.step("lint", "Run every static check CI runs");
    lint_step.dependOn(&fmt_check.step);
    lint_step.dependOn(&check_imports.step);
    lint_step.dependOn(&check_unused.step);
    lint_step.dependOn(&check_strict.step);
    lint_step.dependOn(&check_mirror.step);
    lint_step.dependOn(&check_test_alloc.step);
    lint_step.dependOn(&check_docs.step);
    lint_step.dependOn(&check_naming.step);

    // ----- All-in-one CI ---------------------------------------------------

    const ci_step = b.step("ci", "Local equivalent of CI: lint + test-modes + test-all");
    ci_step.dependOn(lint_step);
    ci_step.dependOn(test_modes_step);
    ci_step.dependOn(test_all);

    // ----- Changesets ------------------------------------------------------

    const changeset_new = b.addSystemCommand(&.{ "bash", "scripts/changeset-new.sh" });
    b.step("changeset", "Scaffold a new changeset interactively").dependOn(&changeset_new.step);

    const changeset_version = b.addSystemCommand(&.{ "bash", "scripts/changeset-version.sh" });
    b.step("version", "Consume pending changesets, bump version, prepend CHANGELOG").dependOn(&changeset_version.step);

    // ----- Cleanup ---------------------------------------------------------

    const clean_step = b.step("clean", "Remove zig-out and .zig-cache (Unix only)");
    const clean_cmd = b.addSystemCommand(&.{ "rm", "-rf", "zig-out", ".zig-cache" });
    clean_step.dependOn(&clean_cmd.step);
}

/// Walk tests/ at build time and collect every relative path ending in
/// `.test.zig`. Returns paths sorted for deterministic build output.
/// Returns an empty slice if tests/ is missing or unreadable — that yields
/// a build with zero test artifacts rather than a hard failure.
fn collectTestFiles(b: *std.Build) []const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    var dir = std.Io.Dir.cwd().openDir(b.graph.io, "tests", .{ .iterate = true }) catch return &.{};
    defer dir.close(b.graph.io);
    var walker = dir.walk(b.allocator) catch return &.{};
    defer walker.deinit();
    while (walker.next(b.graph.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".test.zig")) continue;
        const dup = b.allocator.dupe(u8, entry.path) catch continue;
        paths.append(b.allocator, dup) catch continue;
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, a: []const u8, c: []const u8) bool {
            return std.mem.lessThan(u8, a, c);
        }
    }.lt);
    return paths.toOwnedSlice(b.allocator) catch &.{};
}

/// Build a test artifact for `tests/<rel>` against a (target, optimize) pair.
/// The test module imports `gero` (library) and `util` (helpers in tests/util.zig).
fn makeTest(
    b: *std.Build,
    gero_mod: *std.Build.Module,
    rel: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const util_mod = b.createModule(.{
        .root_source_file = b.path("tests/util.zig"),
        .target = target,
        .optimize = optimize,
    });
    util_mod.addImport("gero", gero_mod);

    const test_mod = b.createModule(.{
        .root_source_file = b.path(b.fmt("tests/{s}", .{rel})),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("gero", gero_mod);
    test_mod.addImport("util", util_mod);

    return b.addTest(.{
        .name = b.fmt("test-{s}", .{sanitizeName(b, rel)}),
        .root_module = test_mod,
    });
}

/// Turn a relative path like "vm/decoder.test.zig" into a valid test
/// artifact name like "vm-decoder". Zig rejects names containing path
/// separators.
fn sanitizeName(b: *std.Build, rel: []const u8) []const u8 {
    const without_suffix = if (std.mem.endsWith(u8, rel, ".test.zig"))
        rel[0 .. rel.len - ".test.zig".len]
    else
        rel;
    const out = b.allocator.alloc(u8, without_suffix.len) catch return "test";
    for (without_suffix, 0..) |c, i| {
        out[i] = switch (c) {
            '/', '\\', '.' => '-',
            else => c,
        };
    }
    return out;
}
