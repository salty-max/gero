const std = @import("std");
const gero = @import("gero");
const VM = gero.vm.VM;

test "vm: init sets boot-state special registers" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    try std.testing.expectEqual(@as(u16, 0), vm.regs.read(.ip));
    try std.testing.expectEqual(@as(u16, 0), vm.regs.read(.acu));
    try std.testing.expectEqual(@as(u16, 0), vm.regs.read(.r1));
    try std.testing.expectEqual(@as(u16, gero.vm.sp_boot), vm.regs.read(.sp));
    try std.testing.expectEqual(@as(u16, gero.vm.fp_boot), vm.regs.read(.fp));
    try std.testing.expectEqual(@as(u16, 0), vm.regs.read(.mb));
    try std.testing.expectEqual(@as(u16, gero.vm.im_boot), vm.regs.read(.im));
    try std.testing.expectEqual(@as(u16, 0), vm.regs.read(.flg));
}

test "vm: init zeroes memory" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    try std.testing.expectEqual(@as(u8, 0), vm.mmap.readByte(0));
    try std.testing.expectEqual(@as(u8, 0), vm.mmap.readByte(0x1100));
    try std.testing.expectEqual(@as(u8, 0), vm.mmap.readByte(0xFFFF));
}

test "vm: bootInitRegisters resets registers but preserves memory" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0xDEAD);
    vm.regs.write(.flg, 0xFFFF);
    vm.mmap.writeByte(0x1100, 0x42);

    vm.bootInitRegisters();

    try std.testing.expectEqual(@as(u16, 0), vm.regs.read(.r1));
    try std.testing.expectEqual(@as(u16, 0), vm.regs.read(.flg));
    try std.testing.expectEqual(@as(u16, gero.vm.sp_boot), vm.regs.read(.sp));
    // Memory deliberately preserved across re-boot.
    try std.testing.expectEqual(@as(u8, 0x42), vm.mmap.readByte(0x1100));
}

test "vm: registers and memory are independently mutable" {
    var vm = VM.init(std.testing.allocator);
    defer vm.deinit();
    vm.regs.write(.r1, 0xAAAA);
    vm.mmap.writeWord(0x2000, 0xBBBB);
    try std.testing.expectEqual(@as(u16, 0xAAAA), vm.regs.read(.r1));
    try std.testing.expectEqual(@as(u16, 0xBBBB), vm.mmap.readWord(0x2000));
}

test "vm: multiple VM instances are independent" {
    var a = VM.init(std.testing.allocator);
    defer a.deinit();
    var b = VM.init(std.testing.allocator);
    defer b.deinit();
    a.regs.write(.r1, 0x1111);
    a.mmap.writeByte(0x100, 0x42);
    try std.testing.expectEqual(@as(u16, 0), b.regs.read(.r1));
    try std.testing.expectEqual(@as(u8, 0), b.mmap.readByte(0x100));
}

// ---------- snapshot / restore ----------

const alloc = std.testing.allocator;

/// A device that counts writes, standing in for a live host peripheral.
const CountingDevice = struct {
    writes: usize = 0,
    device: gero.vm.Device = .{ .vtable = &vtable },

    const vtable: gero.vm.Device.VTable = .{
        .readByte = readByte,
        .writeByte = writeByte,
        .readWord = readWord,
        .writeWord = writeWord,
    };

    fn readByte(_: *gero.vm.Device, _: u16) u8 {
        return 0;
    }
    fn writeByte(d: *gero.vm.Device, _: u16, _: u8) void {
        // safety: the mapper hands back the `device` field this struct owns.
        const self: *CountingDevice = @fieldParentPtr("device", d);
        self.writes += 1;
    }
    fn readWord(_: *gero.vm.Device, _: u16) u16 {
        return 0;
    }
    fn writeWord(d: *gero.vm.Device, _: u16, _: u16) void {
        // safety: as above.
        const self: *CountingDevice = @fieldParentPtr("device", d);
        self.writes += 1;
    }
};

test "snapshot: restoring returns registers, RAM and cycles to the captured point" {
    var vm = VM.init(alloc);
    defer vm.deinit();
    vm.regs.write(.acu, 0x1234);
    vm.mmap.mem.bytes[0x2000] = 42;
    vm.cycles = 7;

    var snap = try vm.snapshot(alloc);
    defer snap.deinit();

    vm.regs.write(.acu, 0xFFFF);
    vm.mmap.mem.bytes[0x2000] = 99;
    vm.cycles = 500;

    try vm.restore(snap);
    try std.testing.expectEqual(@as(u16, 0x1234), vm.regs.read(.acu));
    try std.testing.expectEqual(@as(u8, 42), vm.mmap.mem.bytes[0x2000]);
    try std.testing.expectEqual(@as(u64, 7), vm.cycles);
}

