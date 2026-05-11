const std = @import("std");
const gero = @import("gero");
const VM = gero.vm.VM;

fn loadProgram(vm: *VM, bytes: []const u8) void {
    vm.regs.write(.ip, 0x1100);
    for (bytes, 0..) |b, i| {
        vm.mmap.writeByte(0x1100 + @as(u16, @intCast(i)), b);
    }
}

// ---------- unconditional ----------

test "jmp 0x70 addr: always sets ip to target" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    loadProgram(&vm, &.{ 0x70, 0x00, 0x20 }); // jmp 0x2000
    try std.testing.expectEqual(gero.vm.StepResult.branched, gero.vm.step(&vm));
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));
}

test "jmp 0x70: jump-to-self does NOT advance past the instruction" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    // jmp $1100 — should stay parked on this instruction (infinite loop).
    loadProgram(&vm, &.{ 0x70, 0x00, 0x11 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x1100), vm.regs.read(.ip));
}

test "jmp 0x71 reg: target read from register" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x3000);
    loadProgram(&vm, &.{ 0x71, 0x02 }); // jmp r1
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x3000), vm.regs.read(.ip));
}

// ---------- conditional jumps ----------

test "jeq 0x72: Z=1 branches, Z=0 falls through" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.setFlag(.zero, true);
    loadProgram(&vm, &.{ 0x72, 0x00, 0x20 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));

    // Fall-through case: Z=0 → ip advances past the 3-byte instruction.
    var vm2 = VM.init(std.testing.allocator);
    defer vm2.deinit();
    vm2.regs.setFlag(.zero, false);
    loadProgram(&vm2, &.{ 0x72, 0x00, 0x20 });
    _ = gero.vm.step(&vm2);
    try std.testing.expectEqual(@as(u16, 0x1103), vm2.regs.read(.ip));
}

test "jne 0x73: Z=0 branches" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.setFlag(.zero, false);
    loadProgram(&vm, &.{ 0x73, 0x00, 0x20 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));
}

test "jlt 0x74: N ≠ V branches (signed less)" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.setFlag(.negative, true);
    vm.regs.setFlag(.overflow, false);
    loadProgram(&vm, &.{ 0x74, 0x00, 0x20 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));
}

test "jle 0x75: Z=1 takes the branch" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.setFlag(.zero, true);
    loadProgram(&vm, &.{ 0x75, 0x00, 0x20 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));
}

test "jle 0x75: Z=0 N≠V (signed less) takes the branch" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.setFlag(.zero, false);
    vm.regs.setFlag(.negative, false);
    vm.regs.setFlag(.overflow, true);
    loadProgram(&vm, &.{ 0x75, 0x00, 0x20 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));
}

test "jgt 0x76: Z=0 ∧ N=V branches" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.setFlag(.zero, false);
    vm.regs.setFlag(.negative, false);
    vm.regs.setFlag(.overflow, false);
    loadProgram(&vm, &.{ 0x76, 0x00, 0x20 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));
}

test "jge 0x77: N=V branches (includes Z=1)" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.setFlag(.zero, true);
    vm.regs.setFlag(.negative, true);
    vm.regs.setFlag(.overflow, true);
    loadProgram(&vm, &.{ 0x77, 0x00, 0x20 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));
}

test "jcc 0x78: C=0 branches" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.setFlag(.carry, false);
    loadProgram(&vm, &.{ 0x78, 0x00, 0x20 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));
}

test "jcs 0x79: C=1 branches" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.setFlag(.carry, true);
    loadProgram(&vm, &.{ 0x79, 0x00, 0x20 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));
}

test "jvc 0x7A: V=0 branches" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.setFlag(.overflow, false);
    loadProgram(&vm, &.{ 0x7A, 0x00, 0x20 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));
}

test "jvs 0x7B: V=1 branches" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.setFlag(.overflow, true);
    loadProgram(&vm, &.{ 0x7B, 0x00, 0x20 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));
}

test "jz 0x7C / jnz 0x7D: aliases for jeq / jne" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.setFlag(.zero, true);
    loadProgram(&vm, &.{ 0x7C, 0x00, 0x20 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));

    var vm2 = VM.init(std.testing.allocator);
    defer vm2.deinit();
    vm2.regs.setFlag(.zero, false);
    loadProgram(&vm2, &.{ 0x7D, 0x00, 0x30 });
    _ = gero.vm.step(&vm2);
    try std.testing.expectEqual(@as(u16, 0x3000), vm2.regs.read(.ip));
}

