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

test "jmp 0x90 addr: always sets ip to target" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    loadProgram(&vm, &.{ 0x90, 0x00, 0x20 }); // jmp 0x2000
    try std.testing.expectEqual(gero.vm.StepResult.branched, gero.vm.step(&vm));
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));
}

test "jmp 0x90: jump-to-self does NOT advance past the instruction" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    // jmp $1100 — should stay parked on this instruction (infinite loop).
    loadProgram(&vm, &.{ 0x90, 0x00, 0x11 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x1100), vm.regs.read(.ip));
}

test "jmp 0x91 reg: target read from register" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x3000);
    loadProgram(&vm, &.{ 0x91, 0x02 }); // jmp r1
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x3000), vm.regs.read(.ip));
}

// ---------- conditional jumps ----------

test "jeq 0x92: Z=1 branches, Z=0 falls through" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.setFlag(.zero, true);
    loadProgram(&vm, &.{ 0x92, 0x00, 0x20 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));

    // Fall-through case: Z=0 → ip advances past the 3-byte instruction.
    var vm2 = VM.init(std.testing.allocator);
    defer vm2.deinit();
    vm2.regs.setFlag(.zero, false);
    loadProgram(&vm2, &.{ 0x92, 0x00, 0x20 });
    _ = gero.vm.step(&vm2);
    try std.testing.expectEqual(@as(u16, 0x1103), vm2.regs.read(.ip));
}

test "jne 0x93: Z=0 branches" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.setFlag(.zero, false);
    loadProgram(&vm, &.{ 0x93, 0x00, 0x20 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));
}

test "jlt 0x94: N ≠ V branches (signed less)" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.setFlag(.negative, true);
    vm.regs.setFlag(.overflow, false);
    loadProgram(&vm, &.{ 0x94, 0x00, 0x20 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));
}

test "jle 0x95: Z=1 takes the branch" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.setFlag(.zero, true);
    loadProgram(&vm, &.{ 0x95, 0x00, 0x20 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));
}

test "jle 0x95: Z=0 N≠V (signed less) takes the branch" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.setFlag(.zero, false);
    vm.regs.setFlag(.negative, false);
    vm.regs.setFlag(.overflow, true);
    loadProgram(&vm, &.{ 0x95, 0x00, 0x20 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));
}

test "jgt 0x96: Z=0 ∧ N=V branches" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.setFlag(.zero, false);
    vm.regs.setFlag(.negative, false);
    vm.regs.setFlag(.overflow, false);
    loadProgram(&vm, &.{ 0x96, 0x00, 0x20 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));
}

test "jge 0x97: N=V branches (includes Z=1)" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.setFlag(.zero, true);
    vm.regs.setFlag(.negative, true);
    vm.regs.setFlag(.overflow, true);
    loadProgram(&vm, &.{ 0x97, 0x00, 0x20 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));
}

test "jcc 0x98: C=0 branches" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.setFlag(.carry, false);
    loadProgram(&vm, &.{ 0x98, 0x00, 0x20 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));
}

test "jcs 0x99: C=1 branches" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.setFlag(.carry, true);
    loadProgram(&vm, &.{ 0x99, 0x00, 0x20 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));
}

test "jvc 0x9A: V=0 branches" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.setFlag(.overflow, false);
    loadProgram(&vm, &.{ 0x9A, 0x00, 0x20 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));
}

test "jvs 0x9B: V=1 branches" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.setFlag(.overflow, true);
    loadProgram(&vm, &.{ 0x9B, 0x00, 0x20 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));
}

test "jz 0x9C / jnz 0x9D: aliases for jeq / jne" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.setFlag(.zero, true);
    loadProgram(&vm, &.{ 0x9C, 0x00, 0x20 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));

    var vm2 = VM.init(std.testing.allocator);
    defer vm2.deinit();
    vm2.regs.setFlag(.zero, false);
    loadProgram(&vm2, &.{ 0x9D, 0x00, 0x30 });
    _ = gero.vm.step(&vm2);
    try std.testing.expectEqual(@as(u16, 0x3000), vm2.regs.read(.ip));
}

