/// Handlers for the stack family. All three ops use the
/// pre-decrement push / post-increment pop convention shared
/// with the fault-entry sequence via `dispatch.pushWord` /
/// `dispatch.popWord`.
const vm_mod = @import("../vm.zig");
const dispatch = @import("../dispatch.zig");
const VM = vm_mod.VM;
const StepResult = dispatch.StepResult;

const ok = StepResult.cont;

fn fault(vm: *VM, vector: dispatch.Vector) StepResult {
    return dispatch.raiseFault(vm, vector);
}

/// `0x30` — `push Imm16` → `sp -= 2; mem[sp] = imm`.
pub fn pushImm16(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const imm = vm.mmap.readWord(ip +% 1);
    dispatch.pushWord(vm, imm);
    return ok;
}

/// `0x31` — `push Reg` → `sp -= 2; mem[sp] = reg`.
pub fn pushReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const reg = vm.mmap.readByte(ip +% 1);
    const value = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    dispatch.pushWord(vm, value);
    return ok;
}

/// `0x32` — `pop Reg` → `reg = mem[sp]; sp += 2`.
pub fn popReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const reg = vm.mmap.readByte(ip +% 1);
    const value = dispatch.popWord(vm);
    if (!vm.regs.writeByIndex(reg, value)) return fault(vm, .invalid_register);
    return ok;
}