test "snapshot: the capture is independent of later writes" {
    var vm = VM.init(alloc);
    defer vm.deinit();
    vm.mmap.mem.bytes[0x300] = 1;

    var snap = try vm.snapshot(alloc);
    defer snap.deinit();

    // Writing through the VM must not reach the captured buffer — a
    // shared allocation is the failure this API exists to prevent.
    vm.mmap.mem.bytes[0x300] = 2;
    try std.testing.expectEqual(@as(u8, 1), snap.ram[0x300]);
}

test "snapshot: two captures of one VM are independent" {
    var vm = VM.init(alloc);
    defer vm.deinit();
    vm.mmap.mem.bytes[0x400] = 10;
    var a = try vm.snapshot(alloc);
    defer a.deinit();

    vm.mmap.mem.bytes[0x400] = 20;
    var b = try vm.snapshot(alloc);
    defer b.deinit();

    try std.testing.expectEqual(@as(u8, 10), a.ram[0x400]);
    try std.testing.expectEqual(@as(u8, 20), b.ram[0x400]);
}

test "snapshot: mapped devices survive a restore" {
    var vm = VM.init(alloc);
    defer vm.deinit();
    var dev: CountingDevice = .{};
    _ = try vm.mmap.map(&dev.device, 0x8000, 0x100);

    vm.mmap.writeByte(0x8000, 1);
    try std.testing.expectEqual(@as(usize, 1), dev.writes);

    var snap = try vm.snapshot(alloc);
    defer snap.deinit();
    try vm.restore(snap);

    // The device stays mapped and stays the same object: a restore
    // returns what the program can change, not what the host owns.
    vm.mmap.writeByte(0x8000, 1);
    try std.testing.expectEqual(@as(usize, 2), dev.writes);
}

test "snapshot: a device's own state is not captured" {
    var vm = VM.init(alloc);
    defer vm.deinit();
    var dev: CountingDevice = .{};
    _ = try vm.mmap.map(&dev.device, 0x8000, 0x100);

    var snap = try vm.snapshot(alloc);
    defer snap.deinit();
    vm.mmap.writeByte(0x8000, 1);
    try vm.restore(snap);

    // The write happened host-side and a restore cannot undo it.
    try std.testing.expectEqual(@as(usize, 1), dev.writes);
}

test "snapshot: bank contents round-trip" {
    var vm = VM.init(alloc);
    defer vm.deinit();
    try vm.installBanks(alloc, 4, 0);
    vm.regs.write(.mb, 1);
    vm.mmap.writeByte(0xBE00, 77);

    var snap = try vm.snapshot(alloc);
    defer snap.deinit();

    vm.mmap.writeByte(0xBE00, 99);
    try vm.restore(snap);
    try std.testing.expectEqual(@as(u8, 77), vm.mmap.readByte(0xBE00));
}

test "snapshot: an unbanked VM captures no bank pool" {
    var vm = VM.init(alloc);
    defer vm.deinit();
    var snap = try vm.snapshot(alloc);
    defer snap.deinit();
    try std.testing.expect(snap.banks == null);
    try vm.restore(snap);
}

test "snapshot: restoring a banked capture into an unbanked VM is rejected" {
    var banked = VM.init(alloc);
    defer banked.deinit();
    try banked.installBanks(alloc, 2, 0);
    var snap = try banked.snapshot(alloc);
    defer snap.deinit();

    var plain = VM.init(alloc);
    defer plain.deinit();
    try std.testing.expectError(error.BankShapeMismatch, plain.restore(snap));
}

// ---------- embedding: more than one VM in one process ----------

test "VM: two instances in one process do not observe each other" {
    // gtx-16 embeds this as a Zig dependency, and a console plus a
    // debugger's replay is two VMs in one process. Nothing in the type
    // forbids that; this pins that nothing in the implementation does
    // either — output, memory, registers and cycle counts all have to
    // stay on their own instance.
    var a = VM.init(alloc);
    defer a.deinit();
    var b = VM.init(alloc);
    defer b.deinit();

    var out_a = std.Io.Writer.Allocating.init(alloc);
    defer out_a.deinit();
    var out_b = std.Io.Writer.Allocating.init(alloc);
    defer out_b.deinit();
    a.host = .{ .out = &out_a.writer };
    b.host = .{ .out = &out_b.writer };

    // The same address in each holds a different program: `int
    // $10` is print_char, and each writes r1's low byte.
    for ([_]*VM{ &a, &b }) |vm| {
        vm.regs.write(.ip, 0x1000);
        vm.writeByte(0x1000, 0xFC); // int
        vm.writeByte(0x1001, 0x10); // print_char
    }
    a.regs.write(.r1, 'A');
    b.regs.write(.r1, 'B');

    // Interleaved, because a shared buffer or cursor would show up as
    // ordering rather than as a wrong value.
    const host_int = gero.vm.host_int;
    try std.testing.expectEqual(host_int.Outcome.printed, try host_int.handle(&a));
    try std.testing.expectEqual(host_int.Outcome.printed, try host_int.handle(&b));

    try std.testing.expectEqualStrings("A", out_a.written());
    try std.testing.expectEqualStrings("B", out_b.written());
    try std.testing.expectEqual(@as(u16, 0x1002), a.regs.read(.ip));
    try std.testing.expectEqual(@as(u16, 0x1002), b.regs.read(.ip));
}

