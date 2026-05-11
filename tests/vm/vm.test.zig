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
