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

// ---------- add ----------

test "add 0x40 imm16,reg: simple addition + sets Z=0,N=0,C=0,V=0" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x0010);
    loadProgram(&vm, &.{ 0x40, 0x05, 0x00, 0x02 }); // add 0x0005 → r1
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x0015), vm.regs.read(.r1));
    const f = flags(&vm);
    try std.testing.expect(!f.z and !f.n and !f.c and !f.v);
}

test "add 0x40 imm16,reg: unsigned overflow sets C" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0xFFFF);
    loadProgram(&vm, &.{ 0x40, 0x02, 0x00, 0x02 }); // add 2 → r1
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x0001), vm.regs.read(.r1));
    try std.testing.expect(flags(&vm).c);
}

test "add 0x40 imm16,reg: signed overflow sets V" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x7FFF); // i16 max
    loadProgram(&vm, &.{ 0x40, 0x01, 0x00, 0x02 }); // add 1 → r1
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x8000), vm.regs.read(.r1));
    try std.testing.expect(flags(&vm).v);
    try std.testing.expect(flags(&vm).n);
}

test "add 0x40 imm16,reg: zero result sets Z" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0xFFFF);
    loadProgram(&vm, &.{ 0x40, 0x01, 0x00, 0x02 }); // add 1 → r1 (wraps to 0)
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0), vm.regs.read(.r1));
    try std.testing.expect(flags(&vm).z);
    try std.testing.expect(flags(&vm).c);
}

test "add 0x41 reg,reg" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x100);
    vm.regs.write(.r2, 0x200);
    loadProgram(&vm, &.{ 0x41, 0x02, 0x03 }); // add r1, r2 → r1 = r1 + r2
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x300), vm.regs.read(.r1));
}

test "add 0x42 reg (implicit acu)" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.acu, 0x10);
    vm.regs.write(.r1, 0x05);
    loadProgram(&vm, &.{ 0x42, 0x02 }); // add r1 → acu
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x15), vm.regs.read(.acu));
}

// ---------- sub ----------

test "sub 0x43 imm16,reg: simple subtraction" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x0010);
    loadProgram(&vm, &.{ 0x43, 0x05, 0x00, 0x02 }); // sub 5 → r1
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x000B), vm.regs.read(.r1));
    try std.testing.expect(!flags(&vm).c);
}

test "sub 0x43 imm16,reg: borrow sets C" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x0001);
    loadProgram(&vm, &.{ 0x43, 0x02, 0x00, 0x02 }); // sub 2 → r1 (underflows)
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0xFFFF), vm.regs.read(.r1));
    try std.testing.expect(flags(&vm).c);
    try std.testing.expect(flags(&vm).n);
}

test "sub 0x43 imm16,reg: signed overflow sets V" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x8000); // i16 min
    loadProgram(&vm, &.{ 0x43, 0x01, 0x00, 0x02 }); // sub 1 → r1 (wraps to 0x7FFF)
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x7FFF), vm.regs.read(.r1));
    try std.testing.expect(flags(&vm).v);
}

test "sub 0x44 reg,reg" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x100);
    vm.regs.write(.r2, 0x040);
    loadProgram(&vm, &.{ 0x44, 0x02, 0x03 }); // sub r1, r2
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x0C0), vm.regs.read(.r1));
}

test "sub 0x45 reg (implicit acu)" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.acu, 0x10);
    vm.regs.write(.r1, 0x03);
    loadProgram(&vm, &.{ 0x45, 0x02 }); // sub r1 from acu
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x0D), vm.regs.read(.acu));
}

// ---------- mul ----------

test "mul 0x46 imm16,reg: 16x16 producing 32-bit result" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x1000);
    loadProgram(&vm, &.{ 0x46, 0x00, 0x10, 0x02 }); // mul r1 × 0x1000
    _ = gero.vm.step(&vm);
    // 0x1000 * 0x1000 = 0x01000000 → low = 0x0000, high (acu) = 0x0100
    try std.testing.expectEqual(@as(u16, 0x0000), vm.regs.read(.r1));
    try std.testing.expectEqual(@as(u16, 0x0100), vm.regs.read(.acu));
    try std.testing.expect(flags(&vm).c); // high half non-zero
    try std.testing.expect(flags(&vm).v);
    try std.testing.expect(!flags(&vm).z); // overall result is non-zero
}

test "mul 0x46 imm16,reg: result fits in 16 bits clears C+V" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x10);
    loadProgram(&vm, &.{ 0x46, 0x05, 0x00, 0x02 }); // 0x10 * 5 = 0x50
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x50), vm.regs.read(.r1));
    try std.testing.expectEqual(@as(u16, 0x00), vm.regs.read(.acu));
    try std.testing.expect(!flags(&vm).c);
    try std.testing.expect(!flags(&vm).v);
}

