//! Turning a `.gx` load failure into something a user can act on.
//!
//! Every command that opens a `.gx` shares this, so the same broken
//! file explains itself the same way whether it was handed to `run`,
//! `info`, or `disasm`.

const std = @import("std");
const gero = @import("gero");

/// Bytes needed before the version field can be read.
const version_offset: usize = 0x04;

/// Longest message `describe` can produce, with room for both
/// rendered versions.
pub const max_message_len: usize = 256;

/// A sentence explaining `err` for the file in `bytes`, and what to do
/// about it, written into `buf`.
///
/// Takes a caller buffer rather than an allocator: the messages are
/// short and bounded, and every call site already has a stack frame to
/// spare. Nothing to free, so nothing to leak.
///
/// The distinction the wording carries is between a file from the
/// *future* — the toolchain is behind, upgrade it — and a file that is
/// *wrong*, where upgrading would change nothing.
pub fn describe(
    buf: *[max_message_len]u8,
    err: gero.vm.LoaderError,
    bytes: []const u8,
) []const u8 {
    return switch (err) {
        error.UnsupportedVersion => blk: {
            var file_buf: [16]u8 = undefined;
            var supported_buf: [16]u8 = undefined;
            // allow-strict: both versions render in under 16 bytes, so
            // the sentence always fits `max_message_len`.
            break :blk std.fmt.bufPrint(
                buf,
                "built for .gx format {s}, but this build supports up to {s} — upgrade gero to open it",
                .{
                    formatVersion(&file_buf, declaredVersion(bytes)),
                    formatVersion(&supported_buf, gero.vm.version_target),
                },
            ) catch unreachable;
        },
        error.BadMagic => "not a .gx file — it does not start with the `GERO` magic bytes",
        error.TooSmall => "too short to be a .gx file — the header alone is 16 bytes",
        error.ReservedBitsSet => "sets header flag bits this build does not recognize — it was written by a newer gero, or it is corrupt",
        error.ImageSizeMismatch => "header declares a larger image than the file holds — it is truncated or corrupt",
        error.BanksSizeMismatch => "header declares more banks than the file holds — it is truncated or corrupt",
        error.InvalidSramCount => "header declares more SRAM banks than total banks — it is corrupt",
        error.HeapInsideImage => "header puts the heap inside the program image, where allocations would overwrite code (isa.md §7.1)",
        error.HeapInBankWindow => "header puts the heap inside the bank window, where a bank switch would replace every allocation (isa.md §7.1)",
    };
}

/// The version the file claims, or `null` when it is too short to say.
/// A file that cannot even hold a version is reported as unknown
/// rather than as some number read out of adjacent bytes.
fn declaredVersion(bytes: []const u8) ?u16 {
    if (bytes.len < version_offset + 2) return null;
    return gero.gx.readU16Le(bytes[version_offset..][0..2]);
}

/// Render a format version as `major.minor`, matching how ISA §10
/// talks about them rather than echoing the raw `0xMMmm` word.
fn formatVersion(buf: *[16]u8, version: ?u16) []const u8 {
    const v = version orelse return "an unknown version";
    // allow-strict: two bytes render as at most "255.255", well inside 16.
    return std.fmt.bufPrint(buf, "{d}.{d}", .{ v >> 8, v & 0xFF }) catch unreachable;
}

// ---------- tests ----------

const testing = std.testing;

/// A 16-byte header carrying `version`, otherwise well-formed.
fn headerWith(buf: *[16]u8, version: u16) []const u8 {
    @memset(buf, 0);
    @memcpy(buf[0..4], "GERO");
    gero.gx.writeU16Le(buf[4..6], version);
    return buf;
}

test "describe: a future version names both versions and says to upgrade" {
    var header: [16]u8 = undefined;
    var msg_buf: [max_message_len]u8 = undefined;
    const msg = describe(&msg_buf, error.UnsupportedVersion, headerWith(&header, 0x0100));
    // The file's version, this build's ceiling, and the action.
    try testing.expect(std.mem.indexOf(u8, msg, "1.0") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "0.4") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "upgrade") != null);
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
