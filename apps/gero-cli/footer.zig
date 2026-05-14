/// Cargo-style elapsed-time footer printed by the long-running
/// CLI subcommands (`gero asm`, `gero check`, …) to give a quick
/// "how long did that take" signal. Shared so the format stays
/// consistent across every command.
///
/// Output shape:
///
/// ```text
///     Finished in 1.2 ms
///     Failed in   4.1 ms
/// ```
///
/// The footer label is right-padded by the caller's choice of
/// style (`style.location` bold for ok, `style.code` red for
/// failures).
const std = @import("std");
const gero = @import("gero");

/// Did the command produce its artifact or bail on errors?
pub const Outcome = enum { ok, failed };

/// Write a single `Finished in …` / `Failed in …` line to `stdout`.
pub fn writeFooter(
    stdout: *std.Io.Writer,
    io: std.Io,
    style: gero.asm_.Style,
    t_start: std.Io.Timestamp,
    outcome: Outcome,
) std.Io.Writer.Error!void {
    const t_end = std.Io.Timestamp.now(io, .awake);
    const elapsed_ns: i96 = t_start.durationTo(t_end).nanoseconds;
    const label = switch (outcome) {
        .ok => "    Finished in ",
        .failed => "    Failed in ",
    };
    const label_style = switch (outcome) {
        .ok => style.location, // bold — same as path headers
        .failed => style.code, // red — same as [Exxx]
    };
    try stdout.print("{s}{s}{s}", .{ label_style, label, style.reset });
    try writeDuration(stdout, elapsed_ns);
    try stdout.writeByte('\n');
}

/// Render a wall-clock duration as `<whole>.<tenths> <unit>` with
/// `s` / `ms` / `< 1 ms` granularity. Public so commands that want
/// per-phase breakdowns can reuse the same rendering.
pub fn writeDuration(stdout: *std.Io.Writer, ns: i96) std.Io.Writer.Error!void {
    const ns_per_ms: i96 = std.time.ns_per_ms;
    const ns_per_s: i96 = std.time.ns_per_s;
    if (ns >= ns_per_s) {
        // @as: caller passes a non-negative duration; the cast to
        //      u64 just lets `{d}` format unsigned without the
        //      leading-sign business that confuses the spec.
        const whole: u64 = @intCast(@divFloor(ns, ns_per_s));
        const tenths: u64 = @intCast(@divFloor(@mod(ns, ns_per_s), ns_per_ms * 100));
        try stdout.print("{d}.{d} s", .{ whole, tenths });
    } else if (ns >= ns_per_ms) {
        // @as: see above — non-negative ns by construction.
        const whole: u64 = @intCast(@divFloor(ns, ns_per_ms));
        const tenths: u64 = @intCast(@divFloor(@mod(ns, ns_per_ms), 100_000));
        try stdout.print("{d}.{d} ms", .{ whole, tenths });
    } else {
        try stdout.writeAll("< 1 ms");
    }
}
