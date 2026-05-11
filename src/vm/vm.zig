/// The gero VM. Composes the register file and 64KB memory.
/// Banking, the host mapper indirection, and the dispatch loop
/// layer on top in subsequent PRs.
const std = @import("std");
const registers = @import("registers.zig");
const memory = @import("memory.zig");

/// Re-export: named register handles.
pub const Register = registers.Register;
/// Re-export: register file type.
pub const Registers = registers.Registers;
/// Re-export: flag bit positions inside `flg`.
pub const Flag = registers.Flag;
/// Re-export: 64KB memory type.
pub const Memory = memory.Memory;

/// Boot-state default for `sp` — top of memory minus 1 word so the
/// first push lands on a valid word.
pub const sp_boot: u16 = 0xFFFE;

/// Boot-state default for `fp` — same as `sp_boot` (no frames open).
pub const fp_boot: u16 = 0xFFFE;

/// Boot-state default for `im` — every maskable vector enabled.
pub const im_boot: u16 = 0xFFFF;

/// The VM. Owns the register file and a flat 64KB memory.
pub const VM = struct {
    regs: Registers,
    mem: Memory,

    /// Construct a fresh VM with default boot state. `ip` is left
    /// at 0; the loader sets it to the program's entry point.
    pub fn init() VM {
        var vm: VM = .{
            .regs = Registers.init(),
            .mem = Memory.init(),
        };
        vm.bootInitRegisters();
        return vm;
    }

    /// Re-applies the register defaults. Public so the loader can
    /// re-boot between programs without recreating memory (memory
    /// is deliberately preserved — useful for SRAM-backed runs).
    pub fn bootInitRegisters(self: *VM) void {
        self.regs.write(.ip, 0);
        self.regs.write(.acu, 0);
        self.regs.write(.r1, 0);
        self.regs.write(.r2, 0);
        self.regs.write(.r3, 0);
        self.regs.write(.r4, 0);
        self.regs.write(.r5, 0);
        self.regs.write(.r6, 0);
        self.regs.write(.r7, 0);
        self.regs.write(.r8, 0);
        self.regs.write(.sp, sp_boot);
        self.regs.write(.fp, fp_boot);
        self.regs.write(.mb, 0);
        self.regs.write(.im, im_boot);
        self.regs.write(.flg, 0);
    }
};
