const std = @import("std");
const gero = @import("gero");
const VM = gero.vm.VM;

/// Build a minimal valid .gx header + image. Returns the
/// owned-on-stack buffer; caller copies if needed.
fn buildGx(
    out: []u8,
    version: u16,
    flags: u16,
    entry: u16,
    image_size: u16,
    bank_count: u8,
    sram_bank_count: u8,
) []u8 {
    @memset(out, 0);
    @memcpy(out[0..4], "GERO");
    out[0x04] = @truncate(version & 0xFF);
    out[0x05] = @truncate(version >> 8);
    out[0x06] = @truncate(flags & 0xFF);
    out[0x07] = @truncate(flags >> 8);
    out[0x08] = @truncate(entry & 0xFF);
    out[0x09] = @truncate(entry >> 8);
    out[0x0A] = @truncate(image_size & 0xFF);
    out[0x0B] = @truncate(image_size >> 8);
    out[0x0C] = bank_count;
    out[0x0D] = sram_bank_count;
    // 0x0E..0x0F left zero
    return out;
}

test "loader: rejects buffer shorter than the header" {
    var tiny: [4]u8 = .{ 'G', 'E', 'R', 'O' };
    try std.testing.expectError(error.TooSmall, gero.vm.parseGx(&tiny));
}

test "loader: rejects bad magic" {
    var buf: [16]u8 = undefined;
    _ = buildGx(&buf, 0x0001, 0, 0x1100, 0, 0, 0);
    buf[0] = 'X';
    try std.testing.expectError(error.BadMagic, gero.vm.parseGx(&buf));
}

test "loader: rejects future major version" {
    var buf: [16]u8 = undefined;
    _ = buildGx(&buf, 0x0100, 0, 0x1100, 0, 0, 0);
    try std.testing.expectError(error.UnsupportedVersion, gero.vm.parseGx(&buf));
}

test "loader: accepts same-major higher-minor version" {
    var buf: [16]u8 = undefined;
    _ = buildGx(&buf, 0x0050, 0, 0x1100, 0, 0, 0);
    const loaded = try gero.vm.parseGx(&buf);
    try std.testing.expectEqual(@as(u16, 0x0050), loaded.header.version);
}

test "loader: rejects reserved flag bits" {
    var buf: [16]u8 = undefined;
    _ = buildGx(&buf, 0x0001, 0b1000_0000, 0x1100, 0, 0, 0);
    try std.testing.expectError(error.ReservedBitsSet, gero.vm.parseGx(&buf));
}

test "loader: parses heap_base from bytes 0x0E..0x0F (little-endian)" {
    var buf: [16]u8 = undefined;
    _ = buildGx(&buf, 0x0002, 0, 0x1100, 0, 0, 0);
    buf[0x0E] = 0x34;
    buf[0x0F] = 0x12;
    const loaded = try gero.vm.parseGx(&buf);
    try std.testing.expectEqual(@as(u16, 0x1234), loaded.header.heap_base);
}

test "loader: heap_base defaults to 0 when bytes 0x0E..0x0F are zero" {
    var buf: [16]u8 = undefined;
    _ = buildGx(&buf, 0x0001, 0, 0x1100, 0, 0, 0);
    const loaded = try gero.vm.parseGx(&buf);
    try std.testing.expectEqual(@as(u16, 0), loaded.header.heap_base);
}

test "loader: rejects sram_bank_count > bank_count" {
    var buf: [16]u8 = undefined;
    _ = buildGx(&buf, 0x0001, 0, 0x1100, 0, 2, 3);
    try std.testing.expectError(error.InvalidSramCount, gero.vm.parseGx(&buf));
}

test "loader: rejects image_size that doesn't fit" {
    var buf: [16]u8 = undefined;
    _ = buildGx(&buf, 0x0001, 0, 0x1100, 100, 0, 0);
    // No bytes after header.
    try std.testing.expectError(error.ImageSizeMismatch, gero.vm.parseGx(&buf));
}

test "loader: valid header + image returns the slice" {
    var buf: [16 + 4]u8 = undefined;
    _ = buildGx(buf[0..16], 0x0001, 0, 0x1100, 4, 0, 0);
    buf[16] = 0xDE;
    buf[17] = 0xAD;
    buf[18] = 0xBE;
    buf[19] = 0xEF;
    const loaded = try gero.vm.parseGx(&buf);
    try std.testing.expectEqual(@as(u16, 0x1100), loaded.header.entry_point);
    try std.testing.expectEqual(@as(u16, 4), loaded.header.image_size);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF }, loaded.image);
    try std.testing.expectEqual(@as(usize, 0), loaded.banks.len);
}

test "loader: banked flag requires bank section to fit" {
    var buf: [16]u8 = undefined;
    _ = buildGx(&buf, 0x0001, 0x0001, 0x1100, 0, 2, 0);
    try std.testing.expectError(error.BanksSizeMismatch, gero.vm.parseGx(&buf));
}

