const std = @import("std");
const gero = @import("gero");
const VM = gero.vm.VM;

fn loadProgram(vm: *VM, bytes: []const u8) void {
    vm.regs.write(.ip, 0x1100);
    for (bytes, 0..) |b, i| {
        vm.mmap.writeByte(0x1100 + @as(u16, @intCast(i)), b);
    }
}

fn flags(vm: *VM) struct { z: bool, n: bool, c: bool, v: bool } {
    return .{
        .z = vm.regs.flagSet(.zero),
        .n = vm.regs.flagSet(.negative),
        .c = vm.regs.flagSet(.carry),
        .v = vm.regs.flagSet(.overflow),
    };
}

// ---------- and ----------

test "and 0x60 imm16,reg" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0xFF0F);
    loadProgram(&vm, &.{ 0x60, 0xF0, 0x00, 0x02 }); // and 0x00F0, r1
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x0000), vm.regs.read(.r1));
    const f = flags(&vm);
    try std.testing.expect(f.z and !f.n and !f.c and !f.v);
}

test "and 0x60: high bit set marks N" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0xFFFF);
    loadProgram(&vm, &.{ 0x60, 0x00, 0x80, 0x02 }); // and 0x8000, r1
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x8000), vm.regs.read(.r1));
    try std.testing.expect(flags(&vm).n);
}

test "and 0x61 reg,reg clears C+V even if preset" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0xFF00);
    vm.regs.write(.r2, 0xFF0F);
    vm.regs.setFlag(.carry, true);
    vm.regs.setFlag(.overflow, true);
    loadProgram(&vm, &.{ 0x61, 0x03, 0x02 }); // and r2, r1 → r1 &= r2 (src, dst)
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0xFF00), vm.regs.read(.r1));
    try std.testing.expect(!flags(&vm).c);
    try std.testing.expect(!flags(&vm).v);
}

// ---------- or ----------

test "or 0x62 imm16,reg" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x000F);
    loadProgram(&vm, &.{ 0x62, 0xF0, 0x00, 0x02 }); // or 0x00F0, r1
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x00FF), vm.regs.read(.r1));
}

test "or 0x63 reg,reg" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0xF000);
    vm.regs.write(.r2, 0x000F);
    loadProgram(&vm, &.{ 0x63, 0x03, 0x02 }); // or r2, r1 → r1 |= r2 (src, dst)
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0xF00F), vm.regs.read(.r1));
}

// ---------- xor ----------

test "xor 0x64 imm16,reg" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0xAAAA);
    loadProgram(&vm, &.{ 0x64, 0xFF, 0xFF, 0x02 }); // xor 0xFFFF, r1 (= not)
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x5555), vm.regs.read(.r1));
}

test "xor 0x65 reg,reg: self-xor zeroes the register" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0xCAFE);
    loadProgram(&vm, &.{ 0x65, 0x02, 0x02 }); // xor r1, r1
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0), vm.regs.read(.r1));
    try std.testing.expect(flags(&vm).z);
}

// ---------- not ----------

test "not 0x66 reg: bitwise complement" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0xAAAA);
    loadProgram(&vm, &.{ 0x66, 0x02 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x5555), vm.regs.read(.r1));
}

// ---------- shl ----------

test "shl 0x70 reg,imm8: simple left shift, C from last bit out" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x4001); // bit 14 set, bit 0 set
    loadProgram(&vm, &.{ 0x70, 0x02, 0x02 }); // shl r1, 2
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x0004), vm.regs.read(.r1));
    try std.testing.expect(flags(&vm).c); // last bit out was bit 14 = 1
}

test "shl 0x70 reg,imm8: count 0 preserves C" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x1234);
    vm.regs.setFlag(.carry, true);
    loadProgram(&vm, &.{ 0x70, 0x02, 0x00 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x1234), vm.regs.read(.r1));
    try std.testing.expect(flags(&vm).c); // unchanged
}

test "shl 0x70: count >= 16 zeroes the result and clears C" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x00FF);
    loadProgram(&vm, &.{ 0x70, 0x02, 0x14 }); // shl r1, 20
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0), vm.regs.read(.r1));
    try std.testing.expect(flags(&vm).z);
    try std.testing.expect(!flags(&vm).c);
}

test "shl 0x71 reg,reg: count from src" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x0008);
    vm.regs.write(.r2, 0x0003);
    loadProgram(&vm, &.{ 0x71, 0x02, 0x03 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x0040), vm.regs.read(.r1));
}

// ---------- shr ----------

test "shr 0x72 reg,imm8: logical right shift, zero-fills high bit" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x8003);
    loadProgram(&vm, &.{ 0x72, 0x02, 0x02 }); // shr r1, 2
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.r1));
    try std.testing.expect(flags(&vm).c); // last bit out was bit 1 (set)
}

test "shr 0x72: count 0 preserves C" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x1234);
    vm.regs.setFlag(.carry, true);
    loadProgram(&vm, &.{ 0x72, 0x02, 0x00 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x1234), vm.regs.read(.r1));
    try std.testing.expect(flags(&vm).c);
}

