/// Handlers for `cmp` and `tst` — flag-only ops that discard
/// the computed result. `cmp` mirrors `sub` (sets `Z` / `N` /
/// `C` / `V`); `tst` mirrors `and` (sets `Z` / `N`, clears
/// `C` / `V`).
const vm_mod = @import("../vm.zig");
const dispatch = @import("../dispatch.zig");
const VM = vm_mod.VM;
const StepResult = dispatch.StepResult;

const ok = StepResult.cont;

fn fault(vm: *VM, vector: dispatch.Vector) StepResult {
    return dispatch.raiseFault(vm, vector);
}

fn setSubFlags(vm: *VM, a: u16, b: u16) void {
    // @as: widen u16 operands to u32 so the wrapping sub keeps the full result
    const wide: u32 = @as(u32, a) -% @as(u32, b);
    // @as: truncate the wide difference back to u16 for sign / zero checks
    const result: u16 = @as(u16, @truncate(wide));
    vm.regs.setFlag(.zero, result == 0);
    vm.regs.setFlag(.negative, (result & 0x8000) != 0);
    vm.regs.setFlag(.carry, a < b);
    const diff_sign = ((a ^ b) & 0x8000) != 0;
    const result_matches_b = ((b ^ result) & 0x8000) == 0;
    vm.regs.setFlag(.overflow, diff_sign and result_matches_b);
}

fn setAndFlags(vm: *VM, a: u16, b: u16) void {
    const result = a & b;
    vm.regs.setFlag(.zero, result == 0);
    vm.regs.setFlag(.negative, (result & 0x8000) != 0);
    vm.regs.setFlag(.carry, false);
    vm.regs.setFlag(.overflow, false);
}

/// `0x60` — `cmp Reg, Imm16` → set flags from `reg - imm`,
/// discard the result.
pub fn cmpRegImm16(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const reg = vm.readByte(ip +% 1);
    const imm = vm.readWord(ip +% 2);
    const a = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    setSubFlags(vm, a, imm);
    return ok;
}

/// `0x61` — `cmp Reg, Reg` → set flags from `dst - src`.
pub fn cmpRegReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const dst = vm.readByte(ip +% 1);
    const src = vm.readByte(ip +% 2);
    const a = vm.regs.readByIndex(dst) orelse return fault(vm, .invalid_register);
    const b = vm.regs.readByIndex(src) orelse return fault(vm, .invalid_register);
    setSubFlags(vm, a, b);
    return ok;
}

/// `0x62` — `tst Reg, Imm16` → set Z/N from `reg & imm`, clear C/V.
pub fn tstRegImm16(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const reg = vm.readByte(ip +% 1);
    const imm = vm.readWord(ip +% 2);
    const a = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    setAndFlags(vm, a, imm);
    return ok;
}

/// `0x63` — `tst Reg, Reg` → set Z/N from `dst & src`, clear C/V.
pub fn tstRegReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const dst = vm.readByte(ip +% 1);
    const src = vm.readByte(ip +% 2);
    const a = vm.regs.readByIndex(dst) orelse return fault(vm, .invalid_register);
    const b = vm.regs.readByIndex(src) orelse return fault(vm, .invalid_register);
    setAndFlags(vm, a, b);
    return ok;
}
