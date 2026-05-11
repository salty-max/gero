/// The fetch-decode-execute loop. Part 1 wires the dispatch
/// skeleton + fault delivery — every byte at `ip` currently
/// triggers the invalid-opcode fault. The opcode table and
/// named per-opcode stubs land in a follow-up PR.
const std = @import("std");
const vm_mod = @import("vm.zig");
const VM = vm_mod.VM;
const Register = vm_mod.Register;
const Flag = vm_mod.Flag;

/// Base address of the interrupt vector table (ISA §6.1).
pub const ivt_base: u16 = 0x1000;

/// Interrupt / fault vector. Non-exhaustive: only the reserved
/// vectors (ISA §6.1 + §9) get named tags, but any `u8` in
/// `0..0x3F` is a valid vector index — the `int N` opcode can
/// raise host-defined or software-int vectors that aren't named.
pub const Vector = enum(u8) {
    /// Reset — runs at boot when the program's entry point is 0.
    reset = 0x00,
    /// Invalid-opcode fault.
    invalid_opcode = 0x01,
    /// Invalid-register fault.
    invalid_register = 0x02,
    /// Division by zero.
    div_by_zero = 0x03,
    /// Arithmetic overflow (e.g. `div` quotient > 16 bits).
    arith_overflow = 0x05,
    _,
};

/// Outcome of a `step` call.
pub const StepResult = enum {
    /// The VM advanced — keep dispatching.
    cont,
    /// The VM hit `hlt` (no resume).
    halted,
    /// A fault fired but no ISR was installed (vector slot is `0`).
    /// The host should surface the fault to the user.
    halted_on_fault,
};

/// One fetch-decode-execute cycle. Part 1 dispatches every byte
/// to the invalid-opcode fault; later PRs add real handlers.
pub fn step(vm: *VM) StepResult {
    return raiseFault(vm, .invalid_opcode);
}

/// Iterate `step` until it returns anything other than `.cont`.
/// Returns the final outcome (`.halted` or `.halted_on_fault`).
pub fn run(vm: *VM) StepResult {
    while (true) {
        const r = step(vm);
        if (r != .cont) return r;
    }
}

/// Deliver a fault through the interrupt mechanism (ISA §6.2 + §9).
/// If the vector slot is `0` the VM halts with a host-visible
/// fault marker; otherwise the entry sequence pushes `ip` / `fp` /
/// `flg`, sets `flg.I`, and jumps to the ISR.
pub fn raiseFault(vm: *VM, vector: Vector) StepResult {
    const target = vm.mmap.readWord(ivtSlot(vector));
    if (target == 0) return .halted_on_fault;

    pushWord(vm, vm.regs.read(.ip));
    pushWord(vm, vm.regs.read(.fp));
    pushWord(vm, vm.regs.read(.flg));
    vm.regs.setFlag(.interrupt_disable, true);
    vm.regs.write(.ip, target);
    return .cont;
}

/// Address of the slot for `vector` inside the IVT.
pub fn ivtSlot(vector: Vector) u16 {
    // @as: widen the u8 vector index to u16 before the multiply
    return ivt_base + 2 * @as(u16, @intFromEnum(vector));
}

fn pushWord(vm: *VM, value: u16) void {
    // Stack grows downward, `sp` always points at the top word.
    const sp = vm.regs.read(.sp);
    vm.mmap.writeWord(sp, value);
    vm.regs.write(.sp, sp -% 2);
}
