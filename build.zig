const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Single source of truth for the package version. The CLI picks
    // this up via `@import("build_options")` so `gero --version`
    // tracks `build.zig.zon` automatically — no second site to bump.
    const package_version: []const u8 = @import("build.zig.zon").version;
    const cli_options = b.addOptions();
    cli_options.addOption([]const u8, "version", package_version);

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
    cli_mod.addOptions("build_options", cli_options);

    const cli_exe = b.addExecutable(.{
        .name = "gero",
        .root_module = cli_mod,
    });
    b.installArtifact(cli_exe);

    // Tests embedded in the CLI source — wire them into `zig build test`.
    const cli_test_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-cli/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_test_mod.addOptions("build_options", cli_options);
    const cli_test = b.addTest(.{
        .name = "test-cli",
        .root_module = cli_test_mod,
    });
    const run_cmd_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-cli/run.zig"),
        .target = target,
        .optimize = optimize,
    });
    run_cmd_mod.addImport("gero", gero_mod);
    run_cmd_mod.addOptions("build_options", cli_options);
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
    asm_mod.addOptions("build_options", cli_options);
    const asm_test = b.addTest(.{
        .name = "test-cli-asm",
        .root_module = asm_mod,
    });
    const disasm_cli_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-cli/disasm.zig"),
        .target = target,
        .optimize = optimize,
    });
    disasm_cli_mod.addImport("gero", gero_mod);
    disasm_cli_mod.addOptions("build_options", cli_options);
    const disasm_cli_test = b.addTest(.{
        .name = "test-cli-disasm",
        .root_module = disasm_cli_mod,
    });
    const test_cli_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-cli/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_cli_mod.addImport("gero", gero_mod);
    test_cli_mod.addOptions("build_options", cli_options);
    const test_cli_test = b.addTest(.{
        .name = "test-cli-test",
        .root_module = test_cli_mod,
    });
    const check_cli_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-cli/check.zig"),
        .target = target,
        .optimize = optimize,
    });
    check_cli_mod.addImport("gero", gero_mod);
    check_cli_mod.addOptions("build_options", cli_options);
    const check_cli_test = b.addTest(.{
        .name = "test-cli-check",
        .root_module = check_cli_mod,
    });
    const fmt_cli_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-cli/fmt.zig"),
        .target = target,
        .optimize = optimize,
    });
    fmt_cli_mod.addImport("gero", gero_mod);
    fmt_cli_mod.addOptions("build_options", cli_options);
    const fmt_cli_test = b.addTest(.{
        .name = "test-cli-fmt",
        .root_module = fmt_cli_mod,
    });
    const diagnostics_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-cli/diagnostics.zig"),
        .target = target,
        .optimize = optimize,
    });
    diagnostics_mod.addImport("gero", gero_mod);
    const diagnostics_test = b.addTest(.{
        .name = "test-cli-diagnostics",
        .root_module = diagnostics_mod,
    });
    const footer_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-cli/footer.zig"),
        .target = target,
        .optimize = optimize,
    });
    footer_mod.addImport("gero", gero_mod);
    const footer_test = b.addTest(.{
        .name = "test-cli-footer",
        .root_module = footer_mod,
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

    // Build the `examples` import once — exposes each
    // `examples/asm/<name>.gas` as a `pub const name_gas: []const u8`
    // so tests living under `tests/` can pull the source text without
    // tripping the `@embedFile` package-path guard.
    const examples_opts = makeExamplesOptions(b);

    // ----- Native tests, default optimize ----------------------------------

    const test_step = b.step("test", "Run native tests");
    test_step.dependOn(&b.addRunArtifact(cli_test).step);
    test_step.dependOn(&b.addRunArtifact(run_cmd_test).step);
    test_step.dependOn(&b.addRunArtifact(term_test).step);
    test_step.dependOn(&b.addRunArtifact(info_test).step);
    test_step.dependOn(&b.addRunArtifact(asm_test).step);
    test_step.dependOn(&b.addRunArtifact(disasm_cli_test).step);
    test_step.dependOn(&b.addRunArtifact(test_cli_test).step);
    test_step.dependOn(&b.addRunArtifact(check_cli_test).step);
    test_step.dependOn(&b.addRunArtifact(fmt_cli_test).step);
    test_step.dependOn(&b.addRunArtifact(diagnostics_test).step);
    test_step.dependOn(&b.addRunArtifact(footer_test).step);
    for (test_files) |rel| {
        const t = makeTest(b, gero_mod, examples_opts, rel, target, optimize);
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
            const t = makeTest(b, gero_mod, examples_opts, rel, target, mode);
            const run = b.addRunArtifact(t);
            mode_step.dependOn(&run.step);
            test_modes_step.dependOn(&run.step);
        }
    }

    // ----- Cross-target compile-only tests ---------------------------------

    const test_all = b.step("test-all", "Native run + compile-only on extra targets");
    for (test_files) |rel| {
        const t = makeTest(b, gero_mod, examples_opts, rel, target, optimize);
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
            const t = makeTest(b, gero_mod, examples_opts, rel, cross_target, optimize);
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

    // ----- Example integration tests ---------------------------------------
    //
    // Drive every examples/asm/*.gas through the installed `gero`
    // CLI (assemble + run) and diff stdout against its golden
    // `.expected` file. Depends on the install step so the binary
    // is on disk before the script runs.

    const test_examples_cmd = b.addSystemCommand(&.{ "bash", "scripts/test-examples.sh" });
    test_examples_cmd.step.dependOn(b.getInstallStep());
    const test_examples_step = b.step(
        "test-examples",
        "Assemble + run every examples/asm/*.gas and diff against its .expected",
    );
    test_examples_step.dependOn(&test_examples_cmd.step);

    const check_examples_cmd = b.addSystemCommand(&.{ "bash", "scripts/check-examples.sh" });
    check_examples_cmd.step.dependOn(b.getInstallStep());
    const check_examples_step = b.step(
        "check-examples",
        "Drive every examples/asm/*.gas through `gero check` (fails on any non-zero)",
    );
    check_examples_step.dependOn(&check_examples_cmd.step);

    const check_broken_cmd = b.addSystemCommand(&.{ "bash", "scripts/check-broken.sh" });
    check_broken_cmd.step.dependOn(b.getInstallStep());
    const check_broken_step = b.step(
        "check-broken",
        "Drive every tests/asm/check-broken/*.gas through `gero check` and assert each fails",
    );
    check_broken_step.dependOn(&check_broken_cmd.step);

    const fmt_check_examples_cmd = b.addSystemCommand(&.{ "bash", "scripts/fmt-check-examples.sh" });
    fmt_check_examples_cmd.step.dependOn(b.getInstallStep());
    const fmt_check_examples_step = b.step(
        "fmt-check-examples",
        "Verify every examples/asm/*.gas is canonical under `gero fmt --check`",
    );
    fmt_check_examples_step.dependOn(&fmt_check_examples_cmd.step);

    // ----- All-in-one CI ---------------------------------------------------

    const ci_step = b.step("ci", "Local equivalent of CI: lint + test-modes + test-all + check-examples + check-broken + fmt-check-examples + test-examples");
    ci_step.dependOn(lint_step);
    ci_step.dependOn(test_modes_step);
    ci_step.dependOn(test_all);
    ci_step.dependOn(&check_examples_cmd.step);
    ci_step.dependOn(&check_broken_cmd.step);
    ci_step.dependOn(&fmt_check_examples_cmd.step);
    ci_step.dependOn(&test_examples_cmd.step);

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
/// The test module imports `gero` (library), `util` (helpers in
/// tests/util.zig), and `examples` (example .gas sources, generated by
/// `makeExamplesOptions`).
fn makeTest(
    b: *std.Build,
    gero_mod: *std.Build.Module,
    examples_opts: *std.Build.Step.Options,
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
    test_mod.addOptions("examples", examples_opts);

    return b.addTest(.{
        .name = b.fmt("test-{s}", .{sanitizeName(b, rel)}),
        .root_module = test_mod,
    });
}

/// Read each `examples/asm/<name>.gas` at build time and expose it as
/// a `pub const <name>_gas: []const u8` on the returned options Step.
/// Tests `@import("examples")` to reach them without bumping into the
/// `@embedFile` package-path guard.
fn makeExamplesOptions(b: *std.Build) *std.Build.Step.Options {
    const opts = b.addOptions();
    const names = [_][]const u8{ "hello", "fib", "counter" };
    for (names) |name| {
        const rel = b.fmt("examples/asm/{s}.gas", .{name});
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            b.graph.io,
            rel,
            b.allocator,
            .unlimited,
        ) catch |err| std.debug.panic("makeExamplesOptions: read {s} failed ({s})", .{ rel, @errorName(err) });
        opts.addOption([]const u8, b.fmt("{s}_gas", .{name}), bytes);
    }
    return opts;
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