test "shr 0x73 reg,reg: count from src" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x0080);
    vm.regs.write(.r2, 0x0004);
    loadProgram(&vm, &.{ 0x73, 0x02, 0x03 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x0008), vm.regs.read(.r1));
}

// ---------- rol ----------

test "rol 0x76 reg,imm8: rotate left through carry, count 1" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x8001);
    vm.regs.setFlag(.carry, false);
    loadProgram(&vm, &.{ 0x76, 0x02, 0x01 }); // rol r1, 1
    _ = gero.vm.step(&vm);
    // bit 15 (1) → C; old C (0) → bit 0 of result; rest shifts left.
    try std.testing.expectEqual(@as(u16, 0x0002), vm.regs.read(.r1));
    try std.testing.expect(flags(&vm).c);
}

test "rol 0x76: rotation preserves all bits through 17-bit chain" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0xABCD);
    vm.regs.setFlag(.carry, false);
    // 17 rotations completes a full cycle → register + C back to start.
    loadProgram(&vm, &.{ 0x76, 0x02, 0x11 }); // rol r1, 17
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0xABCD), vm.regs.read(.r1));
    try std.testing.expect(!flags(&vm).c);
}

test "rol 0x77 reg,reg" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x8000);
    vm.regs.write(.r2, 0x0001);
    vm.regs.setFlag(.carry, true);
    loadProgram(&vm, &.{ 0x77, 0x02, 0x03 });
    _ = gero.vm.step(&vm);
    // bit 15 → C, old C(=1) → bit 0
    try std.testing.expectEqual(@as(u16, 0x0001), vm.regs.read(.r1));
    try std.testing.expect(flags(&vm).c);
}

// ---------- ror ----------

test "ror 0x78 reg,imm8: rotate right through carry" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x0001);
    vm.regs.setFlag(.carry, false);
    loadProgram(&vm, &.{ 0x78, 0x02, 0x01 });
    _ = gero.vm.step(&vm);
    // bit 0 → C; old C (0) → bit 15.
    try std.testing.expectEqual(@as(u16, 0x0000), vm.regs.read(.r1));
    try std.testing.expect(flags(&vm).c);
}

test "ror 0x78: carry-in feeds into bit 15" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x0002);
    vm.regs.setFlag(.carry, true);
    loadProgram(&vm, &.{ 0x78, 0x02, 0x01 });
    _ = gero.vm.step(&vm);
    // bit 0 (0) → C; old C (1) → bit 15.
    try std.testing.expectEqual(@as(u16, 0x8001), vm.regs.read(.r1));
    try std.testing.expect(!flags(&vm).c);
}

test "ror 0x79 reg,reg: count 17 is a full cycle" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0xCAFE);
    vm.regs.write(.r2, 0x0011); // 17
    vm.regs.setFlag(.carry, true);
    loadProgram(&vm, &.{ 0x79, 0x02, 0x03 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0xCAFE), vm.regs.read(.r1));
    try std.testing.expect(flags(&vm).c); // unchanged after full cycle
}

// ---------- fault paths ----------

test "logical: invalid register raises invalid-register fault" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.mmap.writeWord(gero.vm.ivtSlot(.invalid_register), 0x5000);

    loadProgram(&vm, &.{ 0x61, 0x02, 0xFF }); // and r1, <out-of-range>
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x5000), vm.regs.read(.ip));
}

// ---------- asr (0x74 / 0x75) — arithmetic shift right ----------

test "asr 0x74: negative number preserves sign bit on shift" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0xFF00); // = -256 signed
    loadProgram(&vm, &.{ 0x74, 0x02, 0x01 }); // asr r1, $01
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0xFF80), vm.regs.read(.r1)); // -128 signed
}

test "asr 0x74: positive number behaves like shr" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x0080);
    loadProgram(&vm, &.{ 0x74, 0x02, 0x01 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x0040), vm.regs.read(.r1));
}

test "asr 0x74: shift by large count saturates to sign extension" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x8000); // = -32768 signed, MSB set
    loadProgram(&vm, &.{ 0x74, 0x02, 0xFF }); // asr r1, 255 — way past 16
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0xFFFF), vm.regs.read(.r1)); // all sign-extended
}

test "asr 0x75 reg,reg: shift count from second register" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0xFFFC); // = -4 signed
    vm.regs.write(.r2, 0x0001);
    loadProgram(&vm, &.{ 0x75, 0x02, 0x03 }); // asr r1, r2
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0xFFFE), vm.regs.read(.r1)); // -2 signed
}

test "asr: shift by zero is a no-op (no C update, value untouched)" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0xC0DE);
    loadProgram(&vm, &.{ 0x74, 0x02, 0x00 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0xC0DE), vm.regs.read(.r1));
}

test "asr: invalid register raises invalid-register fault" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.mmap.writeWord(gero.vm.ivtSlot(.invalid_register), 0x5000);
    loadProgram(&vm, &.{ 0x74, 0xFF, 0x01 });
    try std.testing.expectEqual(gero.vm.StepResult.branched, gero.vm.step(&vm));
    try std.testing.expectEqual(@as(u16, 0x5000), vm.regs.read(.ip));
}
