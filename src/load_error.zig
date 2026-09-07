// Turning a `.gx` load failure into something a user can act on.
//
// Every consumer that opens a `.gx` shares this, so the same broken
// file explains itself the same way in a terminal, in an editor, and
// in the browser playground.

const std = @import("std");
const vm = @import("vm/vm.zig");
const gx = @import("gx.zig");

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
    err: vm.LoaderError,
    bytes: []const u8,
) []const u8 {
    return switch (err) {
        error.UnsupportedVersion => blk: {
            var file_buf: [16]u8 = undefined;
            var supported_buf: [16]u8 = undefined;
            const found = formatVersion(&file_buf, declaredVersion(bytes));
            const supported = formatVersion(&supported_buf, vm.version_target);
            const template = "built for .gx format {s}, but this build supports up to {s} — upgrade gero to open it";
            // allow-strict: both versions render in under 16 bytes, so the sentence always fits `max_message_len`.
            break :blk std.fmt.bufPrint(buf, template, .{ found, supported }) catch unreachable;
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
    return gx.readU16Le(bytes[version_offset..][0..2]);
}

/// Render a format version as `major.minor`, matching how ISA §10
/// talks about them rather than echoing the raw `0xMMmm` word.
fn formatVersion(buf: *[16]u8, version: ?u16) []const u8 {
    const v = version orelse return "an unknown version";
    // allow-strict: two bytes render as at most "255.255", well inside 16.
    return std.fmt.bufPrint(buf, "{d}.{d}", .{ v >> 8, v & 0xFF }) catch unreachable;
}