test "mul 0x47 reg,reg" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x100);
    vm.regs.write(.r2, 0x20);
    loadProgram(&vm, &.{ 0x47, 0x02, 0x03 }); // mul r1 × r2
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.r1));
    try std.testing.expectEqual(@as(u16, 0x0000), vm.regs.read(.acu));
}

// ---------- inc / dec / neg ----------

test "inc 0x48 reg: +1 sets Z/N/V, leaves C intact" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x42);
    vm.regs.setFlag(.carry, true); // pre-set C — inc must preserve it
    loadProgram(&vm, &.{ 0x48, 0x02 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x43), vm.regs.read(.r1));
    try std.testing.expect(flags(&vm).c); // C preserved
    try std.testing.expect(!flags(&vm).z);
}

test "inc 0x48 reg: 0xFFFF → 0 sets Z (and would normally set C, but C is preserved)" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0xFFFF);
    vm.regs.setFlag(.carry, false); // pre-clear C
    loadProgram(&vm, &.{ 0x48, 0x02 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0), vm.regs.read(.r1));
    try std.testing.expect(flags(&vm).z);
    try std.testing.expect(!flags(&vm).c); // remained clear
}

test "dec 0x49 reg: -1 with C preserved" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x0001);
    vm.regs.setFlag(.carry, true);
    loadProgram(&vm, &.{ 0x49, 0x02 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0), vm.regs.read(.r1));
    try std.testing.expect(flags(&vm).z);
    try std.testing.expect(flags(&vm).c); // preserved
}

test "neg 0x4A reg: twos-complement negate" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x0001);
    loadProgram(&vm, &.{ 0x4A, 0x02 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0xFFFF), vm.regs.read(.r1));
    try std.testing.expect(flags(&vm).n);
    try std.testing.expect(flags(&vm).c); // 0 - 1 borrows
}

test "neg 0x4A reg: negate zero stays zero" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0);
    loadProgram(&vm, &.{ 0x4A, 0x02 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0), vm.regs.read(.r1));
    try std.testing.expect(flags(&vm).z);
    try std.testing.expect(!flags(&vm).c);
}

// ---------- div / divs ----------

test "div 0x4B imm16,reg: 32÷16 unsigned, quotient + remainder" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    // dividend = acu:r1 = 0x00010005, divisor = 7 → q = 9362 (0x2492), r = 3
    vm.regs.write(.acu, 0x0001);
    vm.regs.write(.r1, 0x0005);
    loadProgram(&vm, &.{ 0x4B, 0x07, 0x00, 0x02 }); // div 7 → r1
    _ = gero.vm.step(&vm);
    const expected_q: u16 = @truncate(@as(u32, 0x00010005) / 7);
    const expected_r: u16 = @truncate(@as(u32, 0x00010005) % 7);
    try std.testing.expectEqual(expected_q, vm.regs.read(.r1));
    try std.testing.expectEqual(expected_r, vm.regs.read(.acu));
    try std.testing.expect(!flags(&vm).c);
    try std.testing.expect(!flags(&vm).v);
}

test "div 0x4B imm16,reg: divisor 0 faults via vector 0x03" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.mmap.writeWord(gero.vm.ivtSlot(.div_by_zero), 0x3000);
    vm.regs.write(.r1, 100);
    loadProgram(&vm, &.{ 0x4B, 0x00, 0x00, 0x02 }); // div 0 → r1
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x3000), vm.regs.read(.ip));
}

test "div 0x4B imm16,reg: quotient overflow faults via vector 0x05" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.mmap.writeWord(gero.vm.ivtSlot(.arith_overflow), 0x4000);
    // dividend = 0xFFFF0000, divisor = 1 → quotient = 0xFFFF0000 > 0xFFFF
    vm.regs.write(.acu, 0xFFFF);
    vm.regs.write(.r1, 0x0000);
    loadProgram(&vm, &.{ 0x4B, 0x01, 0x00, 0x02 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x4000), vm.regs.read(.ip));
}

test "div 0x4C reg,reg" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.acu, 0);
    vm.regs.write(.r1, 100);
    vm.regs.write(.r2, 7);
    loadProgram(&vm, &.{ 0x4C, 0x02, 0x03 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 14), vm.regs.read(.r1));
    try std.testing.expectEqual(@as(u16, 2), vm.regs.read(.acu));
}

test "divs 0x4D imm16,reg: -10 / 3 = -3, remainder -1" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    // dividend = signed -10 in acu:r1 (sign-extended). For 32-bit
    // signed -10, acu = 0xFFFF, r1 = 0xFFF6.
    vm.regs.write(.acu, 0xFFFF);
    vm.regs.write(.r1, 0xFFF6);
    loadProgram(&vm, &.{ 0x4D, 0x03, 0x00, 0x02 }); // divs 3 → r1
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0xFFFD), vm.regs.read(.r1)); // -3
    try std.testing.expectEqual(@as(u16, 0xFFFF), vm.regs.read(.acu)); // -1
}

