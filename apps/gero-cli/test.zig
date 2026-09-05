const std = @import("std");
const gero = @import("gero");
const cli = @import("cli.zig");
const term_mod = @import("term.zig");
const manifest_loader = @import("manifest_loader.zig");
const gr_runner = @import("gr_runner.zig");

// Per-test cycle budget comes from the manifest's `[test].cycle_budget`
// (default 1,000,000 per `project.defaults`). Threaded through
// `runOne` / `runImage` so it can vary per-project without a recompile.

/// Discovered test program — assembled lazily, paired with its
/// golden `.expected` body.
const Program = struct {
    /// Display name shown in the runner output — a `.gas` basename
    /// without extension, or a `@test` def's own name.
    name: []const u8,
    /// Relative path of the source that produced this result — a
    /// `.gas` program or the `.gr` module declaring a `@test` def.
    /// Used in failure footers and as assembler input.
    source_path: []const u8,
    /// Full byte contents of the sibling `<name>.expected`.
    expected: []const u8,
};

/// How a single test ended.
const Outcome = enum {
    /// Captured stdout matched `.expected`.
    ok,
    /// Include resolution / parse / codegen produced errors.
    asm_failed,
    /// VM faulted or hit a breakpoint.
    runtime_failed,
    /// Test halted cleanly but stdout differed from `.expected`.
    diff_failed,
    /// Cycle budget exhausted — likely an infinite loop in the
    /// test source.
    timeout,
};

const Result = struct {
    name: []const u8,
    source_path: []const u8,
    outcome: Outcome,
    elapsed_ns: i96,
    /// One-line summary surfaced in the failure section (and the
    /// status line on FAIL).
    detail: []const u8 = "",
    /// Filled only on `.diff_failed` so the failure section can
    /// print an `expected:` / `got:` pair.
    expected: []const u8 = "",
    got: []const u8 = "",
};

/// Drive the test runner per `opts`. Returns the CLI exit code.
pub fn execute(
    io: std.Io,
    arena: std.mem.Allocator,
    opts: cli.Options,
    stdout: *std.Io.Writer,
    term: *term_mod.Term,
) !u8 {
    const positionals = opts.positional();
    if (positionals.len > 1) {
        try term.err("gero test: extra positional args (only [pattern] is accepted)", .{});
        return 2;
    }
    const pattern: ?[]const u8 = if (positionals.len == 1) positionals[0] else null;

    // Project-driven test discovery: load gero.toml from cwd or an
    // ancestor and walk [test].include for `.gas` + sibling
    // `.expected` pairs. No manifest → usage error: there's no
    // sensible default root for a CLI shipped as a binary.
    const outcome = try manifest_loader.load(io, arena, term, "gero test");
    var loaded = switch (outcome) {
        .not_found => {
            try term.err("gero test: no gero.toml in this directory or any parent (run `gero new` to scaffold a project, or `gero asm` + `gero run` for single-file programs)", .{});
            return 2;
        },
        .failed => return 1,
        .ok => |l| l,
    };
    defer loaded.deinit(arena);

    if (loaded.manifest.test_.include.len == 0) {
        try term.err("gero test: gero.toml has no [test].include entries — add at least one directory or .gas path to discover tests", .{});
        return 2;
    }

    var source_files: std.ArrayList([]const u8) = .empty;
    manifest_loader.expandIncludes(io, arena, term, "gero test", loaded.project_root, loaded.manifest.test_.include, &.{ ".gas", ".gr" }, &source_files) catch |err| switch (err) {
        error.LoadFailed => return 1,
        else => |e| return e,
    };

    const programs = try collectPrograms(
        io,
        arena,
        term,
        loaded.project_root,
        source_files.items,
        loaded.manifest.test_.exclude,
        pattern,
    );

    // `@test` defs in `.gr` modules run alongside the `.gas` golden
    // programs — one walk, both languages (§3.7.5).
    const gr_modules = try gr_runner.discover(io, arena, term, "gero test", source_files.items, "test", pattern);
    defer for (gr_modules) |m| m.deinit();

    var gr_count: usize = 0;
    for (gr_modules) |m| gr_count += m.entries.len;

    if (programs.len + gr_count == 0) {
        if (pattern) |p| {
            try stdout.print("no tests matching '{s}' under [test].include\n", .{p});
        } else {
            try stdout.print("no tests under [test].include\n", .{});
        }
        return 0;
    }

    const style: gero.asm_.Style = if (term.color) .ansi else .plain;
    const t_start = std.Io.Timestamp.now(io, .awake);
    const total = programs.len + gr_count;
    try stdout.print("running {d} test{s}\n", .{ total, if (total == 1) "" else "s" });

    const results = try arena.alloc(Result, programs.len + gr_count);
    var pass: usize = 0;
    var fail: usize = 0;
    const budget: u64 = @intCast(loaded.manifest.test_.cycle_budget);
    for (programs, 0..) |prog, i| {
        results[i] = try runOne(io, arena, prog, budget);
        if (results[i].outcome == .ok) pass += 1 else fail += 1;
        try writeStatusLine(stdout, style, results[i], opts.verbose);
    }

    var next = programs.len;
    for (gr_modules) |m| {
        for (m.entries) |entry| {
            results[next] = try runGrTest(io, arena, m, entry, budget);
            if (results[next].outcome == .ok) pass += 1 else fail += 1;
            try writeStatusLine(stdout, style, results[next], opts.verbose);
            next += 1;
        }
    }

    if (fail > 0) try writeFailureBodies(stdout, style, results);

    const t_end = std.Io.Timestamp.now(io, .awake);
    try writeSummary(stdout, style, pass, fail, t_start.durationTo(t_end).nanoseconds);

    return if (fail > 0) 7 else 0;
}