test "conditional jumps: fall-through matrix when the condition is false" {
    // Flag bits: Z=0, N=1, C=2, V=3 in the `flg` register.
    const Case = struct { opcode: u8, flg: u16, label: []const u8 };
    const cases = [_]Case{
        .{ .opcode = 0x92, .flg = 0b0000, .label = "jeq with Z=0" },
        .{ .opcode = 0x93, .flg = 0b0001, .label = "jne with Z=1" },
        .{ .opcode = 0x94, .flg = 0b0000, .label = "jlt with N=V=0" },
        .{ .opcode = 0x94, .flg = 0b1010, .label = "jlt with N=V=1" },
        .{ .opcode = 0x95, .flg = 0b0000, .label = "jle with Z=0, N=V=0" },
        .{ .opcode = 0x96, .flg = 0b0001, .label = "jgt with Z=1" },
        .{ .opcode = 0x96, .flg = 0b1000, .label = "jgt with N≠V" },
        .{ .opcode = 0x97, .flg = 0b0010, .label = "jge with N=1, V=0" },
        .{ .opcode = 0x97, .flg = 0b1000, .label = "jge with N=0, V=1" },
        .{ .opcode = 0x98, .flg = 0b0100, .label = "jcc with C=1" },
        .{ .opcode = 0x99, .flg = 0b0000, .label = "jcs with C=0" },
        .{ .opcode = 0x9A, .flg = 0b1000, .label = "jvc with V=1" },
        .{ .opcode = 0x9B, .flg = 0b0000, .label = "jvs with V=0" },
        .{ .opcode = 0x9C, .flg = 0b0000, .label = "jz with Z=0" },
        .{ .opcode = 0x9D, .flg = 0b0001, .label = "jnz with Z=1" },
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

test "djnz 0x9E: decrement and branch while non-zero" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x0003);
    loadProgram(&vm, &.{ 0x9E, 0x02, 0x00, 0x20 }); // djnz r1, 0x2000
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x0002), vm.regs.read(.r1));
    try std.testing.expectEqual(@as(u16, 0x2000), vm.regs.read(.ip));
}

test "djnz 0x9E: fall through when decrement reaches zero" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x0001);
    loadProgram(&vm, &.{ 0x9E, 0x02, 0x00, 0x20 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x0000), vm.regs.read(.r1));
    // Fall-through: ip advances past the 4-byte instruction.
    try std.testing.expectEqual(@as(u16, 0x1104), vm.regs.read(.ip));
}

test "djnz 0x9E: flags are NOT touched by the decrement" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x0001);
    vm.regs.setFlag(.zero, false);
    vm.regs.setFlag(.carry, true);
    loadProgram(&vm, &.{ 0x9E, 0x02, 0x00, 0x20 });
    _ = gero.vm.step(&vm);
    // r1 just hit 0, but Z stays false (djnz is flag-neutral).
    try std.testing.expect(!vm.regs.flagSet(.zero));
    try std.testing.expect(vm.regs.flagSet(.carry));
}

// ---------- jr ----------

test "jr 0x9F: positive offset, post-instruction relative" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    loadProgram(&vm, &.{ 0x9F, 0x10 }); // jr +16
    _ = gero.vm.step(&vm);
    // target = ip(0x1100) + 2 + 16 = 0x1112
    try std.testing.expectEqual(@as(u16, 0x1112), vm.regs.read(.ip));
}

test "jr 0x9F: negative offset rolls back" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    loadProgram(&vm, &.{ 0x9F, 0xFE }); // jr -2 (i8 = -2)
    _ = gero.vm.step(&vm);
    // target = ip(0x1100) + 2 + (-2) = 0x1100 → loops on itself.
    try std.testing.expectEqual(@as(u16, 0x1100), vm.regs.read(.ip));
}

test "jr 0x9F: zero offset advances to next instruction" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    loadProgram(&vm, &.{ 0x9F, 0x00 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x1102), vm.regs.read(.ip));
}

// ---------- fault paths ----------

test "jmp 0x91: invalid register raises invalid-register fault" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.mmap.writeWord(gero.vm.ivtSlot(.invalid_register), 0x5000);
    loadProgram(&vm, &.{ 0x91, 0xFF });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x5000), vm.regs.read(.ip));
}
