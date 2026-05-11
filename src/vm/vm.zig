/// The gero VM. Composes the register file and the memory mapper.
/// Banking and the dispatch loop layer on top in subsequent PRs.
const std = @import("std");
const registers = @import("registers.zig");
const memory = @import("memory.zig");
const mapper = @import("mapper.zig");
const dispatch_mod = @import("dispatch.zig");

/// Re-export: named register handles.
pub const Register = registers.Register;
/// Re-export: register file type.
pub const Registers = registers.Registers;
/// Re-export: flag bit positions inside `flg`.
pub const Flag = registers.Flag;
/// Re-export: 64KB memory type.
pub const Memory = memory.Memory;
/// Re-export: host-pluggable IO interface.
pub const Device = mapper.Device;
/// Re-export: the routing mapper that wraps `Memory`.
pub const MemoryMapper = mapper.MemoryMapper;
/// Re-export: handle returned by `MemoryMapper.map`.
pub const RegionId = mapper.RegionId;
/// Re-export: errors from `MemoryMapper.map`.
pub const MapError = mapper.MapError;
/// Re-export: outcome of `step` / `run`.
pub const StepResult = dispatch_mod.StepResult;
/// Re-export: reserved interrupt / fault vectors.
pub const Vector = dispatch_mod.Vector;
/// Re-export: one fetch-decode-execute cycle.
pub const step = dispatch_mod.step;
/// Re-export: dispatch loop until halt / fault.
pub const run = dispatch_mod.run;
/// Re-export: deliver a fault through the interrupt mechanism.
pub const raiseFault = dispatch_mod.raiseFault;
/// Re-export: address of the IVT slot for a given vector.
pub const ivtSlot = dispatch_mod.ivtSlot;
/// Re-export: IVT base address (ISA §6.1).
pub const ivt_base = dispatch_mod.ivt_base;

/// Boot-state default for `sp` — top of memory minus 1 word so the
/// first push lands on a valid word.
pub const sp_boot: u16 = 0xFFFE;

/// Boot-state default for `fp` — same as `sp_boot` (no frames open).
pub const fp_boot: u16 = 0xFFFE;

/// Boot-state default for `im` — every maskable vector enabled.
pub const im_boot: u16 = 0xFFFF;

/// The VM. Owns the register file and the memory mapper (which
/// owns the 64KB RAM and the host device registry).
pub const VM = struct {
    regs: Registers,
    mmap: MemoryMapper,

    /// Construct a fresh VM with default boot state. `ip` is left
    /// at 0; the loader sets it to the program's entry point. The
    /// `allocator` backs the device registry — pass the runtime
    /// allocator (or `std.testing.allocator` in tests).
    pub fn init(allocator: std.mem.Allocator) VM {
        var vm: VM = .{
            .regs = Registers.init(),
            .mmap = MemoryMapper.init(allocator),
        };
        vm.bootInitRegisters();
        return vm;
    }

    /// Release VM-owned resources (the device registry).
    pub fn deinit(self: *VM) void {
        self.mmap.deinit();
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
