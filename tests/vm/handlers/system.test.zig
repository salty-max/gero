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

test "swap 0xC0: registers exchanged, ip advances 3 bytes" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0x1111);
    vm.regs.write(.r2, 0x2222);
    loadProgram(&vm, &.{ 0xC0, 0x02, 0x03 }); // swap r1, r2
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x2222), vm.regs.read(.r1));
    try std.testing.expectEqual(@as(u16, 0x1111), vm.regs.read(.r2));
    try std.testing.expectEqual(@as(u16, 0x1103), vm.regs.read(.ip));
}

test "swap 0xC0: invalid register raises fault" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.mmap.writeWord(gero.vm.ivtSlot(.invalid_register), 0x5000);
    loadProgram(&vm, &.{ 0xC0, 0x02, 0xFF });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x5000), vm.regs.read(.ip));
}

test "nop 0xC1: nothing changes except ip" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0xCAFE);
    vm.regs.write(.flg, 0xFFFF);
    const flg_before = vm.regs.read(.flg);
    loadProgram(&vm, &.{0xC1});
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0xCAFE), vm.regs.read(.r1));
    try std.testing.expectEqual(flg_before, vm.regs.read(.flg));
    try std.testing.expectEqual(@as(u16, 0x1101), vm.regs.read(.ip));
}

// ---------- flag manipulation ----------

test "clc 0xB0: clears C, leaves other flags intact" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.flg, 0xFFFF);
    loadProgram(&vm, &.{0xB0});
    _ = gero.vm.step(&vm);
    try std.testing.expect(!vm.regs.flagSet(.carry));
    // Other flags untouched.
    try std.testing.expect(vm.regs.flagSet(.zero));
    try std.testing.expect(vm.regs.flagSet(.negative));
    try std.testing.expect(vm.regs.flagSet(.overflow));
    try std.testing.expect(vm.regs.flagSet(.interrupt_disable));
}

test "sec 0xB1: sets C only" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.flg, 0);
    loadProgram(&vm, &.{0xB1});
    _ = gero.vm.step(&vm);
    try std.testing.expect(vm.regs.flagSet(.carry));
    try std.testing.expect(!vm.regs.flagSet(.zero));
    try std.testing.expect(!vm.regs.flagSet(.negative));
    try std.testing.expect(!vm.regs.flagSet(.overflow));
    try std.testing.expect(!vm.regs.flagSet(.interrupt_disable));
}

test "cli 0xB2 / sei 0xB3: toggle interrupt-disable bit" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.setFlag(.interrupt_disable, true);
    loadProgram(&vm, &.{0xB2}); // cli
    _ = gero.vm.step(&vm);
    try std.testing.expect(!vm.regs.flagSet(.interrupt_disable));

    loadProgram(&vm, &.{0xB3}); // sei
    _ = gero.vm.step(&vm);
    try std.testing.expect(vm.regs.flagSet(.interrupt_disable));
}

test "clv 0xB4: clears V only" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.flg, 0xFFFF);
    loadProgram(&vm, &.{0xB4});
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
    loadProgram(&vm, &.{ 0xC1, 0xC1, 0xFF }); // nop, nop, hlt
    try std.testing.expectEqual(gero.vm.StepResult.halted, gero.vm.run(&vm));
    try std.testing.expectEqual(@as(u16, 0x1102), vm.regs.read(.ip));
}

test "run: exits on brk, but resuming continues to hlt" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    loadProgram(&vm, &.{ 0xC1, 0xFE, 0xFF }); // nop, brk, hlt
    try std.testing.expectEqual(gero.vm.StepResult.breakpoint, gero.vm.run(&vm));
    // ip is past the brk.
    try std.testing.expectEqual(@as(u16, 0x1102), vm.regs.read(.ip));

    // Host resumes.
    try std.testing.expectEqual(gero.vm.StepResult.halted, gero.vm.run(&vm));
}

// ---------- sys 0xFB — host-callback syscalls ----------

fn captureWriter(buf: *std.ArrayList(u8)) std.Io.Writer.Allocating {
    return std.Io.Writer.Allocating.fromArrayList(std.testing.allocator, buf);
}

test "sys 0xFB: print_int writes decimal of acu" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var writer = captureWriter(&buf);
    defer writer.deinit();
    vm.host = .{ .out = &writer.writer };

    vm.regs.write(.acu, 42);
    loadProgram(&vm, &.{ 0xFB, 0x02 }); // sys print_int
    try std.testing.expectEqual(gero.vm.StepResult.cont, gero.vm.step(&vm));
    try std.testing.expectEqualStrings("42", writer.written());
    try std.testing.expectEqual(@as(u16, 0x1102), vm.regs.read(.ip));
}

test "sys 0xFB: print_int formats negative as signed decimal" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var writer = captureWriter(&buf);
    defer writer.deinit();
    vm.host = .{ .out = &writer.writer };

    // -7 as u16 = 0xFFF9
    vm.regs.write(.acu, 0xFFF9);
    loadProgram(&vm, &.{ 0xFB, 0x02 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqualStrings("-7", writer.written());
}

test "sys 0xFB: print_str walks memory from acu until null" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var writer = captureWriter(&buf);
    defer writer.deinit();
    vm.host = .{ .out = &writer.writer };

    // Stash "hi!\0" at 0x2000.
    vm.mmap.writeByte(0x2000, 'h');
    vm.mmap.writeByte(0x2001, 'i');
    vm.mmap.writeByte(0x2002, '!');
    vm.mmap.writeByte(0x2003, 0);
    vm.regs.write(.acu, 0x2000);
    loadProgram(&vm, &.{ 0xFB, 0x01 }); // sys print_str
    _ = gero.vm.step(&vm);
    try std.testing.expectEqualStrings("hi!", writer.written());
}

