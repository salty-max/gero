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
    _ = buildGx(&buf, gero.gx.version, 0, 0x1100, 0, 0, 0);
    buf[0] = 'X';
    try std.testing.expectError(error.BadMagic, gero.vm.parseGx(&buf));
}

test "loader: rejects a higher major version" {
    var buf: [16]u8 = undefined;
    _ = buildGx(&buf, gero.gx.version + 0x0100, 0, 0x1100, 0, 0, 0);
    try std.testing.expectError(error.UnsupportedVersion, gero.vm.parseGx(&buf));
}

test "loader: rejects a lower major version" {
    // The direction a freeze makes matter. A `0.x` file is a valid
    // archive whose instructions address the memory map `1.0` moved,
    // so running it would put its bank window and stack where they no
    // longer are — accepted-and-wrong, which is what the major exists
    // to prevent. The literal is deliberate: this asserts about a
    // major that is gone, so it must not follow the constant.
    var buf: [16]u8 = undefined;
    _ = buildGx(&buf, 0x0004, 0, 0x1100, 0, 0, 0);
    try std.testing.expectError(error.UnsupportedVersion, gero.vm.parseGx(&buf));
}

test "loader: accepts same-major higher-minor version" {
    var buf: [16]u8 = undefined;
    const newer = (gero.gx.version & 0xFF00) | 0x50;
    _ = buildGx(&buf, newer, 0, 0x1100, 0, 0, 0);
    const loaded = try gero.vm.parseGx(&buf);
    try std.testing.expectEqual(@as(u16, newer), loaded.header.version);
}

test "loader: rejects reserved flag bits" {
    var buf: [16]u8 = undefined;
    _ = buildGx(&buf, gero.gx.version, 0b1000_0000, 0x1100, 0, 0, 0);
    try std.testing.expectError(error.ReservedBitsSet, gero.vm.parseGx(&buf));
}

test "loader: parses heap_base from bytes 0x0E..0x0F (little-endian)" {
    var buf: [16]u8 = undefined;
    _ = buildGx(&buf, gero.gx.version, 0, 0x1100, 0, 0, 0);
    buf[0x0E] = 0x34;
    buf[0x0F] = 0x12;
    const loaded = try gero.vm.parseGx(&buf);
    try std.testing.expectEqual(@as(u16, 0x1234), loaded.header.heap_base);
}

test "loader: heap_base defaults to 0 when bytes 0x0E..0x0F are zero" {
    var buf: [16]u8 = undefined;
    _ = buildGx(&buf, gero.gx.version, 0, 0x1100, 0, 0, 0);
    const loaded = try gero.vm.parseGx(&buf);
    try std.testing.expectEqual(@as(u16, 0), loaded.header.heap_base);
}

test "loader: rejects sram_bank_count > bank_count" {
    var buf: [16]u8 = undefined;
    _ = buildGx(&buf, gero.gx.version, 0, 0x1100, 0, 2, 3);
    try std.testing.expectError(error.InvalidSramCount, gero.vm.parseGx(&buf));
}

test "loader: rejects image_size that doesn't fit" {
    var buf: [16]u8 = undefined;
    _ = buildGx(&buf, gero.gx.version, 0, 0x1100, 100, 0, 0);
    // No bytes after header.
    try std.testing.expectError(error.ImageSizeMismatch, gero.vm.parseGx(&buf));
}

test "loader: valid header + image returns the slice" {
    var buf: [16 + 4]u8 = undefined;
    _ = buildGx(buf[0..16], gero.gx.version, 0, 0x1100, 4, 0, 0);
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
    _ = buildGx(&buf, gero.gx.version, 0x0001, 0x1100, 0, 2, 0);
    try std.testing.expectError(error.BanksSizeMismatch, gero.vm.parseGx(&buf));
}

