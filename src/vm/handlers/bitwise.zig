/// Handlers for the logical (`and` / `or` / `xor` / `not`) and
/// shift / rotate (`shl` / `shr` / `rol` / `ror`) families.
///
/// Flag policy:
///   - Logical: set `Z` / `N`; clear `C` / `V`.
///   - Shifts:  set `Z` / `N` from result; `C` ← last bit shifted
///              out (unchanged when count = 0); `V` cleared.
///   - Rotates: bits cycle through `C` (17-bit chain — 16 reg
///              bits + 1 carry); `Z` / `N` from result; `V` cleared.
const vm_mod = @import("../vm.zig");
const dispatch = @import("../dispatch.zig");
const VM = vm_mod.VM;
const StepResult = dispatch.StepResult;

const ok = StepResult.cont;

fn fault(vm: *VM, vector: dispatch.Vector) StepResult {
    return dispatch.raiseFault(vm, vector);
}

fn setZN(vm: *VM, result: u16) void {
    vm.regs.setFlag(.zero, result == 0);
    vm.regs.setFlag(.negative, (result & 0x8000) != 0);
}

fn writeLogical(vm: *VM, dst: u8, result: u16) StepResult {
    if (!vm.regs.writeByIndex(dst, result)) return fault(vm, .invalid_register);
    setZN(vm, result);
    vm.regs.setFlag(.carry, false);
    vm.regs.setFlag(.overflow, false);
    return ok;
}

// ---------- and / or / xor / not ----------

/// `0x50` — `and Imm16, Reg` → `reg ← reg & imm` (asm: `and src, dst`).
pub fn andRegImm16(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const imm = vm.readWord(ip +% 1);
    const reg = vm.readByte(ip +% 3);
    const a = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    return writeLogical(vm, reg, a & imm);
}

/// `0x51` — `and Reg, Reg` → `dst ← dst & src` (asm: `and src, dst`).
pub fn andRegReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const src = vm.readByte(ip +% 1);
    const dst = vm.readByte(ip +% 2);
    const a = vm.regs.readByIndex(dst) orelse return fault(vm, .invalid_register);
    const b = vm.regs.readByIndex(src) orelse return fault(vm, .invalid_register);
    return writeLogical(vm, dst, a & b);
}

/// `0x52` — `or Imm16, Reg` → `reg ← reg | imm` (asm: `or src, dst`).
pub fn orRegImm16(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const imm = vm.readWord(ip +% 1);
    const reg = vm.readByte(ip +% 3);
    const a = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    return writeLogical(vm, reg, a | imm);
}

/// `0x53` — `or Reg, Reg` → `dst ← dst | src` (asm: `or src, dst`).
pub fn orRegReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const src = vm.readByte(ip +% 1);
    const dst = vm.readByte(ip +% 2);
    const a = vm.regs.readByIndex(dst) orelse return fault(vm, .invalid_register);
    const b = vm.regs.readByIndex(src) orelse return fault(vm, .invalid_register);
    return writeLogical(vm, dst, a | b);
}

/// `0x54` — `xor Imm16, Reg` → `reg ← reg ^ imm` (asm: `xor src, dst`).
pub fn xorRegImm16(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const imm = vm.readWord(ip +% 1);
    const reg = vm.readByte(ip +% 3);
    const a = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    return writeLogical(vm, reg, a ^ imm);
}

/// `0x55` — `xor Reg, Reg` → `dst ← dst ^ src` (asm: `xor src, dst`).
pub fn xorRegReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const src = vm.readByte(ip +% 1);
    const dst = vm.readByte(ip +% 2);
    const a = vm.regs.readByIndex(dst) orelse return fault(vm, .invalid_register);
    const b = vm.regs.readByIndex(src) orelse return fault(vm, .invalid_register);
    return writeLogical(vm, dst, a ^ b);
}

/// `0x56` — `not Reg` → `reg ← ~reg`.
pub fn notReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const reg = vm.readByte(ip +% 1);
    const a = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    return writeLogical(vm, reg, ~a);
}

// ---------- shifts ----------

const ShiftEffect = struct { result: u16, last_out: bool };

fn doShl(initial: u16, count: u16) ShiftEffect {
    var v = initial;
    var c: bool = false;
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        c = (v & 0x8000) != 0;
        v = v *% 2;
        // Once value reaches zero with no bit-out, further iterations
        // are no-ops — bail to keep large counts cheap.
        if (v == 0 and !c) break;
    }
    return .{ .result = v, .last_out = c };
}

fn doShr(initial: u16, count: u16) ShiftEffect {
    var v = initial;
    var c: bool = false;
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        c = (v & 1) != 0;
        v = v >> 1;
        if (v == 0 and !c) break;
    }
    return .{ .result = v, .last_out = c };
}

