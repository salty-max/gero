const std = @import("std");
const gero = @import("gero");
const VM = gero.vm.VM;
const Banks = gero.vm.Banks;

test "banks: window base + end are 0xC000 / 0xFEFF" {
    try std.testing.expectEqual(@as(u16, 0xC000), gero.vm.bank_window_base);
    try std.testing.expectEqual(@as(u16, 0xFEFF), gero.vm.bank_window_end);
    try std.testing.expectEqual(@as(usize, 0x4000), gero.vm.bank_size);
}

test "banks: zero pool has every byte at 0 across every bank" {
    var b = try Banks.init(std.testing.allocator, 4, 0);
    defer b.deinit();
    for ([_]u16{ 0, 1, 2, 3 }) |mb| {
        try std.testing.expectEqual(@as(u8, 0), b.readByte(mb, 0xC000));
        try std.testing.expectEqual(@as(u8, 0), b.readByte(mb, 0xFEFF));
    }
}

test "banks: write reads back from same bank, isolated from others" {
    var b = try Banks.init(std.testing.allocator, 4, 0);
    defer b.deinit();
    b.writeByte(2, 0xC000, 0x42);
    try std.testing.expectEqual(@as(u8, 0x42), b.readByte(2, 0xC000));
    // Other banks unaffected.
    try std.testing.expectEqual(@as(u8, 0), b.readByte(0, 0xC000));
    try std.testing.expectEqual(@as(u8, 0), b.readByte(1, 0xC000));
    try std.testing.expectEqual(@as(u8, 0), b.readByte(3, 0xC000));
}

test "banks: out-of-range mb reads 0xFF, writes are dropped" {
    var b = try Banks.init(std.testing.allocator, 4, 0);
    defer b.deinit();
    try std.testing.expectEqual(@as(u8, 0xFF), b.readByte(255, 0xC000));
    b.writeByte(255, 0xC000, 0x42); // dropped
    try std.testing.expectEqual(@as(u8, 0xFF), b.readByte(255, 0xC000));
    // Real banks untouched.
    try std.testing.expectEqual(@as(u8, 0), b.readByte(0, 0xC000));
}

test "banks: initWithImage rejects size mismatch + bad sram count" {
    const small = [_]u8{0} ** 100;
    try std.testing.expectError(error.ImageSizeMismatch, Banks.initWithImage(std.testing.allocator, &small, 4, 0));

    const right = [_]u8{0} ** (0x4000 * 2);
    try std.testing.expectError(error.InvalidSramCount, Banks.initWithImage(std.testing.allocator, &right, 2, 3));
}

test "banks: sramSlice exposes last N banks; empty when sram_bank_count = 0" {
    var b = try Banks.init(std.testing.allocator, 4, 2);
    defer b.deinit();
    // Write a marker at the very start of the SRAM region (= start
    // of bank 2 = byte offset 2 * 0x4000).
    b.writeByte(2, 0xC000, 0x55);
    const sram = b.sramSlice();
    try std.testing.expectEqual(@as(usize, 0x4000 * 2), sram.len);
    try std.testing.expectEqual(@as(u8, 0x55), sram[0]);

    var b2 = try Banks.init(std.testing.allocator, 4, 0);
    defer b2.deinit();
    try std.testing.expectEqual(@as(usize, 0), b2.sramSlice().len);
}

test "banks: word reads / writes are little-endian within a bank" {
    var b = try Banks.init(std.testing.allocator, 1, 0);
    defer b.deinit();
    b.writeWord(0, 0xC000, 0xABCD);
    try std.testing.expectEqual(@as(u8, 0xCD), b.readByte(0, 0xC000));
    try std.testing.expectEqual(@as(u8, 0xAB), b.readByte(0, 0xC001));
    try std.testing.expectEqual(@as(u16, 0xABCD), b.readWord(0, 0xC000));
}

// ---------- VM-level integration ----------

test "vm.readByte unbanked: bank window falls through to plain RAM" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    // No banks installed → window is plain RAM.
    vm.mmap.writeByte(0xC000, 0x42);
    try std.testing.expectEqual(@as(u8, 0x42), vm.readByte(0xC000));
}

test "vm.readByte banked: 0xC000 routes to bank mb" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    try vm.installBanks(std.testing.allocator, 4, 0);
    // Seed bank 2 directly so we can verify mb-switching.
    vm.banks.?.writeByte(2, 0xC000, 0xAA);
    vm.banks.?.writeByte(0, 0xC000, 0x11);

    vm.regs.write(.mb, 0);
    try std.testing.expectEqual(@as(u8, 0x11), vm.readByte(0xC000));

    vm.regs.write(.mb, 2);
    try std.testing.expectEqual(@as(u8, 0xAA), vm.readByte(0xC000));
}

