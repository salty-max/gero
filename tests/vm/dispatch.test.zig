const std = @import("std");
const gero = @import("gero");
const VM = gero.vm.VM;
const Vector = gero.vm.Vector;

/// Install a vector address in the IVT.
fn setVector(vm: *VM, vector: Vector, target: u16) void {
    vm.mmap.writeWord(gero.vm.ivtSlot(vector), target);
}

test "dispatch: ivtSlot follows ISA §6.1 layout" {
    try std.testing.expectEqual(@as(u16, 0x1000), gero.vm.ivtSlot(.reset));
    try std.testing.expectEqual(@as(u16, 0x1002), gero.vm.ivtSlot(.invalid_opcode));
    try std.testing.expectEqual(@as(u16, 0x1004), gero.vm.ivtSlot(.invalid_register));
    try std.testing.expectEqual(@as(u16, 0x1006), gero.vm.ivtSlot(.div_by_zero));
    try std.testing.expectEqual(@as(u16, 0x100A), gero.vm.ivtSlot(.arith_overflow));
}

test "dispatch: step with unset IVT halts on fault" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    // IVT is zero-initialized — vector slot is 0, no ISR installed.
    try std.testing.expectEqual(gero.vm.StepResult.halted_on_fault, gero.vm.step(&vm));
}

test "dispatch: step with installed ISR enters the handler" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    setVector(&vm, .invalid_opcode, 0x2000);
    vm.regs.write(.ip, 0x1100);

    try std.testing.expectEqual(gero.vm.StepResult.cont, gero.vm.step(&vm));
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));
    try std.testing.expect(vm.regs.flagSet(.interrupt_disable));
}

test "dispatch: fault entry pushes ip, fp, flg in spec order" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    setVector(&vm, .invalid_opcode, 0x2000);
    vm.regs.write(.ip, 0x1234);
    vm.regs.write(.fp, 0xABCD);
    vm.regs.write(.flg, 0x000F);

    _ = gero.vm.step(&vm);

    // Stack grows downward; first push lands at 0xFFFE (sp_boot),
    // each subsequent push 2 bytes below. Order per ISA §6.2:
    // ip → fp → flg (flg ends up on top of stack).
    try std.testing.expectEqual(@as(u16, 0x1234), vm.mmap.readWord(0xFFFE));
    try std.testing.expectEqual(@as(u16, 0xABCD), vm.mmap.readWord(0xFFFC));
    // flg was 0x000F before the push; flg.I is set AFTER the push.
    try std.testing.expectEqual(@as(u16, 0x000F), vm.mmap.readWord(0xFFFA));
    // sp ends up 6 bytes below boot.
    try std.testing.expectEqual(@as(u16, 0xFFF8), vm.regs.read(.sp));
}

test "dispatch: raiseFault routes to the right vector slot" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    setVector(&vm, .div_by_zero, 0x3000);
    _ = gero.vm.raiseFault(&vm, .div_by_zero);
    try std.testing.expectEqual(@as(u16, 0x3000), vm.regs.read(.ip));
}

test "dispatch: raiseFault on a zero-slot vector halts" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    try std.testing.expectEqual(
        gero.vm.StepResult.halted_on_fault,
        gero.vm.raiseFault(&vm, .arith_overflow),
    );
    // ip stays untouched on an unhandled fault — the host inspects
    // the offending instruction.
    try std.testing.expectEqual(@as(u16, 0), vm.regs.read(.ip));
}

test "dispatch: run halts when the IVT is empty" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    try std.testing.expectEqual(gero.vm.StepResult.halted_on_fault, gero.vm.run(&vm));
}

test "dispatch: bytes without a handler raise invalid-opcode" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    setVector(&vm, .invalid_opcode, 0x4000);

    // Pick bytes that have no handler yet (gaps in §5 + unimplemented
    // families): the invalid-opcode fault should fire on each.
    inline for ([_]u8{ 0x00, 0x40, 0x80, 0xFF }) |op| {
        vm.regs.write(.ip, 0x1100);
        vm.mmap.writeByte(0x1100, op);
        vm.regs.write(.sp, 0xFFFE);
        vm.regs.write(.flg, 0);
        try std.testing.expectEqual(gero.vm.StepResult.cont, gero.vm.step(&vm));
        try std.testing.expectEqual(@as(u16, 0x4000), vm.regs.read(.ip));
    }
}

test "dispatch: step auto-advances ip by instruction size" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    // 0x91 nop is 1 byte and has no handler yet → faults. Use a
    // mov instead: 0x11 mov reg, reg is 3 bytes total.
    vm.regs.write(.ip, 0x1100);
    vm.mmap.writeByte(0x1100, 0x11);
    vm.mmap.writeByte(0x1101, 0x02); // dst = r1
    vm.mmap.writeByte(0x1102, 0x03); // src = r2
    vm.regs.write(.r2, 0xBEEF);

    try std.testing.expectEqual(gero.vm.StepResult.cont, gero.vm.step(&vm));
    try std.testing.expectEqual(@as(u16, 0x1103), vm.regs.read(.ip));
    try std.testing.expectEqual(@as(u16, 0xBEEF), vm.regs.read(.r1));
}
