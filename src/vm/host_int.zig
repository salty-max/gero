// The `int` vectors a host implements by convention.
//
// ISA §6.1 reserves `0x07..0x1F` as host-defined, and the assembler's
// cookbook programs use two of them. They are not VM behaviour — a
// bare VM has no stdout and no save store — so each host has to supply
// them, and every host has to supply the *same* ones or a program that
// prints in a terminal goes silent in a browser.
//
// Shared so that cannot happen.

const std = @import("std");
const VM = @import("vm.zig").VM;

/// Write `r1`'s low byte to the host's output.
pub const print_char: u8 = 0x10;
/// Flush battery-backed SRAM to the host's save store.
pub const sram_flush: u8 = 0x21;

/// The `int` opcode, checked before dispatch so a convention vector
/// never reaches the IVT.
const int_opcode: u8 = 0xFC;

/// What `handle` did with the instruction at `ip`.
pub const Outcome = enum {
    /// Not a convention vector; the caller dispatches normally.
    no,
    /// A character was written to `vm.host.out` and `ip` advanced.
    printed,
    /// `ip` advanced, and the host should now persist
    /// `vm.sramSlice()` wherever it keeps saves.
    ///
    /// Reported rather than performed: every host prints to the same
    /// place — `vm.host.out` — but saves to somewhere different, a
    /// file for the CLI and browser storage for the lab.
    sram_flush_requested,
};

/// Handle the instruction at `ip` when it is one of the conventions,
/// advancing past it.
pub fn handle(vm: *VM) std.Io.Writer.Error!Outcome {
    const ip = vm.regs.read(.ip);
    if (vm.readByte(ip) != int_opcode) return .no;

    switch (vm.readByte(ip +% 1)) {
        print_char => {
            if (vm.host.out) |out| {
                // safety: the low byte is the documented contract for
                // this vector — the register is 16-bit, the character
                // is not.
                try out.writeByte(@truncate(vm.regs.read(.r1)));
            }
            vm.regs.write(.ip, ip +% 2);
            return .printed;
        },
        sram_flush => {
            vm.regs.write(.ip, ip +% 2);
            return .sram_flush_requested;
        },
        else => return .no,
    }
}