test "sys 0xFB: print_char writes low byte of acu" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var writer = captureWriter(&buf);
    defer writer.deinit();
    vm.host = .{ .out = &writer.writer };

    vm.regs.write(.acu, 0x4142); // low byte = 0x42 = 'B'
    loadProgram(&vm, &.{ 0xFB, 0x03 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqualStrings("B", writer.written());
}

test "sys 0xFB: print_fixed formats Q8.8 positive value as `int.frac`" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var writer = captureWriter(&buf);
    defer writer.deinit();
    vm.host = .{ .out = &writer.writer };

    // 1.5 in Q8.8 = 1*256 + 128 = 384 → "1.500".
    vm.regs.write(.acu, 384);
    loadProgram(&vm, &.{ 0xFB, 0x05 }); // sys print_fixed
    _ = gero.vm.step(&vm);
    try std.testing.expectEqualStrings("1.500", writer.written());
}

test "sys 0xFB: print_fixed formats Q8.8 negative value with leading `-`" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var writer = captureWriter(&buf);
    defer writer.deinit();
    vm.host = .{ .out = &writer.writer };

    // -2.25 in Q8.8 = -(2*256 + 64) = -576 → as u16 = 0xFDC0 → "-2.250".
    vm.regs.write(.acu, 0xFDC0);
    loadProgram(&vm, &.{ 0xFB, 0x05 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqualStrings("-2.250", writer.written());
}

test "sys 0xFB: format_int_to_buf writes signed decimal at [r1], advances r1" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    // Empty host writer — the format-to-buf family writes to VM
    // memory, never to host.out.
    vm.regs.write(.acu, 0xFFF9); // -7 as i16
    vm.regs.write(.r1, 0x2000);
    loadProgram(&vm, &.{ 0xFB, 0x11 }); // sys format_int_to_buf
    _ = gero.vm.step(&vm);

    try std.testing.expectEqual(@as(u8, '-'), vm.mmap.readByte(0x2000));
    try std.testing.expectEqual(@as(u8, '7'), vm.mmap.readByte(0x2001));
    // r1 advanced past the 2 bytes written.
    try std.testing.expectEqual(@as(u16, 0x2002), vm.regs.read(.r1));
}

test "sys 0xFB: format_str_to_buf copies bytes (excl null) and advances r1" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    // Source string "hi\0" at 0x3000.
    vm.mmap.writeByte(0x3000, 'h');
    vm.mmap.writeByte(0x3001, 'i');
    vm.mmap.writeByte(0x3002, 0);
    vm.regs.write(.acu, 0x3000);
    vm.regs.write(.r1, 0x2000);
    loadProgram(&vm, &.{ 0xFB, 0x10 });
    _ = gero.vm.step(&vm);

    try std.testing.expectEqual(@as(u8, 'h'), vm.mmap.readByte(0x2000));
    try std.testing.expectEqual(@as(u8, 'i'), vm.mmap.readByte(0x2001));
    // null NOT copied — caller calls format_terminate_buf separately.
    try std.testing.expectEqual(@as(u8, 0), vm.mmap.readByte(0x2002));
    try std.testing.expectEqual(@as(u16, 0x2002), vm.regs.read(.r1));
}

test "sys 0xFB: format_terminate_buf writes a null byte at [r1] and advances r1" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    // Pre-poison the slot — the terminator must overwrite it.
    vm.mmap.writeByte(0x2000, 0xAB);
    vm.regs.write(.r1, 0x2000);
    loadProgram(&vm, &.{ 0xFB, 0x14 });
    _ = gero.vm.step(&vm);

    try std.testing.expectEqual(@as(u8, 0), vm.mmap.readByte(0x2000));
    try std.testing.expectEqual(@as(u16, 0x2001), vm.regs.read(.r1));
}

test "sys 0xFB: print_newline writes a single \\n" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var writer = captureWriter(&buf);
    defer writer.deinit();
    vm.host = .{ .out = &writer.writer };

    loadProgram(&vm, &.{ 0xFB, 0x04 });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqualStrings("\n", writer.written());
}

test "sys 0xFB: unknown syscall id raises invalid_opcode fault" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var writer = captureWriter(&buf);
    defer writer.deinit();
    vm.host = .{ .out = &writer.writer };

    vm.mmap.writeWord(gero.vm.ivtSlot(.invalid_opcode), 0x5000);
    loadProgram(&vm, &.{ 0xFB, 0xEE });
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x5000), vm.regs.read(.ip));
    try std.testing.expectEqual(@as(usize, 0), writer.written().len);
}

test "sys 0xFB: with host.out = null, output syscalls are silent no-ops" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    // host.out is null by default — no writer installed.
    vm.regs.write(.acu, 42);
    loadProgram(&vm, &.{ 0xFB, 0x02 });
    try std.testing.expectEqual(gero.vm.StepResult.cont, gero.vm.step(&vm));
    try std.testing.expectEqual(@as(u16, 0x1102), vm.regs.read(.ip));
}