test "loader: banked file returns the bank slice" {
    var buf: [16 + 0x4000]u8 = undefined;
    _ = buildGx(buf[0..16], gero.gx.version, 0x0001, 0x1100, 0, 1, 0);
    buf[16] = 0x11; // marker at start of bank 0
    const loaded = try gero.vm.parseGx(&buf);
    try std.testing.expect(loaded.header.isBanked());
    try std.testing.expectEqual(@as(usize, 0x4000), loaded.banks.len);
    try std.testing.expectEqual(@as(u8, 0x11), loaded.banks[0]);
}

test "loader: debug-symbols flag returns the trailing slice" {
    var buf: [16 + 4]u8 = undefined;
    _ = buildGx(buf[0..16], gero.gx.version, 0x0002, 0x1100, 0, 0, 0);
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
    _ = buildGx(buf[0..16], gero.gx.version, 0, 0x1100, 5, 0, 0);
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
    _ = buildGx(buf[0..16], gero.gx.version, 0x0001, 0x0000, 2, 2, 1);
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
    try std.testing.expectEqual(@as(u8, 0xAA), vm.banks.?.readByte(0, 0xBE00));
    try std.testing.expectEqual(@as(u8, 0xBB), vm.banks.?.readByte(1, 0xBE00));
}

test "boot + run: nop nop hlt program executes and halts" {
    var buf: [16 + 3]u8 = undefined;
    _ = buildGx(buf[0..16], gero.gx.version, 0, 0x0000, 3, 0, 0);
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

// ---------- heap_base validity (ISA §7.1) ----------

/// Write `heap_base` into a header `buildGx` already laid out.
fn setHeapBase(buf: []u8, heap_base: u16) void {
    buf[0x0E] = @truncate(heap_base & 0xFF);
    buf[0x0F] = @truncate(heap_base >> 8);
}

test "loader: rejects a heap_base pointing inside the base image" {
    var buf: [24]u8 = undefined;
    const gx = buildGx(&buf, gero.gx.version, 0, 0, 8, 0, 0);
    // A heap starting inside the image would hand out addresses over
    // live code; `sys alloc` only bounds the top of the heap, so
    // nothing downstream would catch it.
    setHeapBase(gx, 4);
    try std.testing.expectError(error.HeapInsideImage, gero.vm.parseGx(gx));
}

test "loader: accepts a heap_base at the image's end" {
    var buf: [24]u8 = undefined;
    const gx = buildGx(&buf, gero.gx.version, 0, 0, 8, 0, 0);
    // The first byte past the image is the tightest legal heap.
    setHeapBase(gx, 8);
    const loaded = try gero.vm.parseGx(gx);
    try std.testing.expectEqual(@as(u16, 8), loaded.header.heap_base);
}

test "loader: heap_base zero means no heap, not an overlap" {
    var buf: [24]u8 = undefined;
    const gx = buildGx(&buf, gero.gx.version, 0, 0, 8, 0, 0);
    setHeapBase(gx, 0);
    const loaded = try gero.vm.parseGx(gx);
    try std.testing.expectEqual(@as(u16, 0), loaded.header.heap_base);
}

test "loader: rejects a banked program's heap_base inside the bank window" {
    var buf: [24]u8 = undefined;
    const gx = buildGx(&buf, gero.gx.version, 0x0001, 0, 8, 1, 0);
    setHeapBase(gx, 0xBE00);
    // The bank window mirrors bank `mb`; a switch would replace every
    // allocation living there.
    try std.testing.expectError(error.HeapInBankWindow, gero.vm.parseGx(gx));
}

test "loader: an unbanked program may put its heap at 0xBE00" {
    var buf: [24]u8 = undefined;
    const gx = buildGx(&buf, gero.gx.version, 0, 0, 8, 0, 0);
    setHeapBase(gx, 0xBE00);
    // With no banks the window is plain RAM, so the address is fine.
    const loaded = try gero.vm.parseGx(gx);
    try std.testing.expectEqual(@as(u16, 0xBE00), loaded.header.heap_base);
}

test "loader: the accepted version is the one producers stamp" {
    // Two constants for one fact drifted once already: producers moved
    // to 0x0004 while the loader still claimed 0x0003. The major-only
    // check hid it.
    try std.testing.expectEqual(gero.gx.version, gero.vm.version_target);
}
