/// Handlers for `call` / `ret` — the subroutine calling convention.
///
/// `call` lays out the activation record:
///   push fp; push (ip after instruction); fp ← sp; ip ← target.
/// The new `fp` ends up pointing at the saved return ip — the
/// subroutine can push locals below it and still find them via
/// `fp - N` offsets.
///
/// `ret` rewinds locals (`sp ← fp`), pops the return ip, then
/// pops the caller's fp.
const vm_mod = @import("../vm.zig");
const dispatch = @import("../dispatch.zig");
const VM = vm_mod.VM;
const StepResult = dispatch.StepResult;

const ok = StepResult.cont;

fn fault(vm: *VM, vector: dispatch.Vector) StepResult {
    return dispatch.raiseFault(vm, vector);
}

fn enter(vm: *VM, target: u16, ip_after: u16) StepResult {
    dispatch.pushWord(vm, vm.regs.read(.fp));
    dispatch.pushWord(vm, ip_after);
    vm.regs.write(.fp, vm.regs.read(.sp));
    vm.regs.write(.ip, target);
    return .branched;
}

/// `0x80` — `call Addr`.
pub fn callAddr(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const target = vm.mmap.readWord(ip +% 1);
    return enter(vm, target, ip +% 3);
}

/// `0x81` — `call Reg` → `ip ← reg`.
pub fn callReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const reg = vm.mmap.readByte(ip +% 1);
    const target = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    return enter(vm, target, ip +% 2);
}

/// `0x82` — `ret` → unwind activation record and resume the caller.
pub fn ret(vm: *VM) StepResult {
    vm.regs.write(.sp, vm.regs.read(.fp));
    const ret_ip = dispatch.popWord(vm);
    const old_fp = dispatch.popWord(vm);
    vm.regs.write(.fp, old_fp);
    vm.regs.write(.ip, ret_ip);
    return .branched;
}
