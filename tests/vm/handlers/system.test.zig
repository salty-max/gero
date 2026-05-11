const std = @import("std");
const gero = @import("gero");
const VM = gero.vm.VM;

fn loadProgram(vm: *VM, bytes: []const u8) void {
    vm.regs.write(.ip, 0x1100);
    for (bytes, 0..) |b, i| {
        vm.mmap.writeByte(0x1100 + @as(u16, @intCast(i)), b);
    }
}

// ---------- misc ----------

test "swap 0x90: registers exchanged, ip advances 3 bytes" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x1111);
    vm.regs.write(.r2, 0x2222);
    loadProgram(&vm, &.{ 0x90, 0x02, 0x03 }); // swap r1, r2
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x2222), vm.regs.read(.r1));
    try std.testing.expectEqual(@as(u16, 0x1111), vm.regs.read(.r2));
    try std.testing.expectEqual(@as(u16, 0x1103), vm.regs.read(.ip));
}

test "swap 0x90: invalid register raises fault" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.mmap.writeWord(gero.vm.ivtSlot(.invalid_register), 0x5000);
    loadProgram(&vm, &.{ 0x90, 0x02, 0xFF });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x5000), vm.regs.read(.ip));
}

test "nop 0x91: nothing changes except ip" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0xCAFE);
    vm.regs.write(.flg, 0xFFFF);
    const flg_before = vm.regs.read(.flg);
    loadProgram(&vm, &.{0x91});
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0xCAFE), vm.regs.read(.r1));
    try std.testing.expectEqual(flg_before, vm.regs.read(.flg));
    try std.testing.expectEqual(@as(u16, 0x1101), vm.regs.read(.ip));
}

// ---------- flag manipulation ----------

test "clc 0xA0: clears C, leaves other flags intact" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.flg, 0xFFFF);
    loadProgram(&vm, &.{0xA0});
    _ = gero.vm.step(&vm);
    try std.testing.expect(!vm.regs.flagSet(.carry));
    // Other flags untouched.
    try std.testing.expect(vm.regs.flagSet(.zero));
    try std.testing.expect(vm.regs.flagSet(.negative));
    try std.testing.expect(vm.regs.flagSet(.overflow));
    try std.testing.expect(vm.regs.flagSet(.interrupt_disable));
}

test "sec 0xA1: sets C only" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.flg, 0);
    loadProgram(&vm, &.{0xA1});
    _ = gero.vm.step(&vm);
    try std.testing.expect(vm.regs.flagSet(.carry));
    try std.testing.expect(!vm.regs.flagSet(.zero));
    try std.testing.expect(!vm.regs.flagSet(.negative));
    try std.testing.expect(!vm.regs.flagSet(.overflow));
    try std.testing.expect(!vm.regs.flagSet(.interrupt_disable));
}

test "cli 0xA2 / sei 0xA3: toggle interrupt-disable bit" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.setFlag(.interrupt_disable, true);
    loadProgram(&vm, &.{0xA2}); // cli
    _ = gero.vm.step(&vm);
    try std.testing.expect(!vm.regs.flagSet(.interrupt_disable));

    loadProgram(&vm, &.{0xA3}); // sei
    _ = gero.vm.step(&vm);
    try std.testing.expect(vm.regs.flagSet(.interrupt_disable));
}

test "clv 0xA4: clears V only" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.flg, 0xFFFF);
    loadProgram(&vm, &.{0xA4});
    _ = gero.vm.step(&vm);
    try std.testing.expect(!vm.regs.flagSet(.overflow));
    try std.testing.expect(vm.regs.flagSet(.carry));
}

// ---------- system ----------

test "int 0xFC: pushes state, jumps via vector table, sets flg.I" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    // Map vector 0x21 → 0x4000 (SRAM-flush convention).
    vm.mmap.writeWord(0x1042, 0x4000); // 0x1000 + 2 * 0x21
    vm.regs.write(.fp, 0xBEEF);
    vm.regs.write(.flg, 0x000F);
    loadProgram(&vm, &.{ 0xFC, 0x21 }); // int 0x21
    _ = gero.vm.step(&vm);

    try std.testing.expectEqual(@as(u16, 0x4000), vm.regs.read(.ip));
    try std.testing.expect(vm.regs.flagSet(.interrupt_disable));
    // Pushed in order: post-int ip (0x1102), fp, flg → top of stack = flg.
    try std.testing.expectEqual(@as(u16, 0x1102), vm.mmap.readWord(0xFFFC));
    try std.testing.expectEqual(@as(u16, 0xBEEF), vm.mmap.readWord(0xFFFA));
    try std.testing.expectEqual(@as(u16, 0x000F), vm.mmap.readWord(0xFFF8));
}