/// Resolve every entry in `includes` (manifest-relative, file or
/// directory) and collect `.gas` programs that have a sibling
/// `.expected`. Optionally filtered by `pattern`. `excludes`
/// subtracts manifest-relative paths from the discovered set —
/// each exclude entry is either a `.gas` file or a directory
/// prefix.
fn collectPrograms(
    io: std.Io,
    arena: std.mem.Allocator,
    term: *term_mod.Term,
    project_root: []const u8,
    source_files: []const []const u8,
    excludes: []const []const u8,
    pattern: ?[]const u8,
) ![]Program {

    // Pre-resolve excludes through the same root-joining so they
    // line up with `gas_files` entries byte-for-byte. Each exclude
    // is treated as a prefix: a directory excludes everything
    // under it, a single `.gas` excludes itself.
    var excluded: std.ArrayList([]const u8) = .empty;
    for (excludes) |rel| {
        const full = try manifest_loader.joinUnderRoot(arena, project_root, rel);
        try excluded.append(arena, full);
    }

    var list: std.ArrayList(Program) = .empty;
    for (source_files) |source_path| {
        if (!std.mem.endsWith(u8, source_path, ".gas")) continue;
        if (isExcluded(source_path, excluded.items)) continue;
        const name_borrowed = stem(std.fs.path.basename(source_path));
        if (pattern) |p| if (std.mem.indexOf(u8, name_borrowed, p) == null) continue;

        const expected_path = try std.fmt.allocPrint(
            arena,
            "{s}.expected",
            .{source_path[0 .. source_path.len - ".gas".len]},
        );

        const expected_bytes = std.Io.Dir.cwd().readFileAlloc(io, expected_path, arena, .unlimited) catch |err| {
            try term.warn("skipping {s}: no .expected ({s})", .{ source_path, @errorName(err) });
            continue;
        };

        try list.append(arena, .{
            .name = try arena.dupe(u8, name_borrowed),
            .source_path = source_path,
            .expected = expected_bytes,
        });
    }

    const items = try list.toOwnedSlice(arena);
    std.mem.sort(Program, items, {}, lessByName);
    return items;
}

/// Run one `@test` def: lower the module with that def as the entry,
/// execute it, and classify. A clean `hlt` is a pass; the `trap`
/// vector is the assertion (or `panic`) the body tripped, and any
/// other fault means the body itself faulted.
fn runGrTest(
    io: std.Io,
    arena: std.mem.Allocator,
    module: *const gr_runner.Module,
    entry: gr_runner.Entry,
    cycle_budget: u64,
) !Result {
    const t0 = std.Io.Timestamp.now(io, .awake);

    const image = (try gr_runner.compileEntry(arena, module, entry.name)) orelse {
        return finalizeGr(io, t0, entry, .asm_failed, "codegen failed for this entry — run `gero check`", "");
    };

    var buf: std.ArrayList(u8) = .empty;
    var captured = std.Io.Writer.Allocating.fromArrayList(arena, &buf);
    defer captured.deinit();

    const outcome = try gr_runner.run(arena, image, &captured.writer, cycle_budget);
    const printed = captured.written();
    return switch (outcome.outcome) {
        .halted => finalizeGr(io, t0, entry, .ok, "", printed),
        .faulted => finalizeGr(io, t0, entry, .runtime_failed, faultDetail(outcome.fault), printed),
        .breakpoint => finalizeGr(io, t0, entry, .runtime_failed, "hit a `brk`", printed),
        .timeout => finalizeGr(
            io,
            t0,
            entry,
            .timeout,
            try std.fmt.allocPrint(arena, "exceeded {d} cycles", .{cycle_budget}),
            printed,
        ),
    };
}

