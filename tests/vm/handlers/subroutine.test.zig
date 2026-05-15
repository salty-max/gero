const std = @import("std");
const gero = @import("gero");
const VM = gero.vm.VM;

fn loadProgram(vm: *VM, bytes: []const u8) void {
    vm.regs.write(.ip, 0x1100);
    for (bytes, 0..) |b, i| {
        vm.mmap.writeByte(0x1100 + @as(u16, @intCast(i)), b);
    }
}

test "call 0xa0 addr: pushes fp + ret-ip, sets fp = sp, jumps" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.fp, 0xDEAD);
    loadProgram(&vm, &.{ 0xa0, 0x00, 0x20 }); // call 0x2000
    _ = gero.vm.step(&vm);

    // After call: ip = target.
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));
    // Pushed values (pre-decrement push from sp_boot=0xFFFE):
    //   mem[0xFFFC] = old fp (0xDEAD)
    //   mem[0xFFFA] = ret-ip (0x1103, post-instruction)
    try std.testing.expectEqual(@as(u16, 0xDEAD), vm.mmap.readWord(0xFFFC));
    try std.testing.expectEqual(@as(u16, 0x1103), vm.mmap.readWord(0xFFFA));
    // sp = 0xFFFA after the two pushes; fp = sp (points at ret-ip).
    try std.testing.expectEqual(@as(u16, 0xFFFA), vm.regs.read(.sp));
    try std.testing.expectEqual(@as(u16, 0xFFFA), vm.regs.read(.fp));
}

test "call 0xa1 reg: target from register, ret-ip is post-instruction (+2)" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x3000);
    loadProgram(&vm, &.{ 0xa1, 0x02 }); // call r1
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x3000), vm.regs.read(.ip));
    // Ret-ip pushed = ip_before + 2 = 0x1102.
    try std.testing.expectEqual(@as(u16, 0x1102), vm.mmap.readWord(0xFFFA));
}

test "call/ret round-trip: control returns to the instruction after call" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    // Caller at 0x1100: `call 0x2000` (3 bytes).
    loadProgram(&vm, &.{ 0xa0, 0x00, 0x20 });
    // Subroutine at 0x2000: a bare `ret`.
    vm.mmap.writeByte(0x2000, 0xa2);

    _ = gero.vm.step(&vm); // call
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));
    _ = gero.vm.step(&vm); // ret
    // Return to ip after call = 0x1103.
    try std.testing.expectEqual(@as(u16, 0x1103), vm.regs.read(.ip));
    // Stack and fp restored to pre-call state.
    try std.testing.expectEqual(@as(u16, 0xFFFE), vm.regs.read(.sp));
    try std.testing.expectEqual(@as(u16, 0xFFFE), vm.regs.read(.fp));
}

test "call/ret nested two levels: outer ret reaches the original caller" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    // 0x1100: call 0x2000
    // 0x1103: hlt-marker (we won't execute it)
    loadProgram(&vm, &.{ 0xa0, 0x00, 0x20 });
    // 0x2000: call 0x2100
    // 0x2003: ret
    vm.mmap.writeByte(0x2000, 0xa0);
    vm.mmap.writeWord(0x2001, 0x2100);
    vm.mmap.writeByte(0x2003, 0xa2);
    // 0x2100: ret
    vm.mmap.writeByte(0x2100, 0xa2);

    _ = gero.vm.step(&vm); // outer call → ip=0x2000
    _ = gero.vm.step(&vm); // inner call → ip=0x2100
    try std.testing.expectEqual(@as(u16, 0x2100), vm.regs.read(.ip));
    _ = gero.vm.step(&vm); // inner ret → ip=0x2003
    try std.testing.expectEqual(@as(u16, 0x2003), vm.regs.read(.ip));
    _ = gero.vm.step(&vm); // outer ret → ip=0x1103
    try std.testing.expectEqual(@as(u16, 0x1103), vm.regs.read(.ip));
    // Both frames fully unwound.
    try std.testing.expectEqual(@as(u16, 0xFFFE), vm.regs.read(.sp));
    try std.testing.expectEqual(@as(u16, 0xFFFE), vm.regs.read(.fp));
}

test "ret 0xa2: unwinds locals that the callee pushed below fp" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    // 0x1100: call 0x2000
    loadProgram(&vm, &.{ 0xa0, 0x00, 0x20 });
    // 0x2000: push 0xCAFE (3 bytes) — a local on the stack.
    // 0x2003: ret.
    vm.mmap.writeByte(0x2000, 0x30); // push imm16
    vm.mmap.writeWord(0x2001, 0xCAFE);
    vm.mmap.writeByte(0x2003, 0xa2);

    _ = gero.vm.step(&vm); // call → ip=0x2000, sp moved 4 bytes (fp+ret-ip).
    _ = gero.vm.step(&vm); // push imm16 → sp moves another 2 bytes.
    const sp_inside = vm.regs.read(.sp);
    try std.testing.expectEqual(@as(u16, 0xFFF8), sp_inside);

    _ = gero.vm.step(&vm); // ret
    // sp ← fp drops the local; then pop ip; pop fp. Final sp = pre-call.
    try std.testing.expectEqual(@as(u16, 0xFFFE), vm.regs.read(.sp));
    try std.testing.expectEqual(@as(u16, 0x1103), vm.regs.read(.ip));
}

test "call 0xa1: invalid register raises invalid-register fault" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.mmap.writeWord(gero.vm.ivtSlot(.invalid_register), 0x5000);
    loadProgram(&vm, &.{ 0xa1, 0xFF });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x5000), vm.regs.read(.ip));
}
