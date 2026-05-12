const std = @import("std");
const gero = @import("gero");
const VM = gero.vm.VM;
const Vector = gero.vm.Vector;

/// Install a vector address in the IVT.
fn setVector(vm: *VM, vector: Vector, target: u16) void {
    vm.mmap.writeWord(gero.vm.ivtSlot(vector), target);
}

test "dispatch: ivtSlot maps reserved vectors to expected addresses" {
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

    try std.testing.expectEqual(gero.vm.StepResult.branched, gero.vm.step(&vm));
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

    // Pre-decrement push: each push decrements sp by 2 before
    // writing. Starting at sp_boot=0xFFFE, the three pushes land
    // at 0xFFFC / 0xFFFA / 0xFFF8 (top of stack = flg).
    try std.testing.expectEqual(@as(u16, 0x1234), vm.mmap.readWord(0xFFFC));
    try std.testing.expectEqual(@as(u16, 0xABCD), vm.mmap.readWord(0xFFFA));
    // flg was 0x000F before the push; flg.I is set AFTER the push.
    try std.testing.expectEqual(@as(u16, 0x000F), vm.mmap.readWord(0xFFF8));
    // sp ends up 6 bytes below boot, pointing at the top (flg).
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

    // Pick bytes that have no handler yet: the invalid-opcode
    // fault should fire on each.
    inline for ([_]u8{ 0x00, 0x68, 0x83, 0xA5 }) |op| {
        vm.regs.write(.ip, 0x1100);
        vm.mmap.writeByte(0x1100, op);
        vm.regs.write(.sp, 0xFFFE);
        vm.regs.write(.flg, 0);
        try std.testing.expectEqual(gero.vm.StepResult.branched, gero.vm.step(&vm));
        try std.testing.expectEqual(@as(u16, 0x4000), vm.regs.read(.ip));
    }
}

// ---------- raiseIrq masking ----------

test "raiseIrq: flg.I set globally blocks delivery" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    setVector(&vm, .invalid_opcode, 0x3000);
    vm.regs.setFlag(.interrupt_disable, true);
    try std.testing.expectEqual(@as(?gero.vm.StepResult, null), gero.vm.raiseIrq(&vm, .invalid_opcode));
    // ip untouched.
    try std.testing.expectEqual(@as(u16, 0), vm.regs.read(.ip));
}

test "raiseIrq: im bit clear blocks vectors 0x00..0x0F" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    setVector(&vm, .invalid_opcode, 0x3000);
    vm.regs.setFlag(.interrupt_disable, false);
    vm.regs.write(.im, 0xFFFD); // bit 1 (= vector 0x01) cleared
    try std.testing.expectEqual(@as(?gero.vm.StepResult, null), gero.vm.raiseIrq(&vm, .invalid_opcode));
}

test "raiseIrq: im bit set delivers vectors 0x00..0x0F" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    setVector(&vm, .invalid_opcode, 0x3000);
    vm.regs.setFlag(.interrupt_disable, false);
    vm.regs.write(.im, 0xFFFF); // every maskable vector enabled
    const r = gero.vm.raiseIrq(&vm, .invalid_opcode);
    try std.testing.expectEqual(@as(?gero.vm.StepResult, .branched), r);
    try std.testing.expectEqual(@as(u16, 0x3000), vm.regs.read(.ip));
}

test "raiseIrq: vectors >= 0x10 ignore im (only respect flg.I)" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    // Vector 0x20 — out of im's reach.
    vm.mmap.writeWord(0x1040, 0x3000); // 0x1000 + 2 * 0x20
    vm.regs.setFlag(.interrupt_disable, false);
    vm.regs.write(.im, 0); // im fully clear
    const v: gero.vm.Vector = @enumFromInt(0x20);
    const r = gero.vm.raiseIrq(&vm, v);
    try std.testing.expectEqual(@as(?gero.vm.StepResult, .branched), r);
    try std.testing.expectEqual(@as(u16, 0x3000), vm.regs.read(.ip));
}

