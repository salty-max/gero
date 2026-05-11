/// 64KB linear address space, byte-addressable, with little-endian
/// `u16` helpers. Pure storage — banking and the host-pluggable
/// mapper layer on top.
const std = @import("std");

/// Total address space.
pub const size: usize = 65536;

/// Flat 64KB byte-addressable RAM.
pub const Memory = struct {
    /// Backing bytes. Public so the loader can `loadImage` and
    /// tests can inspect; production callers use the typed helpers.
    bytes: [size]u8,

    /// Fresh zeroed region.
    pub fn init() Memory {
        return .{ .bytes = @splat(0) };
    }

    /// Read one byte.
    pub fn readByte(self: Memory, addr: u16) u8 {
        return self.bytes[addr];
    }

    /// Write one byte.
    pub fn writeByte(self: *Memory, addr: u16, value: u8) void {
        self.bytes[addr] = value;
    }

    /// Word read at `0xFFFF` wraps the high byte to `0x0000` —
    /// matches real-bus behavior, deliberate.
    pub fn readWord(self: Memory, addr: u16) u16 {
        const lo: u16 = self.bytes[addr];
        const hi: u16 = self.bytes[addr +% 1];
        return lo | (hi << 8);
    }

    /// Same wrap as `readWord` for the symmetric write.
    pub fn writeWord(self: *Memory, addr: u16, value: u16) void {
        self.bytes[addr] = @truncate(value & 0xFF);
        self.bytes[addr +% 1] = @truncate((value >> 8) & 0xFF);
    }

    /// Bulk-copy `data` into RAM at `offset`. Returns the number
    /// of bytes actually written (clamped to remaining space).
    pub fn loadImage(self: *Memory, offset: u16, data: []const u8) usize {
        // @as: widen u16 → usize so the subtraction operates in usize
        const remaining = size - @as(usize, offset);
        const n = @min(remaining, data.len);
        @memcpy(self.bytes[offset..][0..n], data[0..n]);
        return n;
    }
};
