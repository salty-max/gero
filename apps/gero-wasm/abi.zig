//! The types that cross the `gero.wasm` boundary.
//!
//! Pure data: no state, no allocation, no I/O. A host decodes these
//! and nothing else, so their shapes and numeric values are the
//! contract — see `docs/gero-lab.md` §2.2 and `docs/versioning.md`
//! before changing one.

const std = @import("std");

/// Status codes shared by every export. A host switches on these, so
/// their numeric values are part of the boundary and must not be
/// renumbered — see `docs/versioning.md`.
pub const Status = enum(u32) {
    /// The operation produced its payload with no fatal diagnostic.
    ok = 0,
    /// The operation ran and reported diagnostics; the payload is
    /// absent or partial. Not a failure of the module.
    diagnostics = 1,
    /// `gero_init` has not been called, or returned an error.
    not_initialized = 2,
    /// The arena cannot satisfy the request. Reported rather than
    /// trapped, so a host can raise its ceiling and retry instead of
    /// meeting a dead instance.
    out_of_memory = 3,
    /// A `lang` discriminant that names no front-end.
    bad_lang = 4,
    /// A pointer / length pair that does not lie inside the arena.
    bad_argument = 5,
};

/// `bank` value asking for a `.gx`'s base image rather than one of its
/// bank windows. Bank 0 is a real window, so it cannot double as the
/// sentinel.
pub const no_bank: u32 = 0xFFFF_FFFF;

/// CPU address a bank window is mapped at, so a bank disassembly reads
/// in the addresses the program will branch to rather than in offsets.
pub const bank_window_base: u16 = 0xC000;

/// Which front-end a source buffer belongs to. Passed as a `u32` so
/// one `Result` shape serves both languages.
pub const Lang = enum(u32) {
    gas = 0,
    gr = 1,

    /// Decode a host-supplied discriminant, or `null` when it names
    /// no front-end.
    pub fn from(value: u32) ?Lang {
        return switch (value) {
            0 => .gas,
            1 => .gr,
            else => null,
        };
    }
};

/// What every export returns: a pointer to one of these, in module
/// memory, valid until the next call.
///
/// Fixed layout, little-endian, five `u32` fields in this order — a
/// host decodes it with five reads at known offsets and no schema.
/// The payload stays raw bytes (a `.gx` image, or formatted text);
/// only the diagnostics are JSON, because that is the one part with a
/// shape worth sharing with the CLI.
pub const Result = extern struct {
    status: u32,
    /// `.gx` bytes or formatted UTF-8, or 0 when there is none.
    payload_ptr: u32,
    payload_len: u32,
    /// UTF-8 JSON: an array of the objects `gero check --format=json`
    /// emits. `0` when the operation reported none.
    diagnostics_ptr: u32,
    diagnostics_len: u32,

    /// Bytes a host reads to decode one. Part of the boundary.
    pub const encoded_size: usize = 20;
};

// ---------- tests ----------

test "Result: the encoded size a host decodes against" {
    // A host reads five u32s at fixed offsets. If this changes, every
    // decoder breaks — so it is pinned here as well as exported.
    try std.testing.expectEqual(@as(usize, 20), Result.encoded_size);
    try std.testing.expectEqual(@sizeOf(Result), Result.encoded_size);
}

test "Lang: only the two discriminants decode" {
    try std.testing.expectEqual(Lang.gas, Lang.from(0).?);
    try std.testing.expectEqual(Lang.gr, Lang.from(1).?);
    // Anything else is a reported `bad_lang`, not a wild cast.
    try std.testing.expect(Lang.from(2) == null);
    try std.testing.expect(Lang.from(std.math.maxInt(u32)) == null);
}
