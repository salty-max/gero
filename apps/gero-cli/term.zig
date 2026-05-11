/// Tiny terminal-styling layer for the CLI. Wraps an
/// `*std.Io.Writer` with `err` / `warn` / `success` / `info`
/// helpers that prefix messages and (when color is enabled)
/// wrap the labels in ANSI sequences. `cargo` / `clippy` style.
///
/// Color enablement is decided by the caller — the host typically
/// computes it from TTY detection, the `NO_COLOR` env var, and a
/// `--no-color` flag. `apps/gero-cli/main.zig` does that wiring.
const std = @import("std");

/// User-controllable color toggle. `auto` defers to the caller's
/// decision (TTY + `NO_COLOR`); the explicit modes override.
pub const ColorChoice = enum { auto, always, never };

/// Resolve a `ColorChoice` against runtime signals: explicit flag
/// wins, then `NO_COLOR` forces off, then fall back to the TTY
/// hint.
pub fn resolve(choice: ColorChoice, no_color_env: bool, is_tty: bool) bool {
    return switch (choice) {
        .always => true,
        .never => false,
        .auto => !no_color_env and is_tty,
    };
}

const reset = "\x1b[0m";
const bold_red = "\x1b[1;31m";
const bold_yellow = "\x1b[1;33m";
const bold_green = "\x1b[1;32m";

/// Stateful styled writer.
pub const Term = struct {
    out: *std.Io.Writer,
    color: bool,

    /// `error: <message>` — label in bold red when colored.
    pub fn err(self: *Term, comptime fmt: []const u8, args: anytype) std.Io.Writer.Error!void {
        try self.label("error", bold_red);
        try self.out.print(fmt, args);
        try self.out.writeByte('\n');
    }

    /// `warning: <message>` — label in bold yellow when colored.
    pub fn warn(self: *Term, comptime fmt: []const u8, args: anytype) std.Io.Writer.Error!void {
        try self.label("warning", bold_yellow);
        try self.out.print(fmt, args);
        try self.out.writeByte('\n');
    }

    /// Whole message in bold green when colored — meant for the
    /// "task done" line at the end of a long-running command.
    pub fn success(self: *Term, comptime fmt: []const u8, args: anytype) std.Io.Writer.Error!void {
        if (self.color) try self.out.writeAll(bold_green);
        try self.out.print(fmt, args);
        if (self.color) try self.out.writeAll(reset);
        try self.out.writeByte('\n');
    }

    /// Plain message — no prefix, no color. Same as
    /// `self.out.print(fmt, args)` followed by a newline.
    pub fn info(self: *Term, comptime fmt: []const u8, args: anytype) std.Io.Writer.Error!void {
        try self.out.print(fmt, args);
        try self.out.writeByte('\n');
    }

    fn label(self: *Term, name: []const u8, code: []const u8) std.Io.Writer.Error!void {
        if (self.color) try self.out.writeAll(code);
        try self.out.writeAll(name);
        if (self.color) try self.out.writeAll(reset);
        try self.out.writeAll(": ");
    }
};

// ---------- tests ----------

const testing = std.testing;

test "resolve: always forces on" {
    try testing.expect(resolve(.always, true, false));
    try testing.expect(resolve(.always, false, false));
}

test "resolve: never forces off" {
    try testing.expect(!resolve(.never, false, true));
    try testing.expect(!resolve(.never, true, true));
}

test "resolve: auto respects NO_COLOR and TTY" {
    try testing.expect(resolve(.auto, false, true));
    try testing.expect(!resolve(.auto, true, true));
    try testing.expect(!resolve(.auto, false, false));
}

test "err: colored output wraps the label in ANSI red" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var t = Term{ .out = &w, .color = true };
    try t.err("cannot read {s}", .{"prog.gx"});
    const written = buf[0..w.end];
    try testing.expect(std.mem.indexOf(u8, written, bold_red) != null);
    try testing.expect(std.mem.indexOf(u8, written, "error") != null);
    try testing.expect(std.mem.indexOf(u8, written, "cannot read prog.gx") != null);
    try testing.expect(std.mem.indexOf(u8, written, reset) != null);
}

test "err: plain output has no ANSI codes" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var t = Term{ .out = &w, .color = false };
    try t.err("oops", .{});
    const written = buf[0..w.end];
    try testing.expect(std.mem.indexOf(u8, written, "\x1b[") == null);
    try testing.expectEqualStrings("error: oops\n", written);
}

test "warn: plain output" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var t = Term{ .out = &w, .color = false };
    try t.warn("deprecated {s}", .{"foo"});
    try testing.expectEqualStrings("warning: deprecated foo\n", buf[0..w.end]);
}

test "success: plain output has no prefix" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var t = Term{ .out = &w, .color = false };
    try t.success("done", .{});
    try testing.expectEqualStrings("done\n", buf[0..w.end]);
}

test "success: colored output wraps whole line in green" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var t = Term{ .out = &w, .color = true };
    try t.success("done", .{});
    try testing.expect(std.mem.startsWith(u8, buf[0..w.end], bold_green));
    try testing.expect(std.mem.indexOf(u8, buf[0..w.end], reset) != null);
}

test "info: passthrough plain text" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var t = Term{ .out = &w, .color = true };
    try t.info("just text {d}", .{42});
    try testing.expectEqualStrings("just text 42\n", buf[0..w.end]);
}