test "raiseFault: unmaskable — fires even with flg.I and im fully blocking" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    setVector(&vm, .div_by_zero, 0x3000);
    vm.regs.setFlag(.interrupt_disable, true);
    vm.regs.write(.im, 0);
    try std.testing.expectEqual(gero.vm.StepResult.branched, gero.vm.raiseFault(&vm, .div_by_zero));
    try std.testing.expectEqual(@as(u16, 0x3000), vm.regs.read(.ip));
}

// ---------- nested interrupts ----------

test "nested interrupts: cli inside ISR1 lets a second int fire and rti unwinds correctly" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    // Vector 0x20 → ISR1 at 0x4000; vector 0x21 → ISR2 at 0x5000.
    vm.mmap.writeWord(0x1040, 0x4000);
    vm.mmap.writeWord(0x1042, 0x5000);
    // main: int 0x20 at 0x1100.
    vm.regs.write(.ip, 0x1100);
    vm.mmap.writeByte(0x1100, 0xFC);
    vm.mmap.writeByte(0x1101, 0x20);
    // ISR1 at 0x4000: cli; int 0x21; rti.
    vm.mmap.writeByte(0x4000, 0xA2); // cli
    vm.mmap.writeByte(0x4001, 0xFC); // int
    vm.mmap.writeByte(0x4002, 0x21);
    vm.mmap.writeByte(0x4003, 0xFD); // rti
    // ISR2 at 0x5000: rti.
    vm.mmap.writeByte(0x5000, 0xFD);

    _ = gero.vm.step(&vm); // int 0x20 → ip=0x4000, flg.I=1
    try std.testing.expectEqual(@as(u16, 0x4000), vm.regs.read(.ip));
    try std.testing.expect(vm.regs.flagSet(.interrupt_disable));

    _ = gero.vm.step(&vm); // cli → flg.I=0
    try std.testing.expect(!vm.regs.flagSet(.interrupt_disable));

    _ = gero.vm.step(&vm); // int 0x21 → ip=0x5000, flg.I=1 (auto-set on entry)
    try std.testing.expectEqual(@as(u16, 0x5000), vm.regs.read(.ip));
    try std.testing.expect(vm.regs.flagSet(.interrupt_disable));

    _ = gero.vm.step(&vm); // rti (ISR2) → back to ISR1 at 0x4003
    try std.testing.expectEqual(@as(u16, 0x4003), vm.regs.read(.ip));
    // flg restored to ISR1's state after cli: I=0.
    try std.testing.expect(!vm.regs.flagSet(.interrupt_disable));

    _ = gero.vm.step(&vm); // rti (ISR1) → back to main at 0x1102
    try std.testing.expectEqual(@as(u16, 0x1102), vm.regs.read(.ip));
    // sp / fp fully unwound to pre-int state.
    try std.testing.expectEqual(@as(u16, 0xFFFE), vm.regs.read(.sp));
    try std.testing.expectEqual(@as(u16, 0xFFFE), vm.regs.read(.fp));
}

test "dispatch: step auto-advances ip by instruction size" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    // 0x91 nop is 1 byte and has no handler yet → faults. Use a
    // mov instead: 0x11 mov reg, reg is 3 bytes total.
    vm.regs.write(.ip, 0x1100);
    vm.mmap.writeByte(0x1100, 0x11);
    vm.mmap.writeByte(0x1101, 0x03); // src = r2
    vm.mmap.writeByte(0x1102, 0x02); // dst = r1
    vm.regs.write(.r2, 0xBEEF);

    try std.testing.expectEqual(gero.vm.StepResult.cont, gero.vm.step(&vm));
    try std.testing.expectEqual(@as(u16, 0x1103), vm.regs.read(.ip));
    try std.testing.expectEqual(@as(u16, 0xBEEF), vm.regs.read(.r1));
}