test "loader: banked file returns the bank slice" {
    var buf: [16 + 0x4000]u8 = undefined;
    _ = buildGx(buf[0..16], 0x0001, 0x0001, 0x1100, 0, 1, 0);
    buf[16] = 0x11; // marker at start of bank 0
    const loaded = try gero.vm.parseGx(&buf);
    try std.testing.expect(loaded.header.isBanked());
    try std.testing.expectEqual(@as(usize, 0x4000), loaded.banks.len);
    try std.testing.expectEqual(@as(u8, 0x11), loaded.banks[0]);
}

test "loader: debug-symbols flag returns the trailing slice" {
    var buf: [16 + 4]u8 = undefined;
    _ = buildGx(buf[0..16], 0x0001, 0x0002, 0x1100, 0, 0, 0);
    buf[16] = 0x01;
    buf[17] = 0x02;
    buf[18] = 0x03;
    buf[19] = 0x04;
    const loaded = try gero.vm.parseGx(&buf);
    try std.testing.expect(loaded.header.hasDebugSymbols());
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03, 0x04 }, loaded.debug);
}

// ---------- VM.boot ----------

test "boot: copies the base image into RAM at 0x0000 and sets ip" {
    var buf: [16 + 5]u8 = undefined;
    _ = buildGx(buf[0..16], 0x0001, 0, 0x1100, 5, 0, 0);
    // mov 0xABCD → r1 (4 bytes) + hlt (1 byte) — just data to copy.
    buf[16] = 0x10;
    buf[17] = 0xCD;
    buf[18] = 0xAB;
    buf[19] = 0x02;
    buf[20] = 0xFF;
    const loaded = try gero.vm.parseGx(&buf);

    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    try vm.boot(std.testing.allocator, loaded);

    try std.testing.expectEqual(@as(u16, 0x1100), vm.regs.read(.ip));
    try std.testing.expectEqual(@as(u8, 0x10), vm.mmap.mem.readByte(0x0000));
    try std.testing.expectEqual(@as(u8, 0xFF), vm.mmap.mem.readByte(0x0004));
}

test "boot: banked program installs the bank pool" {
    var buf: [16 + 2 + 0x4000 * 2]u8 = undefined;
    _ = buildGx(buf[0..16], 0x0001, 0x0001, 0x0000, 2, 2, 1);
    buf[16] = 0xFF; // image[0] = hlt
    buf[17] = 0x00;
    // Bank 0 marker.
    buf[18 + 0] = 0xAA;
    // Bank 1 marker (SRAM bank).
    buf[18 + 0x4000] = 0xBB;
    const loaded = try gero.vm.parseGx(&buf);

    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    try vm.boot(std.testing.allocator, loaded);

    try std.testing.expect(vm.banks != null);
    try std.testing.expectEqual(@as(u8, 2), vm.banks.?.bank_count);
    try std.testing.expectEqual(@as(u8, 1), vm.banks.?.sram_bank_count);
    try std.testing.expectEqual(@as(u8, 0xAA), vm.banks.?.readByte(0, 0xC000));
    try std.testing.expectEqual(@as(u8, 0xBB), vm.banks.?.readByte(1, 0xC000));
}

test "boot + run: nop nop hlt program executes and halts" {
    var buf: [16 + 3]u8 = undefined;
    _ = buildGx(buf[0..16], 0x0001, 0, 0x0000, 3, 0, 0);
    buf[16] = 0xC1; // nop
    buf[17] = 0xC1; // nop
    buf[18] = 0xFF; // hlt
    const loaded = try gero.vm.parseGx(&buf);

    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    try vm.boot(std.testing.allocator, loaded);

    try std.testing.expectEqual(gero.vm.StepResult.halted, gero.vm.run(&vm));
    try std.testing.expectEqual(@as(u16, 0x0002), vm.regs.read(.ip));
}

// ---------- cycle counter ----------

test "cycles: init starts at 0 and step increments by 1 each call" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    try std.testing.expectEqual(@as(u64, 0), vm.cycles);

    vm.regs.write(.ip, 0x1100);
    vm.mmap.writeByte(0x1100, 0xC1); // nop
    vm.mmap.writeByte(0x1101, 0xC1);
    vm.mmap.writeByte(0x1102, 0xC1);
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u64, 1), vm.cycles);
    _ = gero.vm.step(&vm);
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u64, 3), vm.cycles);
}

test "cycles: faulting steps still count" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.mmap.writeWord(gero.vm.ivtSlot(.invalid_opcode), 0x3000);
    vm.regs.write(.ip, 0x1100);
    vm.mmap.writeByte(0x1100, 0x00); // gap byte → invalid-opcode fault
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u64, 1), vm.cycles);
}

test "cycles: run accumulates one per step including the terminating hlt" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.ip, 0x1100);
    vm.mmap.writeByte(0x1100, 0xC1); // nop
    vm.mmap.writeByte(0x1101, 0xFF); // hlt
    _ = gero.vm.run(&vm);
    try std.testing.expectEqual(@as(u64, 2), vm.cycles);
}
