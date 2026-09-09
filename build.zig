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

    // The library carries its own build_options so consumers picking up
    // `gero` as a dependency see VERSION without needing to wire options
    // themselves. The extra `is_lib` marker forces `addOptions` to emit a
    // distinct content-addressed file from `cli_options` — without it,
    // both objects hash to the same path and the CLI binary fails to
    // build with a "file in two modules" error.
    const lib_options = b.addOptions();
    lib_options.addOption([]const u8, "version", package_version);
    lib_options.addOption(bool, "is_lib", true);
    gero_mod.addOptions("build_options", lib_options);

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
    const project_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-cli/project.zig"),
        .target = target,
        .optimize = optimize,
    });
    const project_test = b.addTest(.{
        .name = "test-cli-project",
        .root_module = project_mod,
    });
    const manifest_loader_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-cli/manifest_loader.zig"),
        .target = target,
        .optimize = optimize,
    });
    const manifest_loader_test = b.addTest(.{
        .name = "test-cli-manifest-loader",
        .root_module = manifest_loader_mod,
    });
    const new_cli_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-cli/new.zig"),
        .target = target,
        .optimize = optimize,
    });
    new_cli_mod.addOptions("build_options", cli_options);
    const new_cli_test = b.addTest(.{
        .name = "test-cli-new",
        .root_module = new_cli_mod,
    });
    const init_cli_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-cli/init.zig"),
        .target = target,
        .optimize = optimize,
    });
    init_cli_mod.addOptions("build_options", cli_options);
    const init_cli_test = b.addTest(.{
        .name = "test-cli-init",
        .root_module = init_cli_mod,
    });
    const build_cli_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-cli/build.zig"),
        .target = target,
        .optimize = optimize,
    });
    build_cli_mod.addImport("gero", gero_mod);
    build_cli_mod.addOptions("build_options", cli_options);
    const build_cli_test = b.addTest(.{
        .name = "test-cli-build",
        .root_module = build_cli_mod,
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
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-cli/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("gero", gero_mod);
    bench_mod.addOptions("build_options", cli_options);
    const bench_test = b.addTest(.{
        .name = "test-cli-bench",
        .root_module = bench_mod,
    });
    const gr_runner_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-cli/gr_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    gr_runner_mod.addImport("gero", gero_mod);
    gr_runner_mod.addOptions("build_options", cli_options);
    const gr_runner_test = b.addTest(.{
        .name = "test-cli-gr-runner",
        .root_module = gr_runner_mod,
    });
    const build_cache_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-cli/build_cache.zig"),
        .target = target,
        .optimize = optimize,
    });
    build_cache_mod.addImport("gero", gero_mod);
    build_cache_mod.addOptions("build_options", cli_options);
    const build_cache_test = b.addTest(.{
        .name = "test-cli-build-cache",
        .root_module = build_cache_mod,
    });
    const compile_cli_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-cli/compile.zig"),
        .target = target,
        .optimize = optimize,
    });
    compile_cli_mod.addImport("gero", gero_mod);
    compile_cli_mod.addOptions("build_options", cli_options);
    const compile_cli_test = b.addTest(.{
        .name = "test-cli-compile",
        .root_module = compile_cli_mod,
    });
    const repl_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-cli/repl.zig"),
        .target = target,
        .optimize = optimize,
    });
    repl_mod.addImport("gero", gero_mod);
    repl_mod.addOptions("build_options", cli_options);
    const repl_test = b.addTest(.{
        .name = "test-cli-repl",
        .root_module = repl_mod,
    });
    const terminal_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-cli/terminal.zig"),
        .target = target,
        .optimize = optimize,
    });
    const terminal_test = b.addTest(.{
        .name = "test-cli-terminal",
        .root_module = terminal_mod,
    });
    const line_editor_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-cli/line_editor.zig"),
        .target = target,
        .optimize = optimize,
    });
    line_editor_mod.addImport("gero", gero_mod);
    line_editor_mod.addOptions("build_options", cli_options);
    const line_editor_test = b.addTest(.{
        .name = "test-cli-line-editor",
        .root_module = line_editor_mod,
    });
    const gr_diagnostics_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-cli/gr_diagnostics.zig"),
        .target = target,
        .optimize = optimize,
    });
    gr_diagnostics_mod.addImport("gero", gero_mod);
    const gr_diagnostics_test = b.addTest(.{
        .name = "test-cli-gr-diagnostics",
        .root_module = gr_diagnostics_mod,
    });
    const lsp_protocol_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-cli/lsp_protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lsp_protocol_test = b.addTest(.{
        .name = "test-cli-lsp-protocol",
        .root_module = lsp_protocol_mod,
    });
    const lsp_uri_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-cli/lsp_uri.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lsp_uri_test = b.addTest(.{
        .name = "test-cli-lsp-uri",
        .root_module = lsp_uri_mod,
    });
    const lsp_server_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-cli/lsp.zig"),
        .target = target,
        .optimize = optimize,
    });
    lsp_server_mod.addImport("gero", gero_mod);
    lsp_server_mod.addOptions("build_options", cli_options);
    const lsp_server_test = b.addTest(.{
        .name = "test-cli-lsp",
        .root_module = lsp_server_mod,
    });
    const lsp_analysis_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-cli/lsp_analysis.zig"),
        .target = target,
        .optimize = optimize,
    });
    lsp_analysis_mod.addImport("gero", gero_mod);
    const lsp_analysis_test = b.addTest(.{
        .name = "test-cli-lsp-analysis",
        .root_module = lsp_analysis_mod,
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
    test_step.dependOn(&b.addRunArtifact(project_test).step);
    test_step.dependOn(&b.addRunArtifact(manifest_loader_test).step);
    test_step.dependOn(&b.addRunArtifact(new_cli_test).step);
    test_step.dependOn(&b.addRunArtifact(init_cli_test).step);
    test_step.dependOn(&b.addRunArtifact(build_cli_test).step);
    test_step.dependOn(&b.addRunArtifact(diagnostics_test).step);
    test_step.dependOn(&b.addRunArtifact(footer_test).step);
    test_step.dependOn(&b.addRunArtifact(bench_test).step);
    test_step.dependOn(&b.addRunArtifact(gr_runner_test).step);
    test_step.dependOn(&b.addRunArtifact(build_cache_test).step);
    test_step.dependOn(&b.addRunArtifact(compile_cli_test).step);
    test_step.dependOn(&b.addRunArtifact(repl_test).step);
    test_step.dependOn(&b.addRunArtifact(terminal_test).step);
    test_step.dependOn(&b.addRunArtifact(line_editor_test).step);
    test_step.dependOn(&b.addRunArtifact(gr_diagnostics_test).step);
    test_step.dependOn(&b.addRunArtifact(lsp_protocol_test).step);
    test_step.dependOn(&b.addRunArtifact(lsp_uri_test).step);
    test_step.dependOn(&b.addRunArtifact(lsp_analysis_test).step);
    test_step.dependOn(&b.addRunArtifact(lsp_server_test).step);
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

        // The library's tests are not the thing users install. Compiling
        // only those let the CLI's terminal handling stay POSIX-only
        // while this gate reported every target green.
        const cross_gero = b.createModule(.{
            .root_source_file = b.path("src/gero.zig"),
            .target = cross_target,
            .optimize = optimize,
        });
        cross_gero.addImport("knit", knit_mod);
        cross_gero.addOptions("build_options", lib_options);
        const cross_cli = b.createModule(.{
            .root_source_file = b.path("apps/gero-cli/main.zig"),
            .target = cross_target,
            .optimize = optimize,
        });
        cross_cli.addImport("gero", cross_gero);
        cross_cli.addOptions("build_options", cli_options);
        const cross_exe = b.addExecutable(.{
            .name = b.fmt("gero-{s}-{s}", .{ @tagName(tq.cpu_arch.?), @tagName(tq.os_tag.?) }),
            .root_module = cross_cli,
        });
        test_all.dependOn(&cross_exe.step);
    }

    // ----- wasm32-wasi runtime tests ---------------------------------------
    //
    // `test-all` compiles for wasi and stops. Compiling proves the
    // library builds for a target; it says nothing about how it behaves
    // on one, and every other runtime test here runs natively. Needs
    // `-fwasmtime` and wasmtime on PATH; without them the run step says
    // so rather than silently passing.

    const wasi_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    const test_wasi = b.step("test-wasi", "Run the test suite under wasmtime for wasm32-wasi");
    for (test_files) |rel| {
        const t = makeTest(b, gero_mod, examples_opts, rel, wasi_target, optimize);
        test_wasi.dependOn(&b.addRunArtifact(t).step);
    }

    // ----- Lint ------------------------------------------------------------
    //
    // The whole-tree lint runs through a single Zig binary that reads
    // every .zig file once and runs every rule against the in-memory
    // lines. ~10× faster than the per-script bash setup (which each
    // walked the tree independently and check-unused did O(decls × tree)
    // grepping). The bash scripts in scripts/check-*.sh are kept for
    // lefthook pre-commit (per-file mode is already fast there).

    const lint_mod = b.createModule(.{
        .root_source_file = b.path("tools/lint/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lint_exe = b.addExecutable(.{
        .name = "gero-lint",
        .root_module = lint_mod,
    });
    // Install so lefthook's pre-commit hook can call the staged-file
    // form via `./zig-out/bin/gero-lint <files>`.
    b.installArtifact(lint_exe);
    const lint_run = b.addRunArtifact(lint_exe);
    lint_run.setCwd(b.path("."));

    const lint_step = b.step("lint", "Run every static check CI runs");
    lint_step.dependOn(&fmt_check.step);
    lint_step.dependOn(&lint_run.step);

    // ----- wasm module -----------------------------------------------------
    //
    // The boundary gero-lab is written against (docs/gero-lab.md §2).
    // `wasm32-freestanding` rather than wasi: the consumer wants a
    // narrow purpose-built surface, not a POSIX shim. Excluded from
    // build.zig.zon's `paths`, so it never reaches library consumers.

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-wasm/main.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    const wasm_gero_mod = b.createModule(.{
        .root_source_file = b.path("src/gero.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    wasm_gero_mod.addImport("knit", b.dependency("knit", .{
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    }).module("knit"));
    wasm_gero_mod.addOptions("build_options", lib_options);
    wasm_mod.addImport("gero", wasm_gero_mod);

    const wasm_exe = b.addExecutable(.{
        .name = "gero",
        .root_module = wasm_mod,
    });
    // A reactor, not a command: the host calls exports, there is no main.
    wasm_exe.entry = .disabled;
    wasm_exe.rdynamic = true;

    // The module's own tests run natively: the arena, the `Result`
    // encoding, and the diagnostics shape are host-independent, and a
    // native runner reports failures legibly.
    const wasm_host_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-wasm/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    wasm_host_mod.addImport("gero", gero_mod);
    const wasm_test = b.addTest(.{
        .name = "test-wasm",
        .root_module = wasm_host_mod,
    });
    test_step.dependOn(&b.addRunArtifact(wasm_test).step);

    // Each file carrying tests is its own root as well, so dropping one
    // from the module's import graph cannot silently stop testing it.
    // Written out rather than looped: the lint rule matches the literal
    // path, and a `b.fmt` would hide these from it.
    const wasm_abi_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-wasm/abi.zig"),
        .target = target,
        .optimize = optimize,
    });
    wasm_abi_mod.addImport("gero", gero_mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .name = "test-wasm-abi",
        .root_module = wasm_abi_mod,
    })).step);

    const wasm_session_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-wasm/session.zig"),
        .target = target,
        .optimize = optimize,
    });
    wasm_session_mod.addImport("gero", gero_mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .name = "test-wasm-session",
        .root_module = wasm_session_mod,
    })).step);

    const wasm_vm_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-wasm/vm.zig"),
        .target = target,
        .optimize = optimize,
    });
    wasm_vm_mod.addImport("gero", gero_mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .name = "test-wasm-vm",
        .root_module = wasm_vm_mod,
    })).step);

    const wasm_toolchain_mod = b.createModule(.{
        .root_source_file = b.path("apps/gero-wasm/toolchain.zig"),
        .target = target,
        .optimize = optimize,
    });
    wasm_toolchain_mod.addImport("gero", gero_mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .name = "test-wasm-toolchain",
        .root_module = wasm_toolchain_mod,
    })).step);

    const wasm_install = b.addInstallArtifact(wasm_exe, .{});
    // The artifact carries the sample corpus (§9, §10), so the
    // application consumes it rather than keeping a copy that drifts.
    const samples_cmd = b.addSystemCommand(&.{ "node", "scripts/emit-samples.mjs", "zig-out/samples" });

    const wasm_step = b.step("wasm", "Build the gero.wasm module for browser hosts");
    wasm_step.dependOn(&wasm_install.step);
    wasm_step.dependOn(&samples_cmd.step);

    // The runtime gate. `wasm32` is otherwise only compile-checked —
    // every other runtime test gero has runs natively — so this is
    // what turns "wasm32 compiles" into "wasm32 runs".
    const wasm_examples_cmd = b.addSystemCommand(&.{ "bash", "scripts/test-wasm-examples.sh" });
    wasm_examples_cmd.setEnvironmentVariable("GERO_WASM", b.getInstallPath(.bin, "gero.wasm"));
    wasm_examples_cmd.step.dependOn(wasm_step);
    const wasm_examples_step = b.step(
        "test-wasm-examples",
        "Run every example through gero.wasm and diff against its .expected",
    );
    wasm_examples_step.dependOn(&wasm_examples_cmd.step);

    // ----- Golden bytecode corpus ------------------------------------------
    //
    // Recompiles every example and compares the bytes against the
    // blessed images in tests/golden/. Nothing else notices when a
    // codegen change alters output that still runs correctly, which is
    // the promise a format freeze makes.

    const golden_mod = b.createModule(.{
        .root_source_file = b.path("tools/golden/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    golden_mod.addImport("gero", gero_mod);
    const golden_exe = b.addExecutable(.{
        .name = "gero-golden",
        .root_module = golden_mod,
    });

    const golden_test = b.addTest(.{
        .name = "test-golden",
        .root_module = golden_mod,
    });
    const golden_run = b.addRunArtifact(golden_exe);
    golden_run.setCwd(b.path("."));
    const golden_step = b.step("golden", "Check emitted bytecode against the blessed corpus");
    golden_step.dependOn(&golden_run.step);
    // The comparator's own rules — what counts as a difference — are
    // unit-tested alongside the rest of the suite.
    const golden_test_run = b.addRunArtifact(golden_test);
    golden_test_run.setCwd(b.path("."));
    test_step.dependOn(&golden_test_run.step);

    const bless_run = b.addRunArtifact(golden_exe);
    bless_run.setCwd(b.path("."));
    bless_run.addArg("--bless");
    const bless_step = b.step("bless-golden", "Rewrite the blessed corpus from current codegen");
    bless_step.dependOn(&bless_run.step);

    // ----- Example integration tests ---------------------------------------
    //
    // Drive every examples/asm/*.gas through the installed `gero`
    // CLI (assemble + run) and diff stdout against its golden
    // `.expected` file. Depends on the install step so the binary
    // is on disk before the script runs.

    // Where the scripts find what they drive. They defaulted to
    // `./zig-out/bin/gero`, which is not the file's name on a host
    // whose executables carry an extension.
    const exe_ext = target.result.exeFileExt();
    const installed_cli = b.getInstallPath(.bin, b.fmt("gero{s}", .{exe_ext}));

    const test_examples_cmd = b.addSystemCommand(&.{ "bash", "scripts/test-examples.sh" });
    test_examples_cmd.setEnvironmentVariable("GERO_BIN", installed_cli);
    test_examples_cmd.step.dependOn(b.getInstallStep());
    const test_examples_step = b.step(
        "test-examples",
        "Assemble + run every examples/asm/*.gas and diff against its .expected",
    );
    test_examples_step.dependOn(&test_examples_cmd.step);

    const test_examples_lang_cmd = b.addSystemCommand(&.{ "bash", "scripts/test-examples-lang.sh" });
    test_examples_lang_cmd.setEnvironmentVariable("GERO_BIN", installed_cli);
    test_examples_lang_cmd.step.dependOn(b.getInstallStep());
    const test_examples_lang_step = b.step(
        "test-examples-lang",
        "Compile + run every examples/lang/*.gr and diff against its .expected",
    );
    test_examples_lang_step.dependOn(&test_examples_lang_cmd.step);

    const check_examples_cmd = b.addSystemCommand(&.{ "bash", "scripts/check-examples.sh" });
    check_examples_cmd.setEnvironmentVariable("GERO_BIN", installed_cli);
    check_examples_cmd.step.dependOn(b.getInstallStep());
    const check_examples_step = b.step(
        "check-examples",
        "Drive every examples/asm/*.gas through `gero check` (fails on any non-zero)",
    );
    check_examples_step.dependOn(&check_examples_cmd.step);

    const check_doc_asm_cmd = b.addSystemCommand(&.{ "bash", "scripts/check-doc-asm.sh" });
    check_doc_asm_cmd.setEnvironmentVariable("GERO_BIN", installed_cli);
    check_doc_asm_cmd.step.dependOn(b.getInstallStep());
    const check_doc_asm_step = b.step(
        "check-doc-asm",
        "Assemble every ```asm block in docs/asm.md (fails on any that can't)",
    );
    check_doc_asm_step.dependOn(&check_doc_asm_cmd.step);

    const check_doc_gr_cmd = b.addSystemCommand(&.{ "bash", "scripts/check-doc-gr.sh" });
    check_doc_gr_cmd.setEnvironmentVariable("GERO_BIN", installed_cli);
    check_doc_gr_cmd.step.dependOn(b.getInstallStep());
    const check_doc_gr_step = b.step(
        "check-doc-gr",
        "Parse every ```gero block in docs/gero-lang.md (fails on any that can't)",
    );
    check_doc_gr_step.dependOn(&check_doc_gr_cmd.step);

    const check_broken_cmd = b.addSystemCommand(&.{ "bash", "scripts/check-broken.sh" });
    check_broken_cmd.setEnvironmentVariable("GERO_BIN", installed_cli);
    check_broken_cmd.step.dependOn(b.getInstallStep());
    const check_broken_step = b.step(
        "check-broken",
        "Drive every tests/asm/check-broken/*.gas through `gero check` and assert each fails",
    );
    check_broken_step.dependOn(&check_broken_cmd.step);

    const fmt_check_examples_cmd = b.addSystemCommand(&.{ "bash", "scripts/fmt-check-examples.sh" });
    fmt_check_examples_cmd.setEnvironmentVariable("GERO_BIN", installed_cli);
    fmt_check_examples_cmd.step.dependOn(b.getInstallStep());
    const fmt_check_examples_step = b.step(
        "fmt-check-examples",
        "Verify every examples/asm/*.gas is canonical under `gero fmt --check`",
    );
    fmt_check_examples_step.dependOn(&fmt_check_examples_cmd.step);

    const check_examples_gr_cmd = b.addSystemCommand(&.{ "bash", "scripts/check-examples-gr.sh" });
    check_examples_gr_cmd.setEnvironmentVariable("GERO_BIN", installed_cli);
    check_examples_gr_cmd.step.dependOn(b.getInstallStep());
    const check_examples_gr_step = b.step(
        "check-examples-gr",
        "Gate docs/examples/*.gr through `gero fmt --check` (+ `gero check` unless fmt-only)",
    );
    check_examples_gr_step.dependOn(&check_examples_gr_cmd.step);

    // ----- Inner-loop gate (fast, no shell scripts) -----------------------

    const quick_step = b.step("quick", "Inner-loop gate (~1s warm cache, ~30s cold): fmt-check + test (Debug only). Skips every bash-driven static check — use this between edits while iterating.");
    quick_step.dependOn(&fmt_check.step);
    quick_step.dependOn(test_step);

    // ----- Pre-push gate ---------------------------------------------------

    const verify_step = b.step("verify", "Pre-push gate (~3-5 min): lint + test + golden + check-examples + check-broken + fmt-check-examples + check-examples-gr. The bash-driven static checks (strict, naming, unused, etc.) walk every .zig file via grep — that's most of the time. Skips test-modes / test-all / test-examples vs the full `ci` step — those run on GitHub Actions on push.");
    verify_step.dependOn(lint_step);
    verify_step.dependOn(test_step);
    verify_step.dependOn(golden_step);
    verify_step.dependOn(wasm_examples_step);
    verify_step.dependOn(&check_examples_cmd.step);
    verify_step.dependOn(&check_doc_asm_cmd.step);
    verify_step.dependOn(&check_doc_gr_cmd.step);
    verify_step.dependOn(&check_broken_cmd.step);
    verify_step.dependOn(&fmt_check_examples_cmd.step);
    verify_step.dependOn(&check_examples_gr_cmd.step);

    // ----- All-in-one CI ---------------------------------------------------

    const ci_step = b.step("ci", "Local equivalent of CI: lint + test-modes + test-all + golden + check-examples + check-broken + fmt-check-examples + check-examples-gr + test-examples + test-examples-lang");
    ci_step.dependOn(lint_step);
    ci_step.dependOn(test_modes_step);
    ci_step.dependOn(test_all);
    ci_step.dependOn(golden_step);
    // Compiling for freestanding wasm is a different question from
    // compiling for wasi, and the lab depends on the answer.
    ci_step.dependOn(wasm_step);
    ci_step.dependOn(wasm_examples_step);
    ci_step.dependOn(&check_examples_cmd.step);
    ci_step.dependOn(&check_broken_cmd.step);
    ci_step.dependOn(&fmt_check_examples_cmd.step);
    ci_step.dependOn(&check_examples_gr_cmd.step);
    ci_step.dependOn(&test_examples_cmd.step);
    ci_step.dependOn(&test_examples_lang_cmd.step);

    // ----- Changesets ------------------------------------------------------

    const changeset_new = b.addSystemCommand(&.{ "bash", "scripts/changeset-new.sh" });
    b.step("changeset", "Scaffold a new changeset interactively").dependOn(&changeset_new.step);

    const changeset_version = b.addSystemCommand(&.{ "bash", "scripts/changeset-version.sh" });
    b.step("version", "Consume pending changesets, bump version, prepend CHANGELOG").dependOn(&changeset_version.step);

    // ----- Cleanup ---------------------------------------------------------

    const clean_step = b.step("clean", "Remove zig-out and .zig-cache (Unix only)");
    const clean_cmd = b.addSystemCommand(&.{ "rm", "-rf", "zig-out", ".zig-cache" });
    clean_step.dependOn(&clean_cmd.step);

    const clean_cache_step = b.step("clean-cache", "Prune .zig-cache/o dirs older than MAX_AGE_DAYS (default 3), keeping the warm working set (Unix only)");
    const clean_cache_cmd = b.addSystemCommand(&.{ "bash", "scripts/clean-cache.sh" });
    clean_cache_step.dependOn(&clean_cache_cmd.step);
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