test "divs 0x4E reg,reg" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    // dividend = signed -10 = 0xFFFFFFF6, split as acu=0xFFFF / r1=0xFFF6.
    vm.regs.write(.acu, 0xFFFF);
    vm.regs.write(.r1, 0xFFF6);
    vm.regs.write(.r2, 3);
    loadProgram(&vm, &.{ 0x4E, 0x02, 0x03 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0xFFFD), vm.regs.read(.r1)); // -3
}

test "divs 0x4D imm16,reg: i32 MIN / -1 faults via vector 0x05" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.mmap.writeWord(gero.vm.ivtSlot(.arith_overflow), 0x4000);
    // dividend = i32 MIN = 0x80000000 → acu=0x8000, r1=0x0000. divisor = -1.
    vm.regs.write(.acu, 0x8000);
    vm.regs.write(.r1, 0x0000);
    loadProgram(&vm, &.{ 0x4D, 0xFF, 0xFF, 0x02 }); // divs -1 → r1
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x4000), vm.regs.read(.ip));
}

test "divs 0x4D imm16,reg: quotient outside i16 range faults via vector 0x05" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.mmap.writeWord(gero.vm.ivtSlot(.arith_overflow), 0x4000);
    // dividend = 0x10000000 (positive), divisor = 2 → quotient = 0x08000000.
    // i16 max is 0x7FFF, so this overflows.
    vm.regs.write(.acu, 0x1000);
    vm.regs.write(.r1, 0x0000);
    loadProgram(&vm, &.{ 0x4D, 0x02, 0x00, 0x02 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x4000), vm.regs.read(.ip));
}

// ---------- adc / sbc ----------

test "adc 0x64 imm16,reg: 32-bit add via low + adc high" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    // Add 0x0001FFFF + 0x00010002 = 0x00030001. Low halves: 0xFFFF +
    // 0x0002 = 0x0001 + carry. High halves: 0x0001 + 0x0001 + C(=1)
    // = 0x0003.
    vm.regs.write(.r1, 0xFFFF); // low half of first operand
    vm.regs.write(.r2, 0x0001); // high half of first operand
    // add r1, 0x0002 — sets C.
    loadProgram(&vm, &.{ 0x40, 0x02, 0x00, 0x02 });
    _ = gero.vm.step(&vm);
    try std.testing.expect(flags(&vm).c);
    try std.testing.expectEqual(@as(u16, 0x0001), vm.regs.read(.r1));

    // adc r2, 0x0001 — uses C from above.
    loadProgram(&vm, &.{ 0x64, 0x01, 0x00, 0x03 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x0003), vm.regs.read(.r2));
}

test "adc 0x65 reg,reg with carry-in" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x10);
    vm.regs.write(.r2, 0x05);
    vm.regs.setFlag(.carry, true);
    loadProgram(&vm, &.{ 0x65, 0x02, 0x03 }); // adc r1, r2 (with C=1)
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x16), vm.regs.read(.r1));
}

test "sbc 0x66 imm16,reg: 32-bit sub via sub low + sbc high" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    // 0x00030000 - 0x00010001 = 0x0001FFFF. Low: 0x0000 - 0x0001 =
    // 0xFFFF + borrow. High: 0x0003 - 0x0001 - C(=1) = 0x0001.
    vm.regs.write(.r1, 0x0000);
    vm.regs.write(.r2, 0x0003);
    loadProgram(&vm, &.{ 0x43, 0x01, 0x00, 0x02 }); // sub r1, 0x0001 → borrow
    _ = gero.vm.step(&vm);
    try std.testing.expect(flags(&vm).c);
    try std.testing.expectEqual(@as(u16, 0xFFFF), vm.regs.read(.r1));

    loadProgram(&vm, &.{ 0x66, 0x01, 0x00, 0x03 }); // sbc r2, 0x0001 (uses C)
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x0001), vm.regs.read(.r2));
}

test "sbc 0x67 reg,reg with borrow-in" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x10);
    vm.regs.write(.r2, 0x05);
    vm.regs.setFlag(.carry, true);
    loadProgram(&vm, &.{ 0x67, 0x02, 0x03 }); // sbc r1, r2 (with C=1)
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x0A), vm.regs.read(.r1));
}

// ---------- fault paths ----------

test "arith: invalid register on add raises invalid-register fault" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.mmap.writeWord(gero.vm.ivtSlot(.invalid_register), 0x5000);

    loadProgram(&vm, &.{ 0x41, 0x02, 0xFF }); // add r1, <out-of-range>
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x5000), vm.regs.read(.ip));
}
