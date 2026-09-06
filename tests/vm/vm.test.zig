const std = @import("std");
const gero = @import("gero");
const VM = gero.vm.VM;

test "vm: init sets boot-state special registers" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    try std.testing.expectEqual(@as(u16, 0), vm.regs.read(.ip));
    try std.testing.expectEqual(@as(u16, 0), vm.regs.read(.acu));
    try std.testing.expectEqual(@as(u16, 0), vm.regs.read(.r1));
    try std.testing.expectEqual(@as(u16, gero.vm.sp_boot), vm.regs.read(.sp));
    try std.testing.expectEqual(@as(u16, gero.vm.fp_boot), vm.regs.read(.fp));
    try std.testing.expectEqual(@as(u16, 0), vm.regs.read(.mb));
    try std.testing.expectEqual(@as(u16, gero.vm.im_boot), vm.regs.read(.im));
    try std.testing.expectEqual(@as(u16, 0), vm.regs.read(.flg));
}

test "vm: init zeroes memory" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    try std.testing.expectEqual(@as(u8, 0), vm.mmap.readByte(0));
    try std.testing.expectEqual(@as(u8, 0), vm.mmap.readByte(0x1100));
    try std.testing.expectEqual(@as(u8, 0), vm.mmap.readByte(0xFFFF));
}

test "vm: bootInitRegisters resets registers but preserves memory" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0xDEAD);
    vm.regs.write(.flg, 0xFFFF);
    vm.mmap.writeByte(0x1100, 0x42);

    vm.bootInitRegisters();

    try std.testing.expectEqual(@as(u16, 0), vm.regs.read(.r1));
    try std.testing.expectEqual(@as(u16, 0), vm.regs.read(.flg));
    try std.testing.expectEqual(@as(u16, gero.vm.sp_boot), vm.regs.read(.sp));
    // Memory deliberately preserved across re-boot.
    try std.testing.expectEqual(@as(u8, 0x42), vm.mmap.readByte(0x1100));
}

test "vm: registers and memory are independently mutable" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0xAAAA);
    vm.mmap.writeWord(0x2000, 0xBBBB);
    try std.testing.expectEqual(@as(u16, 0xAAAA), vm.regs.read(.r1));
    try std.testing.expectEqual(@as(u16, 0xBBBB), vm.mmap.readWord(0x2000));
}

test "vm: multiple VM instances are independent" {
    var a = VM.init(std.testing.allocator);
    defer a.deinit();
    var b = VM.init(std.testing.allocator);
    defer b.deinit();
    a.regs.write(.r1, 0x1111);
    a.mmap.writeByte(0x100, 0x42);
    try std.testing.expectEqual(@as(u16, 0), b.regs.read(.r1));
    try std.testing.expectEqual(@as(u8, 0), b.mmap.readByte(0x100));
}

// ---------- snapshot / restore ----------

const alloc = std.testing.allocator;

/// A device that counts writes, standing in for a live host peripheral.
const CountingDevice = struct {
    writes: usize = 0,
    device: gero.vm.Device = .{ .vtable = &vtable },

    const vtable: gero.vm.Device.VTable = .{
        .readByte = readByte,
        .writeByte = writeByte,
        .readWord = readWord,
        .writeWord = writeWord,
    };

    fn readByte(_: *gero.vm.Device, _: u16) u8 {
        return 0;
    }
    fn writeByte(d: *gero.vm.Device, _: u16, _: u8) void {
        // safety: the mapper hands back the `device` field this struct owns.
        const self: *CountingDevice = @fieldParentPtr("device", d);
        self.writes += 1;
    }
    fn readWord(_: *gero.vm.Device, _: u16) u16 {
        return 0;
    }
    fn writeWord(d: *gero.vm.Device, _: u16, _: u16) void {
        // safety: as above.
        const self: *CountingDevice = @fieldParentPtr("device", d);
        self.writes += 1;
    }
};

