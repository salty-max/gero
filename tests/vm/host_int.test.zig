//! Mirror file for `src/vm/host_int.zig`.
//!
//! These vectors are host-defined (ISA §6.1 reserves `0x07..0x1F`), so
//! a bare VM faults on them. Every host has to implement them, and
//! every host has to implement the *same* ones — a program that prints
//! in a terminal must print in a browser rather than going silent.

const std = @import("std");
const gero = @import("gero");

const alloc = std.testing.allocator;
const host_int = gero.vm.host_int;

/// A VM whose next instruction is `int <vector>`, with `r1` set.
const Fixture = struct {
    vm: gero.vm.VM,
    out: std.Io.Writer.Allocating,

    fn init(vector: u8, r1: u16) !Fixture {
        var fx: Fixture = .{
            .vm = gero.vm.VM.init(alloc),
            .out = std.Io.Writer.Allocating.init(alloc),
        };
        fx.vm.regs.write(.ip, 0x1000);
        fx.vm.regs.write(.r1, r1);
        fx.vm.writeByte(0x1000, 0xFC); // int
        fx.vm.writeByte(0x1001, vector);
        return fx;
    }

    fn wire(self: *Fixture) void {
        self.vm.host = .{ .out = &self.out.writer };
    }

    fn deinit(self: *Fixture) void {
        self.vm.deinit();
        self.out.deinit();
    }
};

test "handle: int 0x10 writes r1's low byte and advances" {
    var fx = try Fixture.init(host_int.print_char, 0x4142);
    defer fx.deinit();
    fx.wire();

    try std.testing.expectEqual(host_int.Outcome.printed, try host_int.handle(&fx.vm));
    // The low byte is the contract — the register is 16-bit, the
    // character is not.
    try std.testing.expectEqualStrings("B", fx.out.written());
    // Two bytes consumed: the opcode and its vector.
    try std.testing.expectEqual(@as(u16, 0x1002), fx.vm.regs.read(.ip));
}

test "handle: int 0x21 asks the host to save, and advances" {
    var fx = try Fixture.init(host_int.sram_flush, 0);
    defer fx.deinit();
    fx.wire();

    // Where a save goes differs per host, so this reports rather than
    // performs — the CLI writes a file, the lab writes browser storage.
    try std.testing.expectEqual(host_int.Outcome.sram_flush_requested, try host_int.handle(&fx.vm));
    try std.testing.expectEqual(@as(u16, 0x1002), fx.vm.regs.read(.ip));
}

test "handle: any other vector is left to the IVT" {
    var fx = try Fixture.init(0x05, 0);
    defer fx.deinit();
    fx.wire();

    // `int 5` is a program-raised overflow, not a host service — it
    // must reach the vector table rather than being swallowed here.
    try std.testing.expectEqual(host_int.Outcome.no, try host_int.handle(&fx.vm));
    try std.testing.expectEqual(@as(u16, 0x1000), fx.vm.regs.read(.ip));
}

test "handle: a non-int instruction is left alone" {
    var fx = try Fixture.init(host_int.print_char, 0);
    defer fx.deinit();
    fx.wire();
    fx.vm.writeByte(0x1000, 0xFF); // hlt

    try std.testing.expectEqual(host_int.Outcome.no, try host_int.handle(&fx.vm));
    try std.testing.expectEqual(@as(u16, 0x1000), fx.vm.regs.read(.ip));
}

test "handle: printing with no host writer is a no-op, not a fault" {
    var fx = try Fixture.init(host_int.print_char, 'A');
    defer fx.deinit();
    // Deliberately not wired: a VM with nowhere to print must still
    // make progress rather than trapping.
    try std.testing.expectEqual(host_int.Outcome.printed, try host_int.handle(&fx.vm));
    try std.testing.expectEqual(@as(u16, 0x1002), fx.vm.regs.read(.ip));
}
