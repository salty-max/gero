const std = @import("std");
const gero = @import("gero");
const Device = gero.vm.Device;
const MemoryMapper = gero.vm.MemoryMapper;

/// Records every access so tests can verify routing. Embeds
/// `Device` as the first field; vtable callbacks recover the
/// parent via `@fieldParentPtr`.
const RecordDevice = struct {
    device: Device,
    last_addr: u16 = 0,
    last_byte: u8 = 0,
    last_word: u16 = 0,
    canned_byte: u8 = 0,
    canned_word: u16 = 0,
    reads_b: u32 = 0,
    writes_b: u32 = 0,
    reads_w: u32 = 0,
    writes_w: u32 = 0,

    fn readByte(dev: *Device, addr: u16) u8 {
        // safety: dev points to the `device` field of a *RecordDevice
        const self: *RecordDevice = @fieldParentPtr("device", dev);
        self.last_addr = addr;
        self.reads_b += 1;
        return self.canned_byte;
    }
    fn writeByte(dev: *Device, addr: u16, value: u8) void {
        // safety: dev points to the `device` field of a *RecordDevice
        const self: *RecordDevice = @fieldParentPtr("device", dev);
        self.last_addr = addr;
        self.last_byte = value;
        self.writes_b += 1;
    }
    fn readWord(dev: *Device, addr: u16) u16 {
        // safety: dev points to the `device` field of a *RecordDevice
        const self: *RecordDevice = @fieldParentPtr("device", dev);
        self.last_addr = addr;
        self.reads_w += 1;
        return self.canned_word;
    }
    fn writeWord(dev: *Device, addr: u16, value: u16) void {
        // safety: dev points to the `device` field of a *RecordDevice
        const self: *RecordDevice = @fieldParentPtr("device", dev);
        self.last_addr = addr;
        self.last_word = value;
        self.writes_w += 1;
    }

    const vtable: Device.VTable = .{
        .readByte = readByte,
        .writeByte = writeByte,
        .readWord = readWord,
        .writeWord = writeWord,
    };

    fn init() RecordDevice {
        return .{ .device = .{ .vtable = &vtable } };
    }
};

test "mapper: with no devices mapped, RAM is accessible 0x0000-0xFFFF" {
    var m = MemoryMapper.init(std.testing.allocator);
    defer m.deinit();

    m.writeByte(0x0000, 0x11);
    m.writeByte(0xFFFF, 0x22);
    m.writeWord(0x8000, 0xDEAD);

    try std.testing.expectEqual(@as(u8, 0x11), m.readByte(0x0000));
    try std.testing.expectEqual(@as(u8, 0x22), m.readByte(0xFFFF));
    try std.testing.expectEqual(@as(u16, 0xDEAD), m.readWord(0x8000));
}

test "mapper: device-mapped range routes reads through the vtable" {
    var m = MemoryMapper.init(std.testing.allocator);
    defer m.deinit();

    var dev = RecordDevice.init();
    dev.canned_byte = 0x5A;
    dev.canned_word = 0xBEEF;
    _ = try m.map(&dev.device, 0x8000, 0x4000);

    try std.testing.expectEqual(@as(u8, 0x5A), m.readByte(0x9000));
    try std.testing.expectEqual(@as(u32, 1), dev.reads_b);
    try std.testing.expectEqual(@as(u16, 0x9000), dev.last_addr);

    try std.testing.expectEqual(@as(u16, 0xBEEF), m.readWord(0xA000));
    try std.testing.expectEqual(@as(u32, 1), dev.reads_w);
    try std.testing.expectEqual(@as(u16, 0xA000), dev.last_addr);
}

test "mapper: device-mapped range routes writes through the vtable" {
    var m = MemoryMapper.init(std.testing.allocator);
    defer m.deinit();

    var dev = RecordDevice.init();
    _ = try m.map(&dev.device, 0xFF00, 0x100);

    m.writeByte(0xFF10, 0x42);
    try std.testing.expectEqual(@as(u32, 1), dev.writes_b);
    try std.testing.expectEqual(@as(u16, 0xFF10), dev.last_addr);
    try std.testing.expectEqual(@as(u8, 0x42), dev.last_byte);

    m.writeWord(0xFF20, 0xCAFE);
    try std.testing.expectEqual(@as(u32, 1), dev.writes_w);
    try std.testing.expectEqual(@as(u16, 0xFF20), dev.last_addr);
    try std.testing.expectEqual(@as(u16, 0xCAFE), dev.last_word);
}

test "mapper: device-mapped writes never touch underlying RAM" {
    var m = MemoryMapper.init(std.testing.allocator);
    defer m.deinit();

    var dev = RecordDevice.init();
    _ = try m.map(&dev.device, 0x8000, 0x4000);

    m.writeByte(0x9000, 0xAB);
    try std.testing.expectEqual(@as(u8, 0), m.mem.readByte(0x9000));
}

