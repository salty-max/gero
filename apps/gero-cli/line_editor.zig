const std = @import("std");

const terminal = @import("terminal.zig");

/// Outcome of one `readLine` call.
pub const Action = union(enum) {
    /// User pressed Enter. Owns the line text (no trailing `\n`).
    submit: []const u8,
    /// Stdin closed (Ctrl-D on empty line, or piped input ended).
    eof,
    /// User pressed Ctrl-C — caller discards the partial line and
    /// re-prompts.
    cancel,
};

/// Raw-mode line editor with up/down history navigation. Falls
/// back to a line-buffered cooked read when stdin is not a TTY
/// (piped scripts, CI captures).
pub const Editor = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    /// Submitted lines in arrival order. Owned strings.
    history: std.ArrayList([]const u8),
    /// `true` when stdin is a TTY and raw mode is workable.
    is_tty: bool,
    /// The terminal mode found before raw mode, for restore-on-exit.
    /// `null` when raw mode is inactive — either because stdin isn't a
    /// TTY or because `restoreTerminal` already ran.
    saved_mode: ?terminal.Saved,
    stdin: std.Io.File,
    /// Lazily-initialized cooked-mode reader. Only used when
    /// `is_tty == false`.
    cooked: ?CookedReader,

    const CookedReader = struct {
        reader: std.Io.File.Reader,
        buf: [256]u8,
    };

    /// Initialize an editor against `stdout`. Detects TTY but does
    /// not enable raw mode — call `enableRawMode` before the read
    /// loop and `restoreTerminal` on exit.
    pub fn init(
        arena: std.mem.Allocator,
        io: std.Io,
        stdout: *std.Io.Writer,
    ) Editor {
        const stdin = std.Io.File.stdin();
        const is_tty = stdin.isTty(io) catch false;
        return .{
            .arena = arena,
            .io = io,
            .stdout = stdout,
            .history = .empty,
            .is_tty = is_tty,
            .saved_mode = null,
            .stdin = stdin,
            .cooked = null,
        };
    }

    /// Release editor-owned resources and restore the terminal.
    pub fn deinit(self: *Editor) void {
        self.restoreTerminal();
        self.history.deinit(self.arena);
    }

    /// Switch the terminal into raw mode (no echo, no line
    /// buffering). No-op when stdin isn't a TTY or raw is already
    /// active.
    pub fn enableRawMode(self: *Editor) !void {
        if (!self.is_tty) return;
        if (self.saved_mode != null) return;
        self.saved_mode = try terminal.enableRaw(self.stdin.handle);
        // `redraw` writes CSI sequences, which a Windows console only
        // interprets once virtual-terminal processing is on. The
        // standard library owns that switch; a console that refuses it
        // still edits, it just redraws the whole line.
        std.Io.File.stdout().enableAnsiEscapeCodes(self.io) catch {};
    }

    /// Restore the mode raw mode replaced. Safe to call repeatedly.
    pub fn restoreTerminal(self: *Editor) void {
        if (self.saved_mode) |mode| {
            terminal.restore(self.stdin.handle, mode);
            self.saved_mode = null;
        }
    }

    /// Append `line` to the history ring. Drops empty lines and
    /// consecutive duplicates of the previous entry.
    pub fn pushHistory(self: *Editor, line: []const u8) !void {
        if (line.len == 0) return;
        if (self.history.items.len > 0) {
            const last = self.history.items[self.history.items.len - 1];
            if (std.mem.eql(u8, last, line)) return;
        }
        const owned = try self.arena.dupe(u8, line);
        try self.history.append(self.arena, owned);
    }

    /// Read one logical line, printing `prompt` first. Handles
    /// printable input, Backspace, Enter, Ctrl-C, Ctrl-D, and
    /// Up/Down history navigation.
    pub fn readLine(self: *Editor, prompt: []const u8) !Action {
        if (!self.is_tty) return self.readLineCooked(prompt);
        // A terminal that will not go raw can still be read. Losing
        // line editing is worth a degraded prompt; losing the REPL is
        // not.
        self.enableRawMode() catch {
            self.is_tty = false;
            return self.readLineCooked(prompt);
        };
        try self.stdout.writeAll(prompt);
        try self.stdout.flush();

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.arena);
        // `hist_pos` indexes into history; `len` means "live input
        // (not navigating yet)".
        var hist_pos: usize = self.history.items.len;
        // Snapshot of in-progress input the user had typed before
        // arrowing into history. Restored when the user arrows
        // back down past the most recent entry.
        var saved_live: []u8 = "";
        defer if (saved_live.len > 0) self.arena.free(saved_live);

        while (true) {
            var one: [1]u8 = undefined;
            const n = self.stdin.readStreaming(self.io, &.{&one}) catch return .eof;
            if (n == 0) return .eof;
            const b = one[0];

            switch (b) {
                '\n', '\r' => {
                    try self.stdout.writeAll("\n");
                    try self.stdout.flush();
                    return Action{ .submit = try self.arena.dupe(u8, buf.items) };
                },
                0x7F, 0x08 => {
                    if (buf.items.len == 0) continue;
                    _ = buf.pop();
                    try self.redraw(prompt, buf.items);
                },
                0x03 => {
                    try self.stdout.writeAll("^C\n");
                    try self.stdout.flush();
                    return .cancel;
                },
                0x04 => {
                    if (buf.items.len == 0) {
                        try self.stdout.writeAll("\n");
                        try self.stdout.flush();
                        return .eof;
                    }
                },
                0x1B => {
                    // CSI sequence — `\x1b [ X`.
                    var seq: [2]u8 = undefined;
                    const n2 = self.stdin.readStreaming(self.io, &.{&seq}) catch continue;
                    if (n2 < 2 or seq[0] != '[') continue;
                    switch (seq[1]) {
                        'A' => try self.recallPrev(&buf, &hist_pos, &saved_live, prompt),
                        'B' => try self.recallNext(&buf, &hist_pos, &saved_live, prompt),
                        else => {},
                    }
                },
                else => {
                    if (b >= 0x20 and b < 0x7F) {
                        try buf.append(self.arena, b);
                        var ch: [1]u8 = .{b};
                        try self.stdout.writeAll(&ch);
                        try self.stdout.flush();
                    }
                },
            }
        }
    }

    fn recallPrev(
        self: *Editor,
        buf: *std.ArrayList(u8),
        hist_pos: *usize,
        saved_live: *[]u8,
        prompt: []const u8,
    ) !void {
        if (self.history.items.len == 0) return;
        if (hist_pos.* == 0) return;
        if (hist_pos.* == self.history.items.len) {
            // First Up press: snapshot the live input so a later
            // Down past the newest entry can restore it.
            if (saved_live.*.len > 0) self.arena.free(saved_live.*);
            saved_live.* = try self.arena.dupe(u8, buf.items);
        }
        hist_pos.* -= 1;
        buf.clearRetainingCapacity();
        try buf.appendSlice(self.arena, self.history.items[hist_pos.*]);
        try self.redraw(prompt, buf.items);
    }

    fn recallNext(
        self: *Editor,
        buf: *std.ArrayList(u8),
        hist_pos: *usize,
        saved_live: *[]u8,
        prompt: []const u8,
    ) !void {
        if (hist_pos.* >= self.history.items.len) return;
        hist_pos.* += 1;
        buf.clearRetainingCapacity();
        if (hist_pos.* == self.history.items.len) {
            try buf.appendSlice(self.arena, saved_live.*);
        } else {
            try buf.appendSlice(self.arena, self.history.items[hist_pos.*]);
        }
        try self.redraw(prompt, buf.items);
    }

    fn redraw(self: *Editor, prompt: []const u8, line: []const u8) !void {
        // CR + clear-to-EOL, then redraw prompt + buffer.
        try self.stdout.writeAll("\r\x1b[K");
        try self.stdout.writeAll(prompt);
        try self.stdout.writeAll(line);
        try self.stdout.flush();
    }

    fn readLineCooked(self: *Editor, prompt: []const u8) !Action {
        try self.stdout.writeAll(prompt);
        try self.stdout.flush();
        if (self.cooked == null) {
            self.cooked = .{
                .reader = std.Io.File.stdin().reader(self.io, undefined),
                .buf = undefined,
            };
            // Reattach the reader to the field's stable buffer.
            self.cooked.?.reader = std.Io.File.stdin().reader(self.io, &self.cooked.?.buf);
        }
        const r = &self.cooked.?.reader.interface;
        var line_buf: std.ArrayList(u8) = .empty;
        defer line_buf.deinit(self.arena);
        while (true) {
            const byte = r.takeByte() catch |err| switch (err) {
                error.EndOfStream => return if (line_buf.items.len == 0)
                    Action.eof
                else
                    Action{ .submit = try self.arena.dupe(u8, line_buf.items) },
                else => return err,
            };
            if (byte == '\n') return Action{ .submit = try self.arena.dupe(u8, line_buf.items) };
            if (byte == '\r') continue;
            try line_buf.append(self.arena, byte);
        }
    }
};

