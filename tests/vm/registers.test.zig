const std = @import("std");
const gero = @import("gero");
const Register = gero.vm.Register;
const Registers = gero.vm.Registers;
const Flag = gero.vm.Flag;

test "registers: init zeroes every slot" {
    const r = Registers.init();
    inline for (.{
        Register.ip, Register.acu, Register.r1, Register.r2, Register.r3,
        Register.r4, Register.r5,  Register.r6, Register.r7, Register.r8,
        Register.sp, Register.fp,  Register.mb, Register.im, Register.flg,
    }) |reg| {
        try std.testing.expectEqual(@as(u16, 0), r.read(reg));
    }
}

test "registers: read after write round-trips by name" {
    var r = Registers.init();
    r.write(.r3, 0x1234);
    try std.testing.expectEqual(@as(u16, 0x1234), r.read(.r3));
}

test "registers: each named slot independent" {
    var r = Registers.init();
    r.write(.r1, 0xAAAA);
    r.write(.r2, 0xBBBB);
    try std.testing.expectEqual(@as(u16, 0xAAAA), r.read(.r1));
    try std.testing.expectEqual(@as(u16, 0xBBBB), r.read(.r2));
}

test "registers: index 0..0x0E maps to the right named register" {
    var r = Registers.init();
    inline for (.{
        .{ 0x00, Register.ip }, .{ 0x01, Register.acu }, .{ 0x02, Register.r1 },
        .{ 0x03, Register.r2 }, .{ 0x04, Register.r3 },  .{ 0x05, Register.r4 },
        .{ 0x06, Register.r5 }, .{ 0x07, Register.r6 },  .{ 0x08, Register.r7 },
        .{ 0x09, Register.r8 }, .{ 0x0A, Register.sp },  .{ 0x0B, Register.fp },
        .{ 0x0C, Register.mb }, .{ 0x0D, Register.im },  .{ 0x0E, Register.flg },
    }) |pair| {
        const idx: u8 = pair[0];
        const named: Register = pair[1];
        const ok = r.writeByIndex(idx, 0xC0DE);
        try std.testing.expect(ok);
        try std.testing.expectEqual(@as(u16, 0xC0DE), r.read(named));
        try std.testing.expectEqual(@as(?u16, 0xC0DE), r.readByIndex(idx));
        // Reset so the next iteration sees a clean slot.
        r.write(named, 0);
    }
}

test "registers: index 0x0F..0xFF rejected" {
    var r = Registers.init();
    inline for (.{ 0x0F, 0x10, 0x42, 0xFE, 0xFF }) |idx| {
        try std.testing.expectEqual(@as(?u16, null), r.readByIndex(idx));
        try std.testing.expect(!r.writeByIndex(idx, 0x1234));
    }
}

test "flg: setFlag toggles only its target bit" {
    var r = Registers.init();
    r.setFlag(.zero, true);
    try std.testing.expect(r.flagSet(.zero));
    try std.testing.expect(!r.flagSet(.negative));
    try std.testing.expect(!r.flagSet(.carry));
    try std.testing.expect(!r.flagSet(.overflow));
    try std.testing.expect(!r.flagSet(.interrupt_disable));

    r.setFlag(.negative, true);
    try std.testing.expect(r.flagSet(.zero));
    try std.testing.expect(r.flagSet(.negative));

    r.setFlag(.zero, false);
    try std.testing.expect(!r.flagSet(.zero));
    try std.testing.expect(r.flagSet(.negative));
}

test "flg: layout — Z=0, N=1, C=2, V=3, I=4" {
    try std.testing.expectEqual(@as(u4, 0), @intFromEnum(Flag.zero));
    try std.testing.expectEqual(@as(u4, 1), @intFromEnum(Flag.negative));
    try std.testing.expectEqual(@as(u4, 2), @intFromEnum(Flag.carry));
    try std.testing.expectEqual(@as(u4, 3), @intFromEnum(Flag.overflow));
    try std.testing.expectEqual(@as(u4, 4), @intFromEnum(Flag.interrupt_disable));
}

test "flg: setFlag(false) on already-clear bit is a no-op" {
    var r = Registers.init();
    r.setFlag(.carry, false);
    try std.testing.expectEqual(@as(u16, 0), r.read(.flg));
}

test "flg: unrelated flg bits preserved across setFlag calls" {
    var r = Registers.init();
    r.write(.flg, 0xFFFF); // all bits set, including reserved
    r.setFlag(.zero, false);
    // Z (bit 0) cleared, every other bit (incl. reserved 5..15) preserved.
    try std.testing.expectEqual(@as(u16, 0xFFFE), r.read(.flg));
}