/// What a fault means for a `@test`. The `trap` vector is the one the
/// body raised on purpose — a failed `test.assert_*`, `panic`,
/// `unreachable`, or `todo`; anything else is an unintended fault, and
/// naming it saves the reader a guess.
fn faultDetail(vector: ?gero.vm.Vector) []const u8 {
    const v = vector orelse return "faulted";
    return switch (v) {
        .trap => "assertion failed",
        .div_by_zero => "faulted: divide by zero",
        .arith_overflow => "faulted: arithmetic overflow",
        .heap_exhausted => "faulted: heap exhausted",
        .invalid_opcode => "faulted: invalid opcode",
        .invalid_register => "faulted: invalid register",
        .reset => "faulted: reset",
        _ => "faulted",
    };
}

fn finalizeGr(
    io: std.Io,
    t0: std.Io.Timestamp,
    entry: gr_runner.Entry,
    outcome: Outcome,
    detail: []const u8,
    printed: []const u8,
) Result {
    const t1 = std.Io.Timestamp.now(io, .awake);
    return .{
        .name = entry.name,
        .source_path = entry.file,
        .outcome = outcome,
        .elapsed_ns = t0.durationTo(t1).nanoseconds,
        .detail = detail,
        .got = printed,
    };
}

fn lessByName(_: void, a: Program, b: Program) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// True when `source_path` is covered by an exclude entry. Excludes
/// match as a prefix — `tests/wip` excludes both `tests/wip/foo.gas`
/// and `tests/wip` itself; an exact `.gas` match excludes only that
/// file.
fn isExcluded(source_path: []const u8, excludes: []const []const u8) bool {
    for (excludes) |ex| {
        if (std.mem.eql(u8, source_path, ex)) return true;
        // Directory prefix: ensure the next char is a separator
        // so `tests/wip` doesn't accidentally swallow `tests/wipe.gas`.
        if (std.mem.startsWith(u8, source_path, ex) and source_path.len > ex.len) {
            const next = source_path[ex.len];
            if (next == '/' or next == std.fs.path.sep) return true;
        }
    }
    return false;
}

/// `foo.gas` → `foo`; `foo` → `foo`. Borrowed slice — caller dupes
/// before storing past the source's lifetime.
fn stem(file: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, file, '.') orelse return file;
    return file[0..dot];
}

/// Assemble + run a single program. Always returns a `Result` —
/// errors land as failure outcomes rather than propagating, so the
/// runner reports them per-test instead of bailing on first error.
fn runOne(io: std.Io, arena: std.mem.Allocator, prog: Program, cycle_budget: u64) !Result {
    const t0 = std.Io.Timestamp.now(io, .awake);

    var fused = gero.asm_.resolveIncludes(io, arena, prog.source_path) catch |err| {
        return finalize(io, t0, prog, .asm_failed, try std.fmt.allocPrint(arena, "include error ({s})", .{@errorName(err)}));
    };
    defer fused.deinit();
    if (fused.errors.len > 0) {
        return finalize(io, t0, prog, .asm_failed, try std.fmt.allocPrint(arena, "{d} include error(s)", .{fused.errors.len}));
    }

    var pt = try gero.asm_.parse(arena, fused.source);
    defer pt.deinit();
    var cg = try gero.asm_.assemble(arena, fused.source, pt, .{});
    defer cg.deinit();
    if (pt.hasErrors() or cg.hasErrors()) {
        const n = pt.errors.len + cg.errors.len;
        return finalize(io, t0, prog, .asm_failed, try std.fmt.allocPrint(arena, "{d} asm error(s)", .{n}));
    }

    var captured: std.Io.Writer.Allocating = .init(arena);
    const run_outcome = runImage(arena, cg.image, &captured.writer, cycle_budget) catch |err| {
        return finalize(io, t0, prog, .runtime_failed, try std.fmt.allocPrint(arena, "vm error ({s})", .{@errorName(err)}));
    };
    switch (run_outcome) {
        .halted => {},
        .faulted => return finalize(io, t0, prog, .runtime_failed, "unhandled fault"),
        .breakpoint => return finalize(io, t0, prog, .runtime_failed, "hit brk"),
        .timeout => return finalize(io, t0, prog, .timeout, try std.fmt.allocPrint(arena, "exceeded {d} cycles", .{cycle_budget})),
    }

    const got = captured.written();
    if (!std.mem.eql(u8, got, prog.expected)) {
        var r = try finalize(io, t0, prog, .diff_failed, "stdout differs from .expected");
        r.expected = prog.expected;
        r.got = try arena.dupe(u8, got);
        return r;
    }

    return finalize(io, t0, prog, .ok, "");
}