test "VM: instances hold their own memory at the same address" {
    var a = VM.init(alloc);
    defer a.deinit();
    var b = VM.init(alloc);
    defer b.deinit();

    a.writeByte(0x2000, 0xAA);
    b.writeByte(0x2000, 0xBB);
    a.writeWord(0x3000, 0x1234);
    b.writeWord(0x3000, 0x5678);

    try std.testing.expectEqual(@as(u8, 0xAA), a.readByte(0x2000));
    try std.testing.expectEqual(@as(u8, 0xBB), b.readByte(0x2000));
    try std.testing.expectEqual(@as(u16, 0x1234), a.readWord(0x3000));
    try std.testing.expectEqual(@as(u16, 0x5678), b.readWord(0x3000));
}

test "VM: a fault in one instance leaves the other running" {
    var faulting = VM.init(alloc);
    defer faulting.deinit();
    var healthy = VM.init(alloc);
    defer healthy.deinit();

    // No ISR is installed, so an illegal opcode stops this one where
    // it stands. `last_fault` is per-instance state, and a shared one
    // would stop the other too.
    faulting.regs.write(.ip, 0x1000);
    faulting.writeByte(0x1000, 0x00); // no handler is bound here

    healthy.regs.write(.ip, 0x1000);
    healthy.writeByte(0x1000, 0xFF); // hlt

    try std.testing.expectEqual(gero.vm.StepResult.halted_on_fault, gero.vm.step(&faulting));
    try std.testing.expect(faulting.last_fault != null);

    try std.testing.expectEqual(gero.vm.StepResult.halted, gero.vm.step(&healthy));
    try std.testing.expectEqual(@as(?gero.vm.Vector, null), healthy.last_fault);
}

/// A sink that steps a second VM while the first is mid-instruction.
///
/// The buffer is empty so every write reaches `drain` immediately,
/// which is what makes the nesting real rather than deferred to a
/// flush.
const ReentrantSink = struct {
    writer: std.Io.Writer,
    other: *VM,
    other_result: ?gero.vm.StepResult = null,
    byte: ?u8 = null,

    fn init(other: *VM) ReentrantSink {
        return .{
            .writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
            .other = other,
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *ReentrantSink = @fieldParentPtr("writer", w);
        for (data) |chunk| {
            if (chunk.len > 0) {
                self.byte = chunk[0];
                break;
            }
        }
        // The nested call: the outer VM has not finished its
        // instruction, and this drives another one to completion.
        self.other_result = gero.vm.step(self.other);
        // The last slice repeats `splat` times, per the vtable's
        // contract; reporting fewer bytes than were consumed would
        // make the writer retry them.
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |chunk| total += chunk.len;
        total += data[data.len - 1].len * splat;
        return total;
    }
};

test "VM: stepping one instance from inside another's host callback is safe" {
    // gtx-16's console will call back into host code mid-instruction,
    // and that host code may drive a second VM. The dispatch loop
    // therefore may not hold state across a handler call.
    var outer = VM.init(alloc);
    defer outer.deinit();
    var inner = VM.init(alloc);
    defer inner.deinit();

    inner.regs.write(.ip, 0x1000);
    inner.writeByte(0x1000, 0xFF); // hlt

    var sink = ReentrantSink.init(&inner);
    outer.host = .{ .out = &sink.writer };
    outer.regs.write(.ip, 0x1000);
    outer.writeByte(0x1000, 0xFC); // int
    outer.writeByte(0x1001, 0x10); // print_char
    outer.regs.write(.r1, 'Z');

    const host_int = gero.vm.host_int;
    try std.testing.expectEqual(host_int.Outcome.printed, try host_int.handle(&outer));

    // The outer instruction completed correctly despite the nesting.
    try std.testing.expectEqual(@as(u16, 0x1002), outer.regs.read(.ip));
    try std.testing.expectEqual(@as(?u8, 'Z'), sink.byte);

    // And the inner one ran to its own halt inside that call.
    try std.testing.expectEqual(gero.vm.StepResult.halted, sink.other_result.?);
    try std.testing.expectEqual(@as(u64, 1), inner.cycles);
    try std.testing.expectEqual(@as(u64, 0), outer.cycles); // `handle` is not `step`
}
