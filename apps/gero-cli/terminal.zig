const std = @import("std");
const builtin = @import("builtin");

const windows = std.os.windows;

/// How a platform is asked to stop line-editing on our behalf.
///
/// The axis is which interface exists, not which OS: wasi is a POSIX
/// that has no terminal control at all, and answering that with the
/// termios path is what made the CLI unbuildable for it.
const Backend = enum { termios, console, none };

const backend: Backend = switch (builtin.os.tag) {
    .windows => .console,
    .wasi, .freestanding => .none,
    else => .termios,
};

/// A terminal handle, as the standard library names it.
pub const Handle = std.Io.File.Handle;

/// The mode a terminal was in before raw mode, to hand back to
/// `restore`.
pub const Saved = switch (backend) {
    .termios => std.posix.termios,
    .console => windows.DWORD,
    .none => void,
};

pub const Error = error{
    /// The handle addresses something that is not a terminal, so it
    /// has no mode to change.
    NotATerminal,
    /// The platform refused a mode it reported as gettable.
    ModeRefused,
};

// Console input flags. `std.os.windows` binds the output-side
// `ENABLE_VIRTUAL_TERMINAL_PROCESSING` and none of the input ones.
const enable_processed_input: windows.DWORD = 0x0001;
const enable_line_input: windows.DWORD = 0x0002;
const enable_echo_input: windows.DWORD = 0x0004;
const enable_virtual_terminal_input: windows.DWORD = 0x0200;

extern "kernel32" fn GetConsoleMode(
    handle: windows.HANDLE,
    mode: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn SetConsoleMode(
    handle: windows.HANDLE,
    mode: windows.DWORD,
) callconv(.winapi) windows.BOOL;

/// Put a terminal into raw mode, returning the mode it was in.
///
/// Raw means bytes arrive as they are typed, nothing is echoed, and
/// the arrow keys arrive as escape sequences rather than being eaten
/// by the terminal's own line editing. Interrupts are deliberately
/// left alone on both platforms: Ctrl-C keeps raising rather than
/// arriving as a byte.
///
/// The returned value is the caller's to keep and hand to `restore`.
///
/// ```
/// const saved = try terminal.enableRaw(handle);
/// defer terminal.restore(handle, saved);
/// ```
pub fn enableRaw(handle: Handle) Error!Saved {
    if (comptime backend == .none) {
        // Nothing to put into raw mode. The caller reads cooked, which
        // is all a platform without a console could have offered.
        return error.NotATerminal;
    }

    if (comptime backend == .console) {
        var mode: windows.DWORD = undefined;
        if (!GetConsoleMode(handle, &mode).toBool()) return error.NotATerminal;
        var raw = mode;
        raw &= ~(enable_line_input | enable_echo_input);
        // The console's counterpart to clearing ICANON: without it the
        // arrow keys never reach a reader as CSI sequences.
        raw |= enable_virtual_terminal_input;
        // The counterpart to leaving ISIG set below.
        raw |= enable_processed_input;
        if (!SetConsoleMode(handle, raw).toBool()) return error.ModeRefused;
        return mode;
    }

    const cur = std.posix.tcgetattr(handle) catch return error.NotATerminal;
    var raw = cur;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = true;
    raw.iflag.ICRNL = false; // keep \r and \n distinguishable
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    std.posix.tcsetattr(handle, .NOW, raw) catch return error.ModeRefused;
    return cur;
}

/// Put back the mode `enableRaw` found.
///
/// Failure is swallowed: this runs on the way out, often from a
/// `defer` during unwinding, and a terminal that refuses to be
/// restored leaves nothing the caller can do about it.
pub fn restore(handle: Handle, saved: Saved) void {
    switch (comptime backend) {
        .none => {},
        .console => _ = SetConsoleMode(handle, saved),
        .termios => std.posix.tcsetattr(handle, .NOW, saved) catch {},
    }
}

// ---------- tests ----------

const testing = std.testing;

test "terminal/enableRaw: a handle that is not a terminal has no mode to set" {
    // On a platform with no terminal control this is the only answer
    // the function ever gives, which is the behaviour being pinned.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(testing.io, "not-a-tty", .{ .read = true });
    defer file.close(testing.io);

    // Both platforms reach this through a different call, and both
    // have to report it the same way — the REPL decides whether to
    // edit or to read cooked from this one answer.
    try testing.expectError(error.NotATerminal, enableRaw(file.handle));
}