test "vm.writeByte banked: routes to bank mb, leaves RAM untouched" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    try vm.installBanks(std.testing.allocator, 2, 0);
    vm.regs.write(.mb, 1);
    vm.writeByte(0xC000, 0x99);
    // Bank received it.
    try std.testing.expectEqual(@as(u8, 0x99), vm.banks.?.readByte(1, 0xC000));
    // Underlying RAM at 0xC000 stays zero — banking intercepts.
    try std.testing.expectEqual(@as(u8, 0), vm.mmap.mem.readByte(0xC000));
}

test "vm.readByte: out-of-window addresses bypass banking" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    try vm.installBanks(std.testing.allocator, 2, 0);
    vm.regs.write(.mb, 0);
    // Address 0x1100 is user RAM — should go through plain mmap.
    vm.mmap.writeByte(0x1100, 0xDE);
    try std.testing.expectEqual(@as(u8, 0xDE), vm.readByte(0x1100));
}

test "vm.readWord: low byte and high byte route independently across window edge" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    try vm.installBanks(std.testing.allocator, 1, 0);
    vm.regs.write(.mb, 0);

    // Word at 0xFEFF: low byte is in window (bank), high byte is
    // at 0xFF00 (outside the window → mmap).
    vm.banks.?.writeByte(0, 0xFEFF, 0xAA);
    vm.mmap.writeByte(0xFF00, 0xBB);
    try std.testing.expectEqual(@as(u16, 0xBBAA), vm.readWord(0xFEFF));
}

test "sram round-trip via the host: save slice, install on new VM, read back" {
    // Step 1 — first boot, write into SRAM.
    var saved: [0x4000]u8 = undefined;
    {
        var vm = VM.init(std.testing.allocator);
        defer vm.deinit();
        try vm.installBanks(std.testing.allocator, 2, 1); // bank 1 is SRAM
        vm.regs.write(.mb, 1);
        vm.writeWord(0xC000, 0xBEEF);
        @memcpy(&saved, vm.sramSlice());
    }

    // Step 2 — second boot, host restores SRAM via the mutable
    // slice.
    var vm2 = VM.init(std.testing.allocator);
    defer vm2.deinit();
    try vm2.installBanks(std.testing.allocator, 2, 1);
    @memcpy(vm2.sramSliceMut(), &saved);
    vm2.regs.write(.mb, 1);
    try std.testing.expectEqual(@as(u16, 0xBEEF), vm2.readWord(0xC000));
}

test "installBanks rejects sram_bank_count > bank_count" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    try std.testing.expectError(error.InvalidSramCount, vm.installBanks(std.testing.allocator, 2, 3));
}

test "installBanksWithImage seeds banks from the provided image" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    var image: [0x4000 * 2]u8 = undefined;
    @memset(&image, 0);
    image[0] = 0x11; // bank 0 byte 0
    image[0x4000] = 0x22; // bank 1 byte 0
    try vm.installBanksWithImage(std.testing.allocator, &image, 2, 0);

    vm.regs.write(.mb, 0);
    try std.testing.expectEqual(@as(u8, 0x11), vm.readByte(0xC000));
    vm.regs.write(.mb, 1);
    try std.testing.expectEqual(@as(u8, 0x22), vm.readByte(0xC000));
}

test "mov 0x14 imm16,addr: bank-aware write lands in the active bank" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    try vm.installBanks(std.testing.allocator, 2, 0);
    vm.regs.write(.mb, 1);

    // `mov 0xCAFE, [0xC000]` — bytecode `[0x14, lo, hi, addr_lo, addr_hi]`.
    vm.regs.write(.ip, 0x1100);
    vm.mmap.writeByte(0x1100, 0x14);
    vm.mmap.writeByte(0x1101, 0xFE);
    vm.mmap.writeByte(0x1102, 0xCA);
    vm.mmap.writeByte(0x1103, 0x00);
    vm.mmap.writeByte(0x1104, 0xC0);

    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0xCAFE), vm.banks.?.readWord(1, 0xC000));
    // RAM at 0xC000 untouched.
    try std.testing.expectEqual(@as(u16, 0), vm.mmap.mem.readWord(0xC000));
}
