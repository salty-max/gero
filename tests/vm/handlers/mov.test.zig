const std = @import("std");
const gero = @import("gero");
const VM = gero.vm.VM;

/// Load a sequence of bytes at `0x1100` and set `ip` there.
fn loadProgram(vm: *VM, bytes: []const u8) void {
    vm.regs.write(.ip, 0x1100);
    for (bytes, 0..) |b, i| {
        vm.mmap.writeByte(0x1100 + @as(u16, @intCast(i)), b);
    }
}

/// Save the flag register, run one step, expect the flag register
/// stayed identical (mov family must not touch flags).
fn expectFlagsUnchanged(vm: *VM) !void {
    const before = vm.regs.read(.flg);
    _ = gero.vm.step(vm);
    try std.testing.expectEqual(before, vm.regs.read(.flg));
}

test "mov 0x10 imm16,reg: writes immediate to register" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    loadProgram(&vm, &.{ 0x10, 0xCD, 0xAB, 0x02 }); // mov 0xABCD → r1
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0xABCD), vm.regs.read(.r1));
    try std.testing.expectEqual(@as(u16, 0x1104), vm.regs.read(.ip));
}

test "mov 0x11 reg,reg: copies between registers (dst, src order)" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    vm.regs.write(.r2, 0xDEAD);
    loadProgram(&vm, &.{ 0x11, 0x02, 0x03 }); // mov r1, r2
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0xDEAD), vm.regs.read(.r1));
    try std.testing.expectEqual(@as(u16, 0xDEAD), vm.regs.read(.r2));
    try std.testing.expectEqual(@as(u16, 0x1103), vm.regs.read(.ip));
}

test "mov 0x12 reg,addr: stores register to memory" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    vm.regs.write(.r1, 0xCAFE);
    loadProgram(&vm, &.{ 0x12, 0x02, 0x00, 0x20 }); // mov r1 → mem[0x2000]
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0xCAFE), vm.mmap.readWord(0x2000));
    try std.testing.expectEqual(@as(u16, 0x1104), vm.regs.read(.ip));
}

test "mov 0x13 addr,reg: loads memory into register" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    vm.mmap.writeWord(0x2000, 0xF00D);
    loadProgram(&vm, &.{ 0x13, 0x00, 0x20, 0x02 }); // mov mem[0x2000] → r1
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0xF00D), vm.regs.read(.r1));
    try std.testing.expectEqual(@as(u16, 0x1104), vm.regs.read(.ip));
}

test "mov 0x14 imm16,addr: stores immediate to memory" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    loadProgram(&vm, &.{ 0x14, 0x34, 0x12, 0x00, 0x20 }); // mem[0x2000] = 0x1234
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x1234), vm.mmap.readWord(0x2000));
    try std.testing.expectEqual(@as(u16, 0x1105), vm.regs.read(.ip));
}

test "mov 0x15 reg,[reg]: indirect load via pointer register" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    vm.regs.write(.r2, 0x3000); // ptr
    vm.mmap.writeWord(0x3000, 0xBABE);
    loadProgram(&vm, &.{ 0x15, 0x02, 0x03 }); // r1 ← mem[r2]
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0xBABE), vm.regs.read(.r1));
}

test "mov 0x16 [reg],reg: indirect store via pointer register" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    vm.regs.write(.r1, 0x3000); // ptr
    vm.regs.write(.r2, 0xFACE);
    loadProgram(&vm, &.{ 0x16, 0x02, 0x03 }); // mem[r1] ← r2
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0xFACE), vm.mmap.readWord(0x3000));
}

test "mov 0x17 addr,reg,reg: indexed load (base + offset_reg)" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    vm.regs.write(.r1, 0x10); // offset
    vm.mmap.writeWord(0x2010, 0xBEEF);
    loadProgram(&vm, &.{ 0x17, 0x00, 0x20, 0x02, 0x03 }); // r2 ← mem[0x2000 + r1]
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0xBEEF), vm.regs.read(.r2));
    try std.testing.expectEqual(@as(u16, 0x1105), vm.regs.read(.ip));
}

test "mov 0x18 imm16,[reg]: imm to memory via pointer register" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    vm.regs.write(.r1, 0x3000);
    loadProgram(&vm, &.{ 0x18, 0xAA, 0x55, 0x02 }); // mem[r1] ← 0x55AA
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x55AA), vm.mmap.readWord(0x3000));
}

test "mov 0x19 reg,zp: zero-page store" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    vm.regs.write(.r1, 0x1234);
    loadProgram(&vm, &.{ 0x19, 0x02, 0x40 }); // mem[0x0040] ← r1
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x1234), vm.mmap.readWord(0x0040));
    try std.testing.expectEqual(@as(u16, 0x1103), vm.regs.read(.ip));
}