test "mapper: addresses outside any region still fall through to RAM" {
    var m = MemoryMapper.init(std.testing.allocator);
    defer m.deinit();

    var dev = RecordDevice.init();
    _ = try m.map(&dev.device, 0x8000, 0x4000);

    m.writeByte(0x1000, 0x77);
    try std.testing.expectEqual(@as(u8, 0x77), m.readByte(0x1000));
    try std.testing.expectEqual(@as(u32, 0), dev.writes_b);
}

test "mapper: most-recently-mapped wins on overlap" {
    var m = MemoryMapper.init(std.testing.allocator);
    defer m.deinit();

    var old = RecordDevice.init();
    old.canned_byte = 0x11;
    var fresh = RecordDevice.init();
    fresh.canned_byte = 0x22;
    _ = try m.map(&old.device, 0x8000, 0x4000);
    _ = try m.map(&fresh.device, 0x9000, 0x1000);

    // Inside the overlap, the fresh one wins.
    try std.testing.expectEqual(@as(u8, 0x22), m.readByte(0x9000));
    try std.testing.expectEqual(@as(u32, 1), fresh.reads_b);
    try std.testing.expectEqual(@as(u32, 0), old.reads_b);

    // Outside the fresh range but inside the old, the old still wins.
    try std.testing.expectEqual(@as(u8, 0x11), m.readByte(0x8000));
    try std.testing.expectEqual(@as(u32, 1), old.reads_b);
}

test "mapper: unmap removes the region and restores fall-through" {
    var m = MemoryMapper.init(std.testing.allocator);
    defer m.deinit();

    var dev = RecordDevice.init();
    dev.canned_byte = 0x99;
    const id = try m.map(&dev.device, 0x8000, 0x100);

    try std.testing.expectEqual(@as(u8, 0x99), m.readByte(0x8000));
    try std.testing.expect(m.unmap(id));

    m.writeByte(0x8000, 0x42);
    try std.testing.expectEqual(@as(u8, 0x42), m.readByte(0x8000));
}

test "mapper: unmap returns false for an unknown id" {
    var m = MemoryMapper.init(std.testing.allocator);
    defer m.deinit();
    try std.testing.expect(!m.unmap(99));
}

test "mapper: two non-overlapping devices both work" {
    var m = MemoryMapper.init(std.testing.allocator);
    defer m.deinit();

    var vram = RecordDevice.init();
    vram.canned_byte = 0xAA;
    var io = RecordDevice.init();
    io.canned_byte = 0xBB;
    _ = try m.map(&vram.device, 0x8000, 0x4000);
    _ = try m.map(&io.device, 0xFF00, 0x100);

    try std.testing.expectEqual(@as(u8, 0xAA), m.readByte(0x8000));
    try std.testing.expectEqual(@as(u8, 0xBB), m.readByte(0xFF80));

    m.writeByte(0xA000, 0x12);
    m.writeByte(0xFFAA, 0x34);
    try std.testing.expectEqual(@as(u8, 0x12), vram.last_byte);
    try std.testing.expectEqual(@as(u8, 0x34), io.last_byte);
}

test "mapper: map rejects empty range" {
    var m = MemoryMapper.init(std.testing.allocator);
    defer m.deinit();

    var dev = RecordDevice.init();
    try std.testing.expectError(error.EmptyRange, m.map(&dev.device, 0x1000, 0));
}

test "mapper: map rejects range overflowing 64KB" {
    var m = MemoryMapper.init(std.testing.allocator);
    defer m.deinit();

    var dev = RecordDevice.init();
    // 0xFF00 + 0x100 = 0x10000 (one past the last byte) is OK.
    _ = try m.map(&dev.device, 0xFF00, 0x100);
    // 0xFF00 + 0x101 overshoots.
    try std.testing.expectError(error.RangeOverflow, m.map(&dev.device, 0xFF00, 0x101));
}

test "mapper: region inclusive at both ends" {
    var m = MemoryMapper.init(std.testing.allocator);
    defer m.deinit();

    var dev = RecordDevice.init();
    dev.canned_byte = 0x77;
    _ = try m.map(&dev.device, 0x1000, 0x10);

    try std.testing.expectEqual(@as(u8, 0x77), m.readByte(0x1000));
    try std.testing.expectEqual(@as(u8, 0x77), m.readByte(0x100F));
    m.writeByte(0x1010, 0x42);
    try std.testing.expectEqual(@as(u8, 0x42), m.readByte(0x1010));
    try std.testing.expectEqual(@as(u32, 0), dev.writes_b);
}
