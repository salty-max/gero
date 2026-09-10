const std = @import("std");

// ---------- .gx layout ----------
//
// The container format lives in `src/gx.zig` so the assembler and the
// compiler cannot stamp different headers for the same ISA. Only what
// lang codegen reaches for directly is mirrored here.

/// Per-bank disk size — 16 KiB, matching the bank window.
pub const bank_disk_size: usize = 0x4000;

/// Window base address — every banked address resolves to
/// `window_base + offset_within_bank`.
pub const bank_window_base: u16 = 0xBE00;

/// Write `value` as 2 little-endian bytes into `dst`.
pub fn writeU16Le(dst: *[2]u8, value: u16) void {
    // safety: u16 → 2 bytes by definition; no truncation possible.
    dst[0] = @intCast(value & 0xFF);
    dst[1] = @intCast(value >> 8);
}

// ---------- helpers ----------

/// Decode the standard backslash escapes (`\n`, `\r`, `\t`, `\\`,
/// `\"`, `\0`) plus the interpolation escape `$$` → `$` (§3.2.2) into
/// raw bytes. The source slice is the part between the surrounding `"`
/// delimiters with escapes still encoded; the returned slice owns its
/// bytes (caller's allocator). Unknown escape sequences pass through as
/// the bare character following the backslash.
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
        // `$$` is the escape for a literal `$` (the lexer leaves it in the
        // literal run; a lone `$` — e.g. `$5` — passes through unchanged).
        if (c == '$' and i + 1 < raw.len and raw[i + 1] == '$') {
            try out.append(allocator, '$');
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
