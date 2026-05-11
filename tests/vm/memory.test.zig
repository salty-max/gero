const std = @import("std");
const gero = @import("gero");
const Memory = gero.vm.Memory;

test "memory: init zeroes every byte" {
    const m = Memory.init();
    for (m.bytes) |b| {
        try std.testing.expectEqual(@as(u8, 0), b);
    }
}

test "memory: byte read/write at every offset" {
    var m = Memory.init();
    var addr: u16 = 0;
    while (true) {
        m.writeByte(addr, @truncate(addr & 0xFF));
        try std.testing.expectEqual(@as(u8, @truncate(addr & 0xFF)), m.readByte(addr));
        if (addr == 0xFFFF) break;
        addr +%= 1;
    }
}

test "memory: word writes are little-endian" {
    var m = Memory.init();
    m.writeWord(0x1000, 0xABCD);
    try std.testing.expectEqual(@as(u8, 0xCD), m.readByte(0x1000));
    try std.testing.expectEqual(@as(u8, 0xAB), m.readByte(0x1001));
}

test "memory: word reads are little-endian" {
    var m = Memory.init();
    m.writeByte(0x2000, 0x34);
    m.writeByte(0x2001, 0x12);
    try std.testing.expectEqual(@as(u16, 0x1234), m.readWord(0x2000));
}

test "memory: word round-trip at boundaries" {
    var m = Memory.init();
    inline for (.{ 0x0000, 0x00FF, 0x0100, 0x7FFF, 0x8000, 0xFFFE }) |addr| {
        m.writeWord(addr, 0xDEAD);
        try std.testing.expectEqual(@as(u16, 0xDEAD), m.readWord(addr));
    }
}

test "memory: word at 0xFFFF wraps high byte to 0x0000" {
    var m = Memory.init();
    m.writeWord(0xFFFF, 0xABCD);
    try std.testing.expectEqual(@as(u8, 0xCD), m.readByte(0xFFFF));
    try std.testing.expectEqual(@as(u8, 0xAB), m.readByte(0x0000));
    try std.testing.expectEqual(@as(u16, 0xABCD), m.readWord(0xFFFF));
}

test "memory: loadImage copies bytes at offset" {
    var m = Memory.init();
    const data = [_]u8{ 0x10, 0x00, 0x00, 0x02 }; // mov $0000, r1
    const n = m.loadImage(0x1100, &data);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(@as(u8, 0x10), m.readByte(0x1100));
    try std.testing.expectEqual(@as(u8, 0x02), m.readByte(0x1103));
    // Bytes outside the loaded range are untouched.
    try std.testing.expectEqual(@as(u8, 0), m.readByte(0x1104));
    try std.testing.expectEqual(@as(u8, 0), m.readByte(0x10FF));
}

test "memory: loadImage clamps to remaining size" {
    var m = Memory.init();
    const data: [10]u8 = @splat(0xAA);
    const n = m.loadImage(0xFFF8, &data); // 8 bytes fit, 2 truncated
    try std.testing.expectEqual(@as(usize, 8), n);
    try std.testing.expectEqual(@as(u8, 0xAA), m.readByte(0xFFFF));
}
