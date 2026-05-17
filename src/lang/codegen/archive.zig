/// `.gx` archive layout + small utility helpers that don't need
/// any `Emitter` state. Owns the byte-level encoding of the
/// header (per ISA §7.1), the per-bank window padding, and the
/// shared `decodeStringEscapes` / `alignUpU16` helpers used by
/// string-pool emission and global placement.
const std = @import("std");

// ---------- .gx layout constants ----------

/// 4-byte ASCII magic at the top of every `.gx` archive.
pub const gx_magic = [4]u8{ 'G', 'E', 'R', 'O' };
/// Format version stored in bytes 4-5 of the header.
pub const gx_version: u16 = 0x0002;
/// Fixed header size in bytes — every archive starts with this
/// many bytes before the base image.
pub const gx_header_size: usize = 16;

/// Per-bank disk size — 16 KiB, the size of the `0xC000..0xFEFF`
/// window in the address space. Each bank stored in the .gx
/// archive consumes exactly this many bytes (zero-padded).
pub const bank_disk_size: usize = 0x4000;

/// Window base address — every banked address resolves to
/// `window_base + offset_within_bank`.
pub const bank_window_base: u16 = 0xC000;

/// Banked flag bit in the .gx header per ISA §7.1.
pub const flag_banked: u16 = 0x0001;

// ---------- helpers ----------

/// Assemble the final `.gx` archive: 16-byte header, then the
/// base image, then each declared bank's 16 KiB window
/// (zero-padded for banks the user didn't touch).
pub fn buildArchive(
    allocator: std.mem.Allocator,
    base_image: []const u8,
    entry_point: u16,
    heap_base: u16,
    banks: *const std.AutoHashMapUnmanaged(u8, std.ArrayList(u8)),
) ![]u8 {
    // Bank count = max bank index + 1 (banks are 0-indexed). 0 if
    // no banks declared.
    var max_bank: ?u8 = null;
    var it = banks.keyIterator();
    while (it.next()) |b| {
        if (max_bank) |m| max_bank = @max(m, b.*) else max_bank = b.*;
    }
    // @as: widen u8 max_bank to u16 so `+ 1` doesn't overflow when max_bank == 255.
    const bank_count: u16 = if (max_bank) |m| @as(u16, m) + 1 else 0;
    // @as: bank_count ≤ 256 by u8 input; the byte total fits usize.
    const banked_bytes: usize = @as(usize, bank_count) * bank_disk_size;

    // safety: base image fits in 16-bit address space per ISA.
    const image_size: u16 = @intCast(base_image.len);
    const total = gx_header_size + base_image.len + banked_bytes;
    var out = try allocator.alloc(u8, total);
    @memset(out, 0);

    var flags: u16 = 0;
    if (bank_count > 0) flags |= flag_banked;

    @memcpy(out[0..4], &gx_magic);
    writeU16Le(out[4..6], gx_version);
    writeU16Le(out[6..8], flags);
    writeU16Le(out[8..10], entry_point);
    writeU16Le(out[10..12], image_size);
    // safety: bank_count ≤ 256 by construction.
    out[12] = @intCast(bank_count);
    out[13] = 0; // sram_bank_count
    writeU16Le(out[14..16], heap_base);

    @memcpy(out[gx_header_size..][0..base_image.len], base_image);

    // Bank buffers: each occupies `bank_disk_size` bytes (zero-
    // padded). Banks the user didn't touch stay all zeros.
    var cursor: usize = gx_header_size + base_image.len;
    var b: u16 = 0;
    while (b < bank_count) : (b += 1) {
        const dst = out[cursor..][0..bank_disk_size];
        // safety: b < bank_count ≤ 256, fits u8.
        if (banks.get(@intCast(b))) |bank_buf| {
            const n = @min(bank_buf.items.len, bank_disk_size);
            @memcpy(dst[0..n], bank_buf.items[0..n]);
        }
        cursor += bank_disk_size;
    }

    return out;
}

/// Write `value` as 2 little-endian bytes into `dst`.
pub fn writeU16Le(dst: *[2]u8, value: u16) void {
    // safety: u16 → 2 bytes by definition; no truncation possible.
    dst[0] = @intCast(value & 0xFF);
    dst[1] = @intCast(value >> 8);
}

/// Decode the standard backslash escapes (`\n`, `\r`, `\t`, `\\`,
/// `\"`, `\0`) into raw bytes. The source slice is the part
/// between the surrounding `"` delimiters with escapes still
/// encoded; the returned slice owns its bytes (caller's
/// allocator). Unknown escape sequences pass through as the
/// bare character following the backslash.
pub fn decodeStringEscapes(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c == '\\' and i + 1 < raw.len) {
            const next = raw[i + 1];
            const decoded: u8 = switch (next) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '\\' => '\\',
                '"' => '"',
                '0' => 0,
                else => next,
            };
            try out.append(allocator, decoded);
            i += 2;
            continue;
        }
        try out.append(allocator, c);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// Round `value` up to the next multiple of `align_n` (which
/// must be a power of two — the typechecker enforces). When
/// `align_n <= 1`, returns `value` unchanged.
pub fn alignUpU16(value: u16, align_n: u16) u16 {
    if (align_n <= 1) return value;
    const mask: u16 = align_n - 1;
    return (value + mask) & ~mask;
}

/// `true` when two optional bank tags refer to the same code
/// location — both `null` (base image) or both wrapping the
/// same bank index.
pub fn banksEqual(a: ?u8, b: ?u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
}