test "conditional jumps: fall-through matrix when the condition is false" {
    // Flag bits: Z=0, N=1, C=2, V=3 in the `flg` register.
    const Case = struct { opcode: u8, flg: u16, label: []const u8 };
    const cases = [_]Case{
        .{ .opcode = 0x72, .flg = 0b0000, .label = "jeq with Z=0" },
        .{ .opcode = 0x73, .flg = 0b0001, .label = "jne with Z=1" },
        .{ .opcode = 0x74, .flg = 0b0000, .label = "jlt with N=V=0" },
        .{ .opcode = 0x74, .flg = 0b1010, .label = "jlt with N=V=1" },
        .{ .opcode = 0x75, .flg = 0b0000, .label = "jle with Z=0, N=V=0" },
        .{ .opcode = 0x76, .flg = 0b0001, .label = "jgt with Z=1" },
        .{ .opcode = 0x76, .flg = 0b1000, .label = "jgt with N≠V" },
        .{ .opcode = 0x77, .flg = 0b0010, .label = "jge with N=1, V=0" },
        .{ .opcode = 0x77, .flg = 0b1000, .label = "jge with N=0, V=1" },
        .{ .opcode = 0x78, .flg = 0b0100, .label = "jcc with C=1" },
        .{ .opcode = 0x79, .flg = 0b0000, .label = "jcs with C=0" },
        .{ .opcode = 0x7A, .flg = 0b1000, .label = "jvc with V=1" },
        .{ .opcode = 0x7B, .flg = 0b0000, .label = "jvs with V=0" },
        .{ .opcode = 0x7C, .flg = 0b0000, .label = "jz with Z=0" },
        .{ .opcode = 0x7D, .flg = 0b0001, .label = "jnz with Z=1" },
    };
    for (cases) |c| {
        var vm = VM.init(std.testing.allocator);
        defer vm.deinit();
        vm.regs.write(.flg, c.flg);
        loadProgram(&vm, &.{ c.opcode, 0x00, 0x20 });
        _ = gero.vm.step(&vm);
        // Fall-through advances past the 3-byte instruction.
        std.testing.expectEqual(@as(u16, 0x1103), vm.regs.read(.ip)) catch |e| {
            std.debug.print("\nfall-through failed: {s}\n", .{c.label});
            return e;
        };
    }
}

// ---------- djnz ----------

test "djnz 0x7E: decrement and branch while non-zero" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x0003);
    loadProgram(&vm, &.{ 0x7E, 0x02, 0x00, 0x20 }); // djnz r1, 0x2000
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x0002), vm.regs.read(.r1));
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));
}

test "djnz 0x7E: fall through when decrement reaches zero" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x0001);
    loadProgram(&vm, &.{ 0x7E, 0x02, 0x00, 0x20 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x0000), vm.regs.read(.r1));
    // Fall-through: ip advances past the 4-byte instruction.
    try std.testing.expectEqual(@as(u16, 0x1104), vm.regs.read(.ip));
}

test "djnz 0x7E: flags are NOT touched by the decrement" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x0001);
    vm.regs.setFlag(.zero, false);
    vm.regs.setFlag(.carry, true);
    loadProgram(&vm, &.{ 0x7E, 0x02, 0x00, 0x20 });
    _ = gero.vm.step(&vm);
    // r1 just hit 0, but Z stays false (djnz is flag-neutral).
    try std.testing.expect(!vm.regs.flagSet(.zero));
    try std.testing.expect(vm.regs.flagSet(.carry));
}

// ---------- jr ----------

test "jr 0x7F: positive offset, post-instruction relative" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    loadProgram(&vm, &.{ 0x7F, 0x10 }); // jr +16
    _ = gero.vm.step(&vm);
    // target = ip(0x1100) + 2 + 16 = 0x1112
    try std.testing.expectEqual(@as(u16, 0x1112), vm.regs.read(.ip));
}

test "jr 0x7F: negative offset rolls back" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    loadProgram(&vm, &.{ 0x7F, 0xFE }); // jr -2 (i8 = -2)
    _ = gero.vm.step(&vm);
    // target = ip(0x1100) + 2 + (-2) = 0x1100 → loops on itself.
    try std.testing.expectEqual(@as(u16, 0x1100), vm.regs.read(.ip));
}

test "jr 0x7F: zero offset advances to next instruction" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    loadProgram(&vm, &.{ 0x7F, 0x00 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x1102), vm.regs.read(.ip));
}

// ---------- fault paths ----------

test "jmp 0x71: invalid register raises invalid-register fault" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.mmap.writeWord(gero.vm.ivtSlot(.invalid_register), 0x5000);
    loadProgram(&vm, &.{ 0x71, 0xFF });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x5000), vm.regs.read(.ip));
}