fn writeShift(vm: *VM, dst: u8, count: u16, eff: ShiftEffect) StepResult {
    if (!vm.regs.writeByIndex(dst, eff.result)) return fault(vm, .invalid_register);
    setZN(vm, eff.result);
    // C unchanged on no-op shift; otherwise reflects the last bit out.
    if (count != 0) vm.regs.setFlag(.carry, eff.last_out);
    vm.regs.setFlag(.overflow, false);
    return ok;
}

/// `0x58` — `shl Reg, Imm8` → `reg ← reg << imm`.
pub fn shlRegImm8(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const reg = vm.readByte(ip +% 1);
    const count = vm.readByte(ip +% 2);
    const a = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    return writeShift(vm, reg, count, doShl(a, count));
}

/// `0x59` — `shl Reg, Reg` → `dst ← dst << src` (count taken from src).
pub fn shlRegReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const dst = vm.readByte(ip +% 1);
    const src = vm.readByte(ip +% 2);
    const a = vm.regs.readByIndex(dst) orelse return fault(vm, .invalid_register);
    const count = vm.regs.readByIndex(src) orelse return fault(vm, .invalid_register);
    return writeShift(vm, dst, count, doShl(a, count));
}

/// `0x5A` — `shr Reg, Imm8` → `reg ← reg >> imm` (logical, zero-fill).
pub fn shrRegImm8(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const reg = vm.readByte(ip +% 1);
    const count = vm.readByte(ip +% 2);
    const a = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    return writeShift(vm, reg, count, doShr(a, count));
}

/// `0x5B` — `shr Reg, Reg`.
pub fn shrRegReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const dst = vm.readByte(ip +% 1);
    const src = vm.readByte(ip +% 2);
    const a = vm.regs.readByIndex(dst) orelse return fault(vm, .invalid_register);
    const count = vm.regs.readByIndex(src) orelse return fault(vm, .invalid_register);
    return writeShift(vm, dst, count, doShr(a, count));
}

// ---------- rotates ----------

fn doRol(initial: u16, count_in: u16, carry_in: bool) ShiftEffect {
    // 17-bit chain (16 reg bits + 1 carry slot) cycles back to the
    // start every 17 rotations — modulo first to keep cost bounded.
    var v = initial;
    var c = carry_in;
    const count = count_in % 17;
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        const next_c = (v & 0x8000) != 0;
        const carry_bit: u16 = if (c) 1 else 0;
        v = (v *% 2) | carry_bit;
        c = next_c;
    }
    return .{ .result = v, .last_out = c };
}

fn doRor(initial: u16, count_in: u16, carry_in: bool) ShiftEffect {
    var v = initial;
    var c = carry_in;
    const count = count_in % 17;
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        const next_c = (v & 1) != 0;
        const carry_bit: u16 = if (c) 0x8000 else 0;
        v = (v >> 1) | carry_bit;
        c = next_c;
    }
    return .{ .result = v, .last_out = c };
}

fn writeRotate(vm: *VM, dst: u8, count: u16, eff: ShiftEffect) StepResult {
    if (!vm.regs.writeByIndex(dst, eff.result)) return fault(vm, .invalid_register);
    setZN(vm, eff.result);
    if (count % 17 != 0) vm.regs.setFlag(.carry, eff.last_out);
    vm.regs.setFlag(.overflow, false);
    return ok;
}

/// `0x5C` — `rol Reg, Imm8` → rotate left through carry.
pub fn rolRegImm8(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const reg = vm.readByte(ip +% 1);
    const count = vm.readByte(ip +% 2);
    const a = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    const c_in = vm.regs.flagSet(.carry);
    return writeRotate(vm, reg, count, doRol(a, count, c_in));
}

/// `0x5D` — `rol Reg, Reg` (count from src register).
pub fn rolRegReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const dst = vm.readByte(ip +% 1);
    const src = vm.readByte(ip +% 2);
    const a = vm.regs.readByIndex(dst) orelse return fault(vm, .invalid_register);
    const count = vm.regs.readByIndex(src) orelse return fault(vm, .invalid_register);
    const c_in = vm.regs.flagSet(.carry);
    return writeRotate(vm, dst, count, doRol(a, count, c_in));
}

/// `0x5E` — `ror Reg, Imm8` → rotate right through carry.
pub fn rorRegImm8(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const reg = vm.readByte(ip +% 1);
    const count = vm.readByte(ip +% 2);
    const a = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    const c_in = vm.regs.flagSet(.carry);
    return writeRotate(vm, reg, count, doRor(a, count, c_in));
}

/// `0x5F` — `ror Reg, Reg`.
pub fn rorRegReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const dst = vm.readByte(ip +% 1);
    const src = vm.readByte(ip +% 2);
    const a = vm.regs.readByIndex(dst) orelse return fault(vm, .invalid_register);
    const count = vm.regs.readByIndex(src) orelse return fault(vm, .invalid_register);
    const c_in = vm.regs.flagSet(.carry);
    return writeRotate(vm, dst, count, doRor(a, count, c_in));
}
