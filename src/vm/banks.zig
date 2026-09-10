const std = @import("std");

/// Single-bank size.
pub const bank_size: usize = 0x4000;

/// Lowest address mapped into the bank window.
///
/// The window is exactly `bank_size` bytes and ends below the IO page,
/// so every byte of a bank is addressable and no host register can be
/// swapped out from under a program by a write to `mb`.
pub const window_base: u16 = 0xBE00;

/// Highest address (inclusive) mapped into the bank window.
pub const window_end: u16 = window_base + bank_size - 1;

/// Byte returned for reads through an out-of-range `mb`.
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

    /// Fresh zeroed pool with `bank_count` banks.
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

    /// Pool seeded from `image`. The bytes are copied; the caller
    /// may free its buffer on return.
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
        // The window is exactly one bank, so an address outside it has
        // no slot at all. Answering with one would index a neighbouring
        // bank, or past the pool entirely.
        if (!inWindow(addr)) return null;
        // @as: widen mb to usize so the bank-offset math doesn't wrap
        return (@as(usize, mb) * bank_size) + offsetOf(addr);
    }

    /// Read a byte from the bank window. Out-of-range `mb`
    /// returns `0xFF`.
    pub fn readByte(self: Banks, mb: u16, addr: u16) u8 {
        if (self.slotAt(mb, addr)) |i| return self.data[i];
        return out_of_range_byte;
    }

    /// Write a byte into the bank window. Out-of-range `mb`
    /// silently drops the write.
    pub fn writeByte(self: *Banks, mb: u16, addr: u16, value: u8) void {
        if (self.slotAt(mb, addr)) |i| self.data[i] = value;
    }

    /// Word read. Wraps at the top of the window, matching
    /// `Memory.readWord`.
    pub fn readWord(self: Banks, mb: u16, addr: u16) u16 {
        const lo: u16 = self.readByte(mb, addr);
        const hi: u16 = self.readByte(mb, addr +% 1);
        return lo | (hi << 8);
    }

    /// Word write. Same wrap rule as `readWord`.
    pub fn writeWord(self: *Banks, mb: u16, addr: u16, value: u16) void {
        self.writeByte(mb, addr, @truncate(value & 0xFF));
        self.writeByte(mb, addr +% 1, @truncate((value >> 8) & 0xFF));
    }

    /// Read-only SRAM slice. Host persists this to disk; pass it
    /// back through `initWithImage` on the next boot.
    pub fn sramSlice(self: Banks) []const u8 {
        // @as: widen sram_bank_count to usize for the byte count
        const sram_bytes = @as(usize, self.sram_bank_count) * bank_size;
        if (sram_bytes == 0) return self.data[0..0];
        return self.data[self.data.len - sram_bytes ..];
    }

    /// Mutable SRAM slice. Host seeds this on reload.
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
