/// Handlers for the misc, flag-manipulation, and system families:
/// `swap` / `nop`, `clc` / `sec` / `cli` / `sei` / `clv`, and
/// `int` / `rti` / `brk` / `hlt`. `int` reuses the interrupt-
/// entry path so software interrupts and faults share one
/// implementation.
const vm_mod = @import("../vm.zig");
const dispatch = @import("../dispatch.zig");
const VM = vm_mod.VM;
const StepResult = dispatch.StepResult;

const ok = StepResult.cont;

fn fault(vm: *VM, vector: dispatch.Vector) StepResult {
    return dispatch.raiseFault(vm, vector);
}

// ---------- misc ----------

/// `0x90` — `swap Reg, Reg` → atomic swap.
pub fn swap(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const a_idx = vm.readByte(ip +% 1);
    const b_idx = vm.readByte(ip +% 2);
    const a = vm.regs.readByIndex(a_idx) orelse return fault(vm, .invalid_register);
    const b = vm.regs.readByIndex(b_idx) orelse return fault(vm, .invalid_register);
    if (!vm.regs.writeByIndex(a_idx, b)) return fault(vm, .invalid_register);
    if (!vm.regs.writeByIndex(b_idx, a)) return fault(vm, .invalid_register);
    return ok;
}

/// `0x91` — `nop`.
pub fn nop(vm: *VM) StepResult {
    _ = vm;
    return ok;
}

// ---------- flag manipulation ----------

/// `0xA0` — `clc` → `flg.C ← 0`.
pub fn clc(vm: *VM) StepResult {
    vm.regs.setFlag(.carry, false);
    return ok;
}

/// `0xA1` — `sec` → `flg.C ← 1`.
pub fn sec(vm: *VM) StepResult {
    vm.regs.setFlag(.carry, true);
    return ok;
}

/// `0xA2` — `cli` → `flg.I ← 0` (enable interrupts globally).
pub fn cli(vm: *VM) StepResult {
    vm.regs.setFlag(.interrupt_disable, false);
    return ok;
}

/// `0xA3` — `sei` → `flg.I ← 1` (block interrupts globally).
pub fn sei(vm: *VM) StepResult {
    vm.regs.setFlag(.interrupt_disable, true);
    return ok;
}

/// `0xA4` — `clv` → `flg.V ← 0`.
pub fn clv(vm: *VM) StepResult {
    vm.regs.setFlag(.overflow, false);
    return ok;
}

// ---------- system ----------

/// `0xFC` — `int Imm8` → software interrupt: pushes the
/// post-instruction `ip`, then `fp` / `flg`, sets `flg.I`, jumps
/// to `mem[0x1000 + 2*imm]`. Shares the entry sequence with
/// VM-emitted faults.
pub fn intImm8(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const vector_byte = vm.readByte(ip +% 1);
    // Advance ip so the saved return address points at the
    // instruction AFTER int N, not at int itself.
    vm.regs.write(.ip, ip +% 2);
    const vector: dispatch.Vector = @enumFromInt(vector_byte);
    return dispatch.raiseFault(vm, vector);
}

/// `0xFD` — `rti` → pop `flg` / `fp` / `ip` (reverse push
/// order) and resume.
pub fn rti(vm: *VM) StepResult {
    const flg = dispatch.popWord(vm);
    const fp = dispatch.popWord(vm);
    const ret_ip = dispatch.popWord(vm);
    vm.regs.write(.flg, flg);
    vm.regs.write(.fp, fp);
    vm.regs.write(.ip, ret_ip);
    return .branched;
}

/// `0xFE` — `brk` → resumable breakpoint event. Returns
/// `.breakpoint`; `step` auto-advances `ip` past the brk so the
/// host can resume by calling `run` again.
pub fn brk(vm: *VM) StepResult {
    _ = vm;
    return .breakpoint;
}

/// `0xFF` — `hlt` → terminal halt; the program is done.
pub fn hlt(vm: *VM) StepResult {
    _ = vm;
    return .halted;
}
