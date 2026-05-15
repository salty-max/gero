/// `.gx` bytecode-file parser. Validates the 16-byte header,
/// confirms the image / bank sections fit, and hands back
/// slices the caller can copy into a VM. No allocation; the
/// returned slices borrow from the input buffer.
const std = @import("std");

/// Magic bytes at offset `0x00..0x04`.
pub const magic: [4]u8 = .{ 'G', 'E', 'R', 'O' };

/// ISA version this loader accepts (high byte = major, low =
/// minor). Files with a higher major are rejected; same major
/// + higher minor are accepted (backwards-compatible additions).
pub const version_target: u16 = 0x0001;

/// Header bytes — fixed 16-byte prefix.
pub const header_size: usize = 16;

/// Single-bank size on disk (matches the in-memory bank size).
pub const bank_disk_size: usize = 0x4000;

/// Flag bit 0: bank section follows the base image.
pub const flag_banked: u16 = 0b0000_0000_0000_0001;
/// Flag bit 1: debug-symbol section follows the banks.
pub const flag_has_debug: u16 = 0b0000_0000_0000_0010;
/// All bits the loader recognizes; the rest are reserved and
/// must be `0`.
pub const flag_known_mask: u16 = flag_banked | flag_has_debug;

/// Errors returned by the parser.
pub const LoaderError = error{
    /// File shorter than the 16-byte header.
    TooSmall,
    /// First four bytes aren't `'G' 'E' 'R' 'O'`.
    BadMagic,
    /// Major version exceeds what this loader supports.
    UnsupportedVersion,
    /// `flags` has a reserved bit set, or the trailing
    /// `reserved` field is non-zero.
    ReservedBitsSet,
    /// `sram_bank_count > bank_count`.
    InvalidSramCount,
    /// File too short for the declared `image_size`.
    ImageSizeMismatch,
    /// `banked` flag set but the file is too short for the
    /// declared `bank_count` banks.
    BanksSizeMismatch,
};

/// Parsed file header.
pub const Header = struct {
    version: u16,
    flags: u16,
    entry_point: u16,
    image_size: u16,
    bank_count: u8,
    sram_bank_count: u8,

    /// `true` when the file carries a bank-pool section.
    pub fn isBanked(self: Header) bool {
        return (self.flags & flag_banked) != 0;
    }

    /// `true` when the file carries a debug-symbol section.
    pub fn hasDebugSymbols(self: Header) bool {
        return (self.flags & flag_has_debug) != 0;
    }
};

/// Output of `parse` — header plus borrowed slices into the
/// input buffer. `banks` and `debug` are empty when the
/// corresponding flag is clear.
pub const LoadedProgram = struct {
    header: Header,
    image: []const u8,
    banks: []const u8,
    debug: []const u8,
};

fn readU16Le(bytes: []const u8, offset: usize) u16 {
    const lo: u16 = bytes[offset];
    const hi: u16 = bytes[offset + 1];
    return lo | (hi << 8);
}

/// Validate + parse a `.gx` buffer.
pub fn parse(bytes: []const u8) LoaderError!LoadedProgram {
    if (bytes.len < header_size) return error.TooSmall;
    if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.BadMagic;

    const version = readU16Le(bytes, 0x04);
    // Major check: high byte must match.
    if ((version >> 8) > (version_target >> 8)) return error.UnsupportedVersion;

    const flags = readU16Le(bytes, 0x06);
    if ((flags & ~flag_known_mask) != 0) return error.ReservedBitsSet;

    const entry_point = readU16Le(bytes, 0x08);
    const image_size = readU16Le(bytes, 0x0A);
    const bank_count = bytes[0x0C];
    const sram_bank_count = bytes[0x0D];
    const reserved = readU16Le(bytes, 0x0E);
    if (reserved != 0) return error.ReservedBitsSet;
    if (sram_bank_count > bank_count) return error.InvalidSramCount;

    const image_start = header_size;
    // @as: widen u16 image_size to usize for slice-end math
    const image_end = image_start + @as(usize, image_size);
    if (bytes.len < image_end) return error.ImageSizeMismatch;
    const image = bytes[image_start..image_end];

    var banks: []const u8 = bytes[image_end..image_end];
    var cursor = image_end;
    if ((flags & flag_banked) != 0) {
        // @as: widen u8 bank_count to usize for the byte total
        const banks_bytes = bank_disk_size * @as(usize, bank_count);
        const banks_end = cursor + banks_bytes;
        if (bytes.len < banks_end) return error.BanksSizeMismatch;
        banks = bytes[cursor..banks_end];
        cursor = banks_end;
    }

    var debug: []const u8 = bytes[cursor..cursor];
    if ((flags & flag_has_debug) != 0) {
        // Debug symbols are variable-length; the loader exposes
        // the trailing slice as-is. The disassembler parses it on
        // demand.
        debug = bytes[cursor..];
    }

    return .{
        .header = .{
            .version = version,
            .flags = flags,
            .entry_point = entry_point,
            .image_size = image_size,
            .bank_count = bank_count,
            .sram_bank_count = sram_bank_count,
        },
        .image = image,
        .banks = banks,
        .debug = debug,
    };
}