fn finalize(io: std.Io, t0: std.Io.Timestamp, prog: Program, outcome: Outcome, detail: []const u8) !Result {
    const t1 = std.Io.Timestamp.now(io, .awake);
    return .{
        .name = prog.name,
        .source_path = prog.source_path,
        .outcome = outcome,
        .elapsed_ns = t0.durationTo(t1).nanoseconds,
        .detail = detail,
    };
}

const RunOutcome = enum { halted, faulted, breakpoint, timeout };

/// Boot a fresh VM on `image`, capture stdout-syscall output into
/// `out`, ignore the SRAM save syscall, and step until halt or the
/// cycle budget runs out.
fn runImage(arena: std.mem.Allocator, image: []const u8, out: *std.Io.Writer, cycle_budget: u64) !RunOutcome {
    const loaded = try gero.vm.parseGx(image);
    var vm = gero.vm.VM.init(arena);
    defer vm.deinit();
    try vm.boot(arena, loaded);

    var i: u64 = 0;
    while (i < cycle_budget) : (i += 1) {
        const ip = vm.regs.read(.ip);
        const op = vm.readByte(ip);
        if (op == 0xFC) {
            const vec = vm.readByte(ip +% 1);
            switch (vec) {
                0x10 => {
                    // safety: print syscall contract — low byte of r1
                    const byte: u8 = @truncate(vm.regs.read(.r1));
                    try out.writeByte(byte);
                    vm.regs.write(.ip, ip +% 2);
                    continue;
                },
                0x21 => {
                    // SRAM save — no-op under `gero test`; .sav
                    // bytes aren't part of the golden compare.
                    vm.regs.write(.ip, ip +% 2);
                    continue;
                },
                else => {},
            }
        }
        switch (gero.vm.step(&vm)) {
            .cont, .branched => continue,
            .halted => return .halted,
            .halted_on_fault => return .faulted,
            .breakpoint => return .breakpoint,
        }
    }
    return .timeout;
}

fn writeStatusLine(out: *std.Io.Writer, style: gero.asm_.Style, r: Result, verbose: bool) !void {
    const tag = if (r.outcome == .ok) "ok" else "FAIL";
    const tag_style = if (r.outcome == .ok) style.location else style.code;
    try out.print("test {s} ... {s}{s}{s}", .{ r.name, tag_style, tag, style.reset });
    if (verbose) {
        try out.writeAll(" (");
        try writeDuration(out, r.elapsed_ns);
        try out.writeByte(')');
    }
    try out.writeByte('\n');
}

fn writeFailureBodies(out: *std.Io.Writer, style: gero.asm_.Style, results: []const Result) !void {
    var first = true;
    for (results) |r| {
        if (r.outcome == .ok) continue;
        if (first) {
            try out.writeByte('\n');
            first = false;
        }
        try out.print(
            "{s}FAIL{s} {s}{s}{s}: {s}\n",
            .{ style.code, style.reset, style.location, r.name, style.reset, r.detail },
        );
        if (r.outcome == .diff_failed) {
            try out.writeAll("  expected:\n");
            try writeIndented(out, r.expected, "    ");
            try out.writeAll("  got:\n");
            try writeIndented(out, r.got, "    ");
        }
        try out.print("  at {s}\n", .{r.source_path});
    }
}

/// Echo `text` line-by-line with `prefix` in front of each line.
/// A trailing newline in `text` is consumed so we don't emit a
/// dangling prefix-only line.
fn writeIndented(out: *std.Io.Writer, text: []const u8, prefix: []const u8) !void {
    var body = text;
    if (body.len > 0 and body[body.len - 1] == '\n') body = body[0 .. body.len - 1];
    var iter = std.mem.splitScalar(u8, body, '\n');
    while (iter.next()) |line| {
        try out.writeAll(prefix);
        try out.writeAll(line);
        try out.writeByte('\n');
    }
}