test "int 0xFC: unhandled vector halts on fault" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    // IVT is zero-initialized; vector 0x20 slot = 0 → halts.
    loadProgram(&vm, &.{ 0xFC, 0x20 });
    try std.testing.expectEqual(gero.vm.StepResult.halted_on_fault, gero.vm.step(&vm));
}

test "rti 0xFD: pops flg / fp / ip in reverse push order" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    // Pre-stage the stack as if an `int` had just fired (top = flg).
    vm.regs.write(.sp, 0xFFF8);
    vm.mmap.writeWord(0xFFFC, 0x2222); // saved ip
    vm.mmap.writeWord(0xFFFA, 0x3333); // saved fp
    vm.mmap.writeWord(0xFFF8, 0x0000); // saved flg (I clear)
    // Pre-set flg.I to true so we can verify it's restored to clear.
    vm.regs.setFlag(.interrupt_disable, true);

    loadProgram(&vm, &.{0xFD});
    _ = gero.vm.step(&vm);

    try std.testing.expectEqual(@as(u16, 0x2222), vm.regs.read(.ip));
    try std.testing.expectEqual(@as(u16, 0x3333), vm.regs.read(.fp));
    try std.testing.expectEqual(@as(u16, 0x0000), vm.regs.read(.flg));
    try std.testing.expect(!vm.regs.flagSet(.interrupt_disable));
    // sp returns to pre-frame position.
    try std.testing.expectEqual(@as(u16, 0xFFFE), vm.regs.read(.sp));
}

test "int + rti round-trip: caller resumes at post-int ip with state intact" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.mmap.writeWord(0x1042, 0x4000); // vector 0x21 → ISR at 0x4000
    vm.regs.write(.fp, 0xBEEF);
    vm.regs.write(.flg, 0x000F);
    // 0x1100: int 0x21
    // 0x4000: rti
    loadProgram(&vm, &.{ 0xFC, 0x21 });
    vm.mmap.writeByte(0x4000, 0xFD);

    _ = gero.vm.step(&vm); // int — jumps to ISR, flg.I set
    _ = gero.vm.step(&vm); // rti — returns to caller

    // Caller restored.
    try std.testing.expectEqual(@as(u16, 0x1102), vm.regs.read(.ip));
    try std.testing.expectEqual(@as(u16, 0xBEEF), vm.regs.read(.fp));
    try std.testing.expectEqual(@as(u16, 0x000F), vm.regs.read(.flg));
    try std.testing.expect(!vm.regs.flagSet(.interrupt_disable));
    try std.testing.expectEqual(@as(u16, 0xFFFE), vm.regs.read(.sp));
}

test "brk 0xFE: returns breakpoint, ip advances past it for resume" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    loadProgram(&vm, &.{0xFE});
    try std.testing.expectEqual(gero.vm.StepResult.breakpoint, gero.vm.step(&vm));
    // ip is past the brk so a subsequent run resumes naturally.
    try std.testing.expectEqual(@as(u16, 0x1101), vm.regs.read(.ip));
}

test "hlt 0xFF: returns halted, ip stays on hlt instruction" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    loadProgram(&vm, &.{0xFF});
    try std.testing.expectEqual(gero.vm.StepResult.halted, gero.vm.step(&vm));
    // ip parked on hlt — the program is done.
    try std.testing.expectEqual(@as(u16, 0x1100), vm.regs.read(.ip));
}

test "run: exits on hlt" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    loadProgram(&vm, &.{ 0x91, 0x91, 0xFF }); // nop, nop, hlt
    try std.testing.expectEqual(gero.vm.StepResult.halted, gero.vm.run(&vm));
    try std.testing.expectEqual(@as(u16, 0x1102), vm.regs.read(.ip));
}

test "run: exits on brk, but resuming continues to hlt" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    loadProgram(&vm, &.{ 0x91, 0xFE, 0xFF }); // nop, brk, hlt
    try std.testing.expectEqual(gero.vm.StepResult.breakpoint, gero.vm.run(&vm));
    // ip is past the brk.
    try std.testing.expectEqual(@as(u16, 0x1102), vm.regs.read(.ip));

    // Host resumes.
    try std.testing.expectEqual(gero.vm.StepResult.halted, gero.vm.run(&vm));
}