// ---------- tests ----------

const testing = std.testing;

test "line_editor/pushHistory: appends new entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&stub_buf);
    // `init` probes stdin for a TTY, so `io` must be real.
    var ed = Editor.init(arena.allocator(), testing.io, &w);
    try ed.pushHistory("alpha");
    try ed.pushHistory("beta");
    try testing.expectEqual(@as(usize, 2), ed.history.items.len);
    try testing.expectEqualStrings("alpha", ed.history.items[0]);
    try testing.expectEqualStrings("beta", ed.history.items[1]);
}

test "line_editor/pushHistory: drops empty + consecutive duplicates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&stub_buf);
    // `init` probes stdin for a TTY, so `io` must be real.
    var ed = Editor.init(arena.allocator(), testing.io, &w);
    try ed.pushHistory("");
    try ed.pushHistory("alpha");
    try ed.pushHistory("alpha");
    try ed.pushHistory("beta");
    try ed.pushHistory("alpha"); // non-adjacent dup is allowed
    try testing.expectEqual(@as(usize, 3), ed.history.items.len);
    try testing.expectEqualStrings("alpha", ed.history.items[0]);
    try testing.expectEqualStrings("beta", ed.history.items[1]);
    try testing.expectEqualStrings("alpha", ed.history.items[2]);
}