test "mov 0x1A zp,reg: zero-page load" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    vm.mmap.writeWord(0x0040, 0x5678);
    loadProgram(&vm, &.{ 0x1A, 0x40, 0x02 }); // r1 ← mem[0x0040]
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x5678), vm.regs.read(.r1));
}

test "mov 0x1B imm16,zp: zero-page immediate store" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    loadProgram(&vm, &.{ 0x1B, 0xCD, 0xAB, 0x80 }); // mem[0x0080] ← 0xABCD
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0xABCD), vm.mmap.readWord(0x0080));
    try std.testing.expectEqual(@as(u16, 0x1104), vm.regs.read(.ip));
}

test "mov8 0x20 imm8,addr: byte store" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    loadProgram(&vm, &.{ 0x20, 0x42, 0x00, 0x20 }); // mem[0x2000] ← 0x42 (byte)
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u8, 0x42), vm.mmap.readByte(0x2000));
    try std.testing.expectEqual(@as(u8, 0), vm.mmap.readByte(0x2001));
}

test "mov8 0x21 imm8,reg: byte load zero-extends reg.hi" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    vm.regs.write(.r1, 0xFFFF); // pre-populated with non-zero high
    loadProgram(&vm, &.{ 0x21, 0x42, 0x02 }); // r1.lo ← 0x42; r1.hi ← 0
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x0042), vm.regs.read(.r1));
}

test "mov8 0x22 addr,reg: byte load zero-extends reg.hi" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    vm.regs.write(.r1, 0xFFFF);
    vm.mmap.writeByte(0x2000, 0x7E);
    loadProgram(&vm, &.{ 0x22, 0x00, 0x20, 0x02 }); // r1.lo ← mem[0x2000]
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x007E), vm.regs.read(.r1));
}

test "mov8 0x23 reg,[reg]: byte store via pointer" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    vm.regs.write(.r1, 0xAB12); // source: only low byte (0x12) gets stored
    vm.regs.write(.r2, 0x3000); // pointer
    loadProgram(&vm, &.{ 0x23, 0x02, 0x03 }); // mem[r2] ← r1.lo
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u8, 0x12), vm.mmap.readByte(0x3000));
    try std.testing.expectEqual(@as(u8, 0), vm.mmap.readByte(0x3001));
}

test "mov8 0x24 [reg],reg: byte load via pointer zero-extends" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    vm.regs.write(.r1, 0x3000);
    vm.regs.write(.r2, 0xFFFF);
    vm.mmap.writeByte(0x3000, 0x99);
    loadProgram(&vm, &.{ 0x24, 0x02, 0x03 }); // r2.lo ← mem[r1]
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u16, 0x0099), vm.regs.read(.r2));
}

test "movh 0x25 reg,addr: writes the high byte of reg to memory" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    vm.regs.write(.r1, 0xAB12);
    loadProgram(&vm, &.{ 0x25, 0x02, 0x00, 0x20 }); // mem[0x2000] ← r1.hi
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u8, 0xAB), vm.mmap.readByte(0x2000));
}

test "movl 0x26 reg,addr: writes the low byte of reg to memory" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    vm.regs.write(.r1, 0xAB12);
    loadProgram(&vm, &.{ 0x26, 0x02, 0x00, 0x20 }); // mem[0x2000] ← r1.lo
    _ = gero.vm.step(&vm);
    try std.testing.expectEqual(@as(u8, 0x12), vm.mmap.readByte(0x2000));
}

test "mov family: no variant touches flags" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    vm.regs.write(.r1, 0xDEAD);
    vm.regs.write(.r2, 0x3000);
    vm.regs.write(.flg, 0x000F);

    // Run a representative variant from each section.
    for ([_][]const u8{
        &.{ 0x10, 0x00, 0x00, 0x02 }, // mov imm16,reg
        &.{ 0x11, 0x02, 0x03 }, // mov reg,reg
        &.{ 0x12, 0x02, 0x00, 0x20 }, // mov reg,addr
        &.{ 0x13, 0x00, 0x20, 0x02 }, // mov addr,reg
        &.{ 0x21, 0x42, 0x02 }, // mov8 imm8,reg
        &.{ 0x25, 0x02, 0x00, 0x21 }, // movh reg,addr
    }) |bytes| {
        loadProgram(&vm, bytes);
        try expectFlagsUnchanged(&vm);
    }
}

test "mov: invalid register index raises invalid-register fault" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();

    // Install an ISR for the invalid-register fault.
    vm.mmap.writeWord(gero.vm.ivtSlot(.invalid_register), 0x5000);

    // mov r1, <out-of-range>
    loadProgram(&vm, &.{ 0x11, 0x02, 0xFF });
    try std.testing.expectEqual(gero.vm.StepResult.cont, gero.vm.step(&vm));
    try std.testing.expectEqual(@as(u16, 0x5000), vm.regs.read(.ip));
}