test "snapshot: restoring returns registers, RAM and cycles to the captured point" {
    var vm = VM.init(alloc);
    defer vm.deinit();
    vm.regs.write(.acu, 0x1234);
    vm.mmap.mem.bytes[0x2000] = 42;
    vm.cycles = 7;

    var snap = try vm.snapshot(alloc);
    defer snap.deinit();

    vm.regs.write(.acu, 0xFFFF);
    vm.mmap.mem.bytes[0x2000] = 99;
    vm.cycles = 500;

    try vm.restore(snap);
    try std.testing.expectEqual(@as(u16, 0x1234), vm.regs.read(.acu));
    try std.testing.expectEqual(@as(u8, 42), vm.mmap.mem.bytes[0x2000]);
    try std.testing.expectEqual(@as(u64, 7), vm.cycles);
}

test "snapshot: the capture is independent of later writes" {
    var vm = VM.init(alloc);
    defer vm.deinit();
    vm.mmap.mem.bytes[0x300] = 1;

    var snap = try vm.snapshot(alloc);
    defer snap.deinit();

    // Writing through the VM must not reach the captured buffer — a
    // shared allocation is the failure this API exists to prevent.
    vm.mmap.mem.bytes[0x300] = 2;
    try std.testing.expectEqual(@as(u8, 1), snap.ram[0x300]);
}

test "snapshot: two captures of one VM are independent" {
    var vm = VM.init(alloc);
    defer vm.deinit();
    vm.mmap.mem.bytes[0x400] = 10;
    var a = try vm.snapshot(alloc);
    defer a.deinit();

    vm.mmap.mem.bytes[0x400] = 20;
    var b = try vm.snapshot(alloc);
    defer b.deinit();

    try std.testing.expectEqual(@as(u8, 10), a.ram[0x400]);
    try std.testing.expectEqual(@as(u8, 20), b.ram[0x400]);
}

test "snapshot: mapped devices survive a restore" {
    var vm = VM.init(alloc);
    defer vm.deinit();
    var dev: CountingDevice = .{};
    _ = try vm.mmap.map(&dev.device, 0x8000, 0x100);

    vm.mmap.writeByte(0x8000, 1);
    try std.testing.expectEqual(@as(usize, 1), dev.writes);

    var snap = try vm.snapshot(alloc);
    defer snap.deinit();
    try vm.restore(snap);

    // The device stays mapped and stays the same object: a restore
    // returns what the program can change, not what the host owns.
    vm.mmap.writeByte(0x8000, 1);
    try std.testing.expectEqual(@as(usize, 2), dev.writes);
}

test "snapshot: a device's own state is not captured" {
    var vm = VM.init(alloc);
    defer vm.deinit();
    var dev: CountingDevice = .{};
    _ = try vm.mmap.map(&dev.device, 0x8000, 0x100);

    var snap = try vm.snapshot(alloc);
    defer snap.deinit();
    vm.mmap.writeByte(0x8000, 1);
    try vm.restore(snap);

    // The write happened host-side and a restore cannot undo it.
    try std.testing.expectEqual(@as(usize, 1), dev.writes);
}

test "snapshot: bank contents round-trip" {
    var vm = VM.init(alloc);
    defer vm.deinit();
    try vm.installBanks(alloc, 4, 0);
    vm.regs.write(.mb, 1);
    vm.mmap.writeByte(0xC000, 77);

    var snap = try vm.snapshot(alloc);
    defer snap.deinit();

    vm.mmap.writeByte(0xC000, 99);
    try vm.restore(snap);
    try std.testing.expectEqual(@as(u8, 77), vm.mmap.readByte(0xC000));
}

test "snapshot: an unbanked VM captures no bank pool" {
    var vm = VM.init(alloc);
    defer vm.deinit();
    var snap = try vm.snapshot(alloc);
    defer snap.deinit();
    try std.testing.expect(snap.banks == null);
    try vm.restore(snap);
}

test "snapshot: restoring a banked capture into an unbanked VM is rejected" {
    var banked = VM.init(alloc);
    defer banked.deinit();
    try banked.installBanks(alloc, 2, 0);
    var snap = try banked.snapshot(alloc);
    defer snap.deinit();

    var plain = VM.init(alloc);
    defer plain.deinit();
    try std.testing.expectError(error.BankShapeMismatch, plain.restore(snap));
}
