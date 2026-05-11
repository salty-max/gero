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

// ---------- cmp ----------

test "cmp 0x60 reg,imm16: equal → Z=1" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x1234);
    loadProgram(&vm, &.{ 0x60, 0x02, 0x34, 0x12 }); // cmp r1, 0x1234
    _ = gero.vm.step(&vm);
    const f = flags(&vm);
    try std.testing.expect(f.z and !f.n and !f.c and !f.v);
    // Result discarded — r1 unchanged.
    try std.testing.expectEqual(@as(u16, 0x1234), vm.regs.read(.r1));
}

test "cmp 0x60 reg,imm16: a < b unsigned sets C" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x0001);
    loadProgram(&vm, &.{ 0x60, 0x02, 0x02, 0x00 }); // cmp r1, 2
    _ = gero.vm.step(&vm);
    try std.testing.expect(flags(&vm).c); // 1 - 2 borrows
    try std.testing.expect(flags(&vm).n);
}

test "cmp 0x60 reg,imm16: a > b clears C and Z" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x0010);
    loadProgram(&vm, &.{ 0x60, 0x02, 0x05, 0x00 }); // cmp r1, 5
    _ = gero.vm.step(&vm);
    const f = flags(&vm);
    try std.testing.expect(!f.c and !f.z and !f.n);
}

test "cmp 0x60: signed comparison via N ≠ V flags i16 max vs -1" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x7FFF); // i16 max
    loadProgram(&vm, &.{ 0x60, 0x02, 0xFF, 0xFF }); // cmp r1, 0xFFFF (= -1)
    _ = gero.vm.step(&vm);
    // 0x7FFF - 0xFFFF = 0x8000 (truncated). Signed: 32767 - (-1) = 32768
    // which overflows i16 → V=1. Result high bit set → N=1.
    try std.testing.expect(flags(&vm).v);
    try std.testing.expect(flags(&vm).n);
    // jge takes branch when N == V → 32767 >= -1 is true. ✓
}

test "cmp 0x61 reg,reg: same registers Z=1" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0xABCD);
    loadProgram(&vm, &.{ 0x61, 0x02, 0x02 }); // cmp r1, r1
    _ = gero.vm.step(&vm);
    try std.testing.expect(flags(&vm).z);
    try std.testing.expectEqual(@as(u16, 0xABCD), vm.regs.read(.r1));
}

test "cmp 0x61: different values, signed comparison" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0xFFFE); // -2
    vm.regs.write(.r2, 0x0005); // 5
    loadProgram(&vm, &.{ 0x61, 0x02, 0x03 }); // cmp r1, r2
    _ = gero.vm.step(&vm);
    // -2 - 5 = -7 (0xFFF9). Negative result → N=1. No signed overflow.
    try std.testing.expect(flags(&vm).n);
    try std.testing.expect(!flags(&vm).v);
}

// ---------- tst ----------

test "tst 0x62 reg,imm16: zero mask sets Z" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0xCAFE);
    loadProgram(&vm, &.{ 0x62, 0x02, 0x00, 0x00 }); // tst r1, 0
    _ = gero.vm.step(&vm);
    try std.testing.expect(flags(&vm).z);
    // r1 untouched.
    try std.testing.expectEqual(@as(u16, 0xCAFE), vm.regs.read(.r1));
}

test "tst 0x62: bit set in both → Z=0" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x8001);
    loadProgram(&vm, &.{ 0x62, 0x02, 0x00, 0x80 }); // tst r1, 0x8000
    _ = gero.vm.step(&vm);
    try std.testing.expect(!flags(&vm).z);
    try std.testing.expect(flags(&vm).n); // high bit set in AND result
}

test "tst 0x62: clears C and V even if preset" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x00FF);
    vm.regs.setFlag(.carry, true);
    vm.regs.setFlag(.overflow, true);
    loadProgram(&vm, &.{ 0x62, 0x02, 0x0F, 0x00 });
    _ = gero.vm.step(&vm);
    try std.testing.expect(!flags(&vm).c);
    try std.testing.expect(!flags(&vm).v);
}

test "tst 0x63 reg,reg" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0xFF00);
    vm.regs.write(.r2, 0x00FF);
    loadProgram(&vm, &.{ 0x63, 0x02, 0x03 });
    _ = gero.vm.step(&vm);
    try std.testing.expect(flags(&vm).z); // no overlapping bits
    // Neither register changed.
    try std.testing.expectEqual(@as(u16, 0xFF00), vm.regs.read(.r1));
    try std.testing.expectEqual(@as(u16, 0x00FF), vm.regs.read(.r2));
}

// ---------- fault paths ----------

test "cmp/tst: invalid register raises invalid-register fault" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.mmap.writeWord(gero.vm.ivtSlot(.invalid_register), 0x5000);

    loadProgram(&vm, &.{ 0x61, 0x02, 0xFF }); // cmp r1, <out-of-range>
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x5000), vm.regs.read(.ip));
}
