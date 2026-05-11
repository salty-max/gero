const std = @import("std");
const gero = @import("gero");
const VM = gero.vm.VM;

fn loadProgram(vm: *VM, bytes: []const u8) void {
    vm.regs.write(.ip, 0x1100);
    for (bytes, 0..) |b, i| {
        vm.mmap.writeByte(0x1100 + @as(u16, @intCast(i)), b);
    }
}

test "push 0x30 imm16: pre-decrements sp and writes" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    const sp_before = vm.regs.read(.sp);
    loadProgram(&vm, &.{ 0x30, 0xCD, 0xAB }); // push 0xABCD
    _ = gero.vm.step(&vm);

    try std.testing.expectEqual(sp_before -% 2, vm.regs.read(.sp));
    try std.testing.expectEqual(@as(u16, 0xABCD), vm.mmap.readWord(sp_before -% 2));
    try std.testing.expectEqual(@as(u16, 0x1103), vm.regs.read(.ip));
}

test "push 0x31 reg: pre-decrements sp and writes register value" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    const sp_before = vm.regs.read(.sp);
    vm.regs.write(.r1, 0xDEAD);
    loadProgram(&vm, &.{ 0x31, 0x02 }); // push r1
    _ = gero.vm.step(&vm);

    try std.testing.expectEqual(sp_before -% 2, vm.regs.read(.sp));
    try std.testing.expectEqual(@as(u16, 0xDEAD), vm.mmap.readWord(sp_before -% 2));
    try std.testing.expectEqual(@as(u16, 0x1102), vm.regs.read(.ip));
}

test "pop 0x32 reg: reads then post-increments sp" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    // Pre-stage a value on the stack via push semantics.
    const sp_before = vm.regs.read(.sp);
    vm.regs.write(.sp, sp_before -% 2);
    vm.mmap.writeWord(sp_before -% 2, 0xBEEF);

    loadProgram(&vm, &.{ 0x32, 0x02 }); // pop r1
    _ = gero.vm.step(&vm);

    try std.testing.expectEqual(@as(u16, 0xBEEF), vm.regs.read(.r1));
    // sp should be back to its original position.
    try std.testing.expectEqual(sp_before, vm.regs.read(.sp));
    try std.testing.expectEqual(@as(u16, 0x1102), vm.regs.read(.ip));
}

test "stack: push x then pop r round-trips the value" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    loadProgram(&vm, &.{
        0x30, 0x34, 0x12, // push 0x1234
        0x32, 0x02, //       pop r1
    });
    _ = gero.vm.step(&vm); // push
    _ = gero.vm.step(&vm); // pop
    try std.testing.expectEqual(@as(u16, 0x1234), vm.regs.read(.r1));
    // sp returns to its original boot value after balanced push/pop.
    try std.testing.expectEqual(@as(u16, 0xFFFE), vm.regs.read(.sp));
}

test "stack: LIFO ordering across multiple pushes and pops" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    vm.regs.write(.r1, 0x1111);
    vm.regs.write(.r2, 0x2222);
    vm.regs.write(.r3, 0x3333);

    loadProgram(&vm, &.{
        0x31, 0x02, // push r1
        0x31, 0x03, // push r2
        0x31, 0x04, // push r3
        0x32, 0x05, // pop r4
        0x32, 0x06, // pop r5
        0x32, 0x07, // pop r6
    });
    var i: usize = 0;
    while (i < 6) : (i += 1) _ = gero.vm.step(&vm);

    // Last in, first out.
    try std.testing.expectEqual(@as(u16, 0x3333), vm.regs.read(.r4));
    try std.testing.expectEqual(@as(u16, 0x2222), vm.regs.read(.r5));
    try std.testing.expectEqual(@as(u16, 0x1111), vm.regs.read(.r6));
    try std.testing.expectEqual(@as(u16, 0xFFFE), vm.regs.read(.sp));
}

test "stack: underflow wraps silently (not a fault)" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    // Pop with sp = 0xFFFE (boot, empty stack). Reads garbage
    // and wraps sp upward; permissive behavior, NOT a fault.
    loadProgram(&vm, &.{ 0x32, 0x02 }); // pop r1
    try std.testing.expectEqual(gero.vm.StepResult.cont, gero.vm.step(&vm));
    try std.testing.expectEqual(@as(u16, 0x0000), vm.regs.read(.sp));
}

test "stack: overflow wraps silently (not a fault)" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    // Drive sp down to 0x0000 then push once more — should wrap to
    // 0xFFFE without faulting.
    vm.regs.write(.sp, 0x0000);
    vm.regs.write(.r1, 0xFACE);
    loadProgram(&vm, &.{ 0x31, 0x02 }); // push r1
    try std.testing.expectEqual(gero.vm.StepResult.cont, gero.vm.step(&vm));
    try std.testing.expectEqual(@as(u16, 0xFFFE), vm.regs.read(.sp));
    try std.testing.expectEqual(@as(u16, 0xFACE), vm.mmap.readWord(0xFFFE));
}

test "stack: invalid register on push raises invalid-register fault" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.mmap.writeWord(gero.vm.ivtSlot(.invalid_register), 0x5000);

    loadProgram(&vm, &.{ 0x31, 0xFF }); // push <out-of-range>
    try std.testing.expectEqual(gero.vm.StepResult.cont, gero.vm.step(&vm));
    try std.testing.expectEqual(@as(u16, 0x5000), vm.regs.read(.ip));
}

test "stack: invalid register on pop raises invalid-register fault" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.mmap.writeWord(gero.vm.ivtSlot(.invalid_register), 0x5000);

    loadProgram(&vm, &.{ 0x32, 0xFF }); // pop <out-of-range>
    try std.testing.expectEqual(gero.vm.StepResult.cont, gero.vm.step(&vm));
    try std.testing.expectEqual(@as(u16, 0x5000), vm.regs.read(.ip));
}
