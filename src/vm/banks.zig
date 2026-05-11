/// Bank pool — the 16KB pages that mirror into the bank window
/// at `0xC000..0xFEFF`. Bytes outside the window are out of
/// scope here; the VM only routes window accesses through the
/// pool.
///
/// The last `sram_bank_count` banks are battery-backed: the host
/// is expected to persist `sramSlice` and to restore it via
/// `initWithImage` on the next boot. The pool itself does not do
/// any I/O.
const std = @import("std");

/// Size of a single bank, matching the window size.
pub const bank_size: usize = 0x4000;

/// Lowest address that maps into the bank window.
pub const window_base: u16 = 0xC000;

/// Highest address inclusive that maps into the bank window.
pub const window_end: u16 = 0xFEFF;

/// Read of an out-of-range `mb` returns this byte per spec.
pub const out_of_range_byte: u8 = 0xFF;

/// Errors returned by the bank-pool constructors.
pub const BanksError = error{
    /// `sram_bank_count > bank_count`.
    InvalidSramCount,
    /// Provided image is not `bank_count * bank_size` bytes.
    ImageSizeMismatch,
};

/// Allocator-owned bank pool.
pub const Banks = struct {
    data: []u8,
    bank_count: u8,
    sram_bank_count: u8,
    allocator: std.mem.Allocator,

    /// Fresh zeroed pool with `bank_count` banks. Use when the
    /// host has no save store yet — every byte starts at zero.
    pub fn init(
        allocator: std.mem.Allocator,
        bank_count: u8,
        sram_bank_count: u8,
    ) (std.mem.Allocator.Error || BanksError)!Banks {
        if (sram_bank_count > bank_count) return error.InvalidSramCount;
        const data = try allocator.alloc(u8, bank_size * bank_count);
        @memset(data, 0);
        return .{
            .data = data,
            .bank_count = bank_count,
            .sram_bank_count = sram_bank_count,
            .allocator = allocator,
        };
    }

    /// Pool seeded from an existing image. Copies the bytes so
    /// the caller can release its buffer immediately after.
    pub fn initWithImage(
        allocator: std.mem.Allocator,
        image: []const u8,
        bank_count: u8,
        sram_bank_count: u8,
    ) (std.mem.Allocator.Error || BanksError)!Banks {
        if (sram_bank_count > bank_count) return error.InvalidSramCount;
        // @as: widen u8 bank_count to usize for the byte-count math
        const expected = bank_size * @as(usize, bank_count);
        if (image.len != expected) return error.ImageSizeMismatch;
        const data = try allocator.alloc(u8, expected);
        @memcpy(data, image);
        return .{
            .data = data,
            .bank_count = bank_count,
            .sram_bank_count = sram_bank_count,
            .allocator = allocator,
        };
    }

    /// Release the bank buffer.
    pub fn deinit(self: *Banks) void {
        self.allocator.free(self.data);
    }

    fn offsetOf(addr: u16) usize {
        return addr - window_base;
    }

    fn slotAt(self: Banks, mb: u16, addr: u16) ?usize {
        if (mb >= self.bank_count) return null;
        // @as: widen mb to usize so the bank-offset math doesn't wrap
        return (@as(usize, mb) * bank_size) + offsetOf(addr);
    }

    /// Read a byte from the bank window. Out-of-range `mb`
    /// returns `0xFF` per the permissive spec.
    pub fn readByte(self: Banks, mb: u16, addr: u16) u8 {
        if (self.slotAt(mb, addr)) |i| return self.data[i];
        return out_of_range_byte;
    }

    /// Write a byte into the bank window. Out-of-range `mb`
    /// drops the write silently.
    pub fn writeByte(self: *Banks, mb: u16, addr: u16, value: u8) void {
        if (self.slotAt(mb, addr)) |i| self.data[i] = value;
    }

    /// Word read that wraps the high byte to the window base if
    /// `addr` is at the very top of the window (matches the
    /// `Memory.readWord` wrap behavior at `0xFFFF`).
    pub fn readWord(self: Banks, mb: u16, addr: u16) u16 {
        const lo: u16 = self.readByte(mb, addr);
        const hi: u16 = self.readByte(mb, addr +% 1);
        return lo | (hi << 8);
    }

    /// Same wrap rule as `readWord` for the symmetric write.
    pub fn writeWord(self: *Banks, mb: u16, addr: u16, value: u16) void {
        self.writeByte(mb, addr, @truncate(value & 0xFF));
        self.writeByte(mb, addr +% 1, @truncate((value >> 8) & 0xFF));
    }

    /// Read-only slice of the SRAM portion of the pool. The host
    /// persists this to disk; on the next boot the same bytes go
    /// back in via `initWithImage`'s `image` argument (with the
    /// non-SRAM banks reproduced from the original `.gx`).
    pub fn sramSlice(self: Banks) []const u8 {
        // @as: widen sram_bank_count to usize for the byte count
        const sram_bytes = @as(usize, self.sram_bank_count) * bank_size;
        if (sram_bytes == 0) return self.data[0..0];
        return self.data[self.data.len - sram_bytes ..];
    }

    /// Mutable variant — used by the host to seed SRAM on reload.
    pub fn sramSliceMut(self: *Banks) []u8 {
        // @as: widen sram_bank_count to usize for the byte count
        const sram_bytes = @as(usize, self.sram_bank_count) * bank_size;
        if (sram_bytes == 0) return self.data[0..0];
        return self.data[self.data.len - sram_bytes ..];
    }
};

/// `true` when `addr` falls inside the bank-window range.
pub fn inWindow(addr: u16) bool {
    return addr >= window_base and addr <= window_end;
}