fn writeSummary(out: *std.Io.Writer, style: gero.asm_.Style, pass: usize, fail: usize, elapsed_ns: i96) !void {
    try out.writeByte('\n');
    if (fail == 0) {
        try out.print("{s}{d} passed{s}", .{ style.location, pass, style.reset });
    } else {
        try out.print("{d} passed, {s}{d} failed{s}", .{ pass, style.code, fail, style.reset });
    }
    try out.writeAll(" (");
    try writeDuration(out, elapsed_ns);
    try out.writeAll(")\n");
}

fn writeDuration(out: *std.Io.Writer, ns: i96) !void {
    const ns_per_ms: i96 = std.time.ns_per_ms;
    const ns_per_s: i96 = std.time.ns_per_s;
    if (ns >= ns_per_s) {
        // safety: caller passes non-negative durations; the cast to
        // u64 lets `{d}` format unsigned without sign handling.
        const whole: u64 = @intCast(@divFloor(ns, ns_per_s));
        const tenths: u64 = @intCast(@divFloor(@mod(ns, ns_per_s), ns_per_ms * 100));
        try out.print("{d}.{d} s", .{ whole, tenths });
    } else if (ns >= ns_per_ms) {
        // safety: same as above.
        const whole: u64 = @intCast(@divFloor(ns, ns_per_ms));
        const tenths: u64 = @intCast(@divFloor(@mod(ns, ns_per_ms), 100_000));
        try out.print("{d}.{d} ms", .{ whole, tenths });
    } else {
        try out.writeAll("< 1 ms");
    }
}

// ---------- tests ----------

const testing = std.testing;

test "test: stem strips the trailing extension" {
    try testing.expectEqualStrings("hello", stem("hello.gas"));
    try testing.expectEqualStrings("noext", stem("noext"));
    try testing.expectEqualStrings("a.b", stem("a.b.c"));
}

test "test: writeIndented prefixes every line and drops trailing newline" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeIndented(&w, "abc\ndef\n", "  > ");
    try testing.expectEqualStrings("  > abc\n  > def\n", buf[0..w.end]);
}

test "test: writeIndented handles unterminated input" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeIndented(&w, "one\ntwo", "| ");
    try testing.expectEqualStrings("| one\n| two\n", buf[0..w.end]);
}

test "test: writeIndented copes with an empty body" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeIndented(&w, "", "  ");
    try testing.expectEqualStrings("  \n", buf[0..w.end]);
}

test "test: writeSummary green ok-only run" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeSummary(&w, .plain, 3, 0, 0);
    try testing.expectEqualStrings("\n3 passed (< 1 ms)\n", buf[0..w.end]);
}

test "test: writeSummary reports both pass and fail counts" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeSummary(&w, .plain, 2, 1, 0);
    try testing.expectEqualStrings("\n2 passed, 1 failed (< 1 ms)\n", buf[0..w.end]);
}

test "test: writeStatusLine non-verbose ok" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const r: Result = .{
        .name = "hello",
        .source_path = "tests/asm/programs/hello.gas",
        .outcome = .ok,
        .elapsed_ns = 0,
    };
    try writeStatusLine(&w, .plain, r, false);
    try testing.expectEqualStrings("test hello ... ok\n", buf[0..w.end]);
}

test "test: writeStatusLine FAIL with verbose duration" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const r: Result = .{
        .name = "boom",
        .source_path = "x.gas",
        .outcome = .diff_failed,
        .elapsed_ns = 0,
    };
    try writeStatusLine(&w, .plain, r, true);
    try testing.expectEqualStrings("test boom ... FAIL (< 1 ms)\n", buf[0..w.end]);
}

test "test: writeFailureBodies prints expected/got for diff fails" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const results = [_]Result{
        .{
            .name = "boom",
            .source_path = "tests/asm/programs/boom.gas",
            .outcome = .diff_failed,
            .elapsed_ns = 0,
            .detail = "stdout differs from .expected",
            .expected = "OK\n",
            .got = "KO\n",
        },
    };
    try writeFailureBodies(&w, .plain, &results);
    const want =
        \\
        \\FAIL boom: stdout differs from .expected
        \\  expected:
        \\    OK
        \\  got:
        \\    KO
        \\  at tests/asm/programs/boom.gas
        \\
    ;
    try testing.expectEqualStrings(want, buf[0..w.end]);
}

test "test: lessByName sorts case-sensitive alphabetically" {
    const a: Program = .{ .name = "alpha", .source_path = "a.gas", .expected = "" };
    const b: Program = .{ .name = "beta", .source_path = "b.gas", .expected = "" };
    try testing.expect(lessByName({}, a, b));
    try testing.expect(!lessByName({}, b, a));
}
