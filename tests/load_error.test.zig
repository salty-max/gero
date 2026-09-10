//! Mirror file for `src/load_error.zig`.
//!
//! Every consumer that opens a `.gx` shares these messages, so the same
//! broken file explains itself the same way in a terminal, an editor,
//! and the browser playground.

const std = @import("std");
const gero = @import("gero");

const testing = std.testing;
const describe = gero.load_error.describe;
const max_message_len = gero.load_error.max_message_len;

/// A 16-byte header carrying `version`, otherwise well-formed.
fn headerWith(buf: *[16]u8, version: u16) []const u8 {
    @memset(buf, 0);
    @memcpy(buf[0..4], "GERO");
    gero.gx.writeU16Le(buf[4..6], version);
    return buf;
}

test "describe: a rejected version names both, in either direction" {
    var header: [16]u8 = undefined;
    var msg_buf: [max_message_len]u8 = undefined;

    // A reader cannot act on "wrong version" alone — it needs the
    // file's and its own, whichever way they differ.
    const future = describe(&msg_buf, error.UnsupportedVersion, headerWith(&header, gero.gx.version + 0x0100));
    try testing.expect(std.mem.indexOf(u8, future, "2.0") != null);
    try testing.expect(std.mem.indexOf(u8, future, "1.0") != null);

    var past_buf: [max_message_len]u8 = undefined;
    const past = describe(&past_buf, error.UnsupportedVersion, headerWith(&header, 0x0004));
    try testing.expect(std.mem.indexOf(u8, past, "0.4") != null);
    try testing.expect(std.mem.indexOf(u8, past, "1.0") != null);
}

test "describe: a version too short to read reports unknown, not garbage" {
    var msg_buf: [max_message_len]u8 = undefined;
    const msg = describe(&msg_buf, error.UnsupportedVersion, "GE");
    try testing.expect(std.mem.indexOf(u8, msg, "unknown") != null);
}

test "describe: a malformed file does not suggest upgrading" {
    var msg_buf: [max_message_len]u8 = undefined;
    // Upgrading fixes a file from the future; it fixes nothing about a
    // file that is simply wrong, so the wording must not imply it.
    for ([_]gero.vm.LoaderError{
        error.BadMagic,
        error.TooSmall,
        error.ImageSizeMismatch,
        error.BanksSizeMismatch,
        error.InvalidSramCount,
        error.HeapInsideImage,
        error.HeapInBankWindow,
    }) |err| {
        const msg = describe(&msg_buf, err, "GERO");
        try testing.expect(std.mem.indexOf(u8, msg, "upgrade") == null);
    }
}

test "describe: every LoaderError renders a sentence, never an error name" {
    var msg_buf: [max_message_len]u8 = undefined;
    inline for (@typeInfo(gero.vm.LoaderError).error_set.?) |e| {
        const err: gero.vm.LoaderError = @field(gero.vm.LoaderError, e.name);
        const msg = describe(&msg_buf, err, "GERO");
        try testing.expect(msg.len > 0);
        // The bug this replaced: surfacing `@errorName` at the user.
        try testing.expect(std.mem.indexOf(u8, msg, e.name) == null);
    }
}
