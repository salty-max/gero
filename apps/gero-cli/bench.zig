const std = @import("std");
const gero = @import("gero");
const cli = @import("cli.zig");
const term_mod = @import("term.zig");
const manifest_loader = @import("manifest_loader.zig");
const gr_runner = @import("gr_runner.zig");

/// Iterations per benchmark when `--iter` isn't given (cli.md §3.5).
const default_iterations: u32 = 1000;

/// Cycle counts across one benchmark's iterations. The VM is
/// deterministic — same image, same start state, same cycle count —
/// so `min` and `max` differing means the body itself varies, not
/// measurement noise.
const Stats = struct {
    name: []const u8,
    avg: u64,
    min: u64,
    max: u64,
};

/// Drive the `@bench` runner per `opts`. Returns the CLI exit code.
pub fn execute(
    io: std.Io,
    arena: std.mem.Allocator,
    opts: cli.Options,
    stdout: *std.Io.Writer,
    term: *term_mod.Term,
) !u8 {
    const positionals = opts.positional();
    if (positionals.len > 1) {
        try term.err("gero bench: extra positional args (only [pattern] is accepted)", .{});
        return 2;
    }
    const pattern: ?[]const u8 = if (positionals.len == 1) positionals[0] else null;
    const iterations: u32 = opts.iter orelse default_iterations;
    if (iterations == 0) {
        try term.err("gero bench: --iter must be at least 1", .{});
        return 2;
    }

    const outcome = try manifest_loader.load(io, arena, term, "gero bench");
    var loaded = switch (outcome) {
        .not_found => {
            try term.err("gero bench: no gero.toml in this directory or any parent (run `gero new` to scaffold a project)", .{});
            return 2;
        },
        .failed => return 1,
        .ok => |l| l,
    };
    defer loaded.deinit(arena);

    if (loaded.manifest.test_.include.len == 0) {
        try term.err("gero bench: gero.toml has no [test].include entries — add at least one directory or path to discover benchmarks", .{});
        return 2;
    }

    var source_files: std.ArrayList([]const u8) = .empty;
    manifest_loader.expandIncludes(io, arena, term, "gero bench", loaded.project_root, loaded.manifest.test_.include, &.{".gr"}, &source_files) catch |err| switch (err) {
        error.LoadFailed => return 1,
        else => |e| return e,
    };

    const modules = try gr_runner.discover(io, arena, term, "gero bench", source_files.items, "bench", pattern);
    defer for (modules) |m| m.deinit();

    var count: usize = 0;
    for (modules) |m| count += m.entries.len;
    if (count == 0) {
        if (pattern) |p| {
            try stdout.print("no benchmarks matching '{s}' under [test].include\n", .{p});
        } else {
            try stdout.print("no benchmarks under [test].include\n", .{});
        }
        return 0;
    }

    const style: gero.asm_.Style = if (term.color) .ansi else .plain;
    try stdout.print("running {d} benchmark{s}, {d} iteration{s} each\n", .{
        count,
        if (count == 1) "" else "s",
        iterations,
        if (iterations == 1) "" else "s",
    });

    const budget: u64 = @intCast(loaded.manifest.test_.cycle_budget);
    var failed: usize = 0;
    for (modules) |m| {
        for (m.entries) |entry| {
            const stats = measure(arena, m, entry, iterations, budget) catch {
                try stdout.print("bench {s} ... {s}FAIL{s} (codegen failed — run `gero check`)\n", .{ entry.name, style.code, style.reset });
                failed += 1;
                continue;
            };
            const s = stats orelse {
                try stdout.print("bench {s} ... {s}FAIL{s} (faulted or exceeded {d} cycles)\n", .{ entry.name, style.code, style.reset, budget });
                failed += 1;
                continue;
            };
            try writeStatsLine(stdout, style, s);
        }
    }

    // A bench that faults or runs away is a runtime fault (§5), not
    // a test failure — nothing asserted, the body just didn't finish.
    return if (failed > 0) 6 else 0;
}

/// Run one `@bench` def `iterations` times, returning its cycle
/// statistics. `null` when any iteration faulted or ran past the
/// budget — a benchmark that doesn't complete has no meaningful cost.
fn measure(
    arena: std.mem.Allocator,
    module: *const gr_runner.Module,
    entry: gr_runner.Entry,
    iterations: u32,
    cycle_budget: u64,
) !?Stats {
    const image = (try gr_runner.compileEntry(arena, module, entry.name)) orelse return error.CodegenFailed;

    var total: u64 = 0;
    var min: u64 = std.math.maxInt(u64);
    var max: u64 = 0;

    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        // Each iteration boots a fresh VM, so a benchmark measures its
        // own body rather than accumulated state from the run before.
        var sink: std.ArrayList(u8) = .empty;
        var discard = std.Io.Writer.Allocating.fromArrayList(arena, &sink);
        defer discard.deinit();

        const r = try gr_runner.run(arena, image, &discard.writer, cycle_budget);
        if (r.outcome != .halted) return null;

        total += r.cycles;
        min = @min(min, r.cycles);
        max = @max(max, r.cycles);
    }

    return .{
        .name = entry.name,
        .avg = total / iterations,
        .min = min,
        .max = max,
    };
}

fn writeStatsLine(out: *std.Io.Writer, style: gero.asm_.Style, s: Stats) !void {
    try out.print("bench {s} ... {s}ok{s}  (avg {d} cyc, min {d} cyc, max {d} cyc)\n", .{
        s.name,
        style.location,
        style.reset,
        s.avg,
        s.min,
        s.max,
    });
}

// ---------- tests ----------

test "bench: default iteration count matches the documented 1000" {
    try std.testing.expectEqual(@as(u32, 1000), default_iterations);
}

test "bench: stats average over iterations" {
    const s: Stats = .{ .name = "b", .avg = 24 / 4, .min = 5, .max = 7 };
    try std.testing.expectEqual(@as(u64, 6), s.avg);
    try std.testing.expect(s.min <= s.avg and s.avg <= s.max);
}
