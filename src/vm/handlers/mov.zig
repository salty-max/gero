/// Handlers for the `mov` family (ISA §5.1) and the byte-sized
/// `mov8` / `movh` / `movl` family (ISA §5.2). None of these
/// affect flags; ip auto-advances by the instruction size after
/// the handler returns `.cont`.
const vm_mod = @import("../vm.zig");
const dispatch = @import("../dispatch.zig");
const VM = vm_mod.VM;
const StepResult = dispatch.StepResult;

const ok = StepResult.cont;

fn fault(vm: *VM, vector: dispatch.Vector) StepResult {
    return dispatch.raiseFault(vm, vector);
}

/// `0x10` — `mov Imm16, Reg` → `reg ← imm`.
pub fn movImm16Reg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const imm = vm.mmap.readWord(ip +% 1);
    const reg = vm.mmap.readByte(ip +% 3);
    if (!vm.regs.writeByIndex(reg, imm)) return fault(vm, .invalid_register);
    return ok;
}

/// `0x11` — `mov Reg, Reg` → `dst ← src` (Intel order: dst first).
pub fn movRegReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const dst = vm.mmap.readByte(ip +% 1);
    const src = vm.mmap.readByte(ip +% 2);
    const value = vm.regs.readByIndex(src) orelse return fault(vm, .invalid_register);
    if (!vm.regs.writeByIndex(dst, value)) return fault(vm, .invalid_register);
    return ok;
}

/// `0x12` — `mov Reg, Addr` → `mem[addr] ← reg`.
pub fn movRegAddr(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const reg = vm.mmap.readByte(ip +% 1);
    const addr = vm.mmap.readWord(ip +% 2);
    const value = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    vm.mmap.writeWord(addr, value);
    return ok;
}

/// `0x13` — `mov Addr, Reg` → `reg ← mem[addr]`.
pub fn movAddrReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const addr = vm.mmap.readWord(ip +% 1);
    const reg = vm.mmap.readByte(ip +% 3);
    const value = vm.mmap.readWord(addr);
    if (!vm.regs.writeByIndex(reg, value)) return fault(vm, .invalid_register);
    return ok;
}

/// `0x14` — `mov Imm16, Addr` → `mem[addr] ← imm`.
pub fn movImm16Addr(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const imm = vm.mmap.readWord(ip +% 1);
    const addr = vm.mmap.readWord(ip +% 3);
    vm.mmap.writeWord(addr, imm);
    return ok;
}

/// `0x15` — `mov Reg, [Reg]` → `dst ← mem[ptr]` (indirect load,
/// Intel order: dst first, ptr second).
pub fn movRegPtr(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const dst = vm.mmap.readByte(ip +% 1);
    const ptr = vm.mmap.readByte(ip +% 2);
    const addr = vm.regs.readByIndex(ptr) orelse return fault(vm, .invalid_register);
    const value = vm.mmap.readWord(addr);
    if (!vm.regs.writeByIndex(dst, value)) return fault(vm, .invalid_register);
    return ok;
}

/// `0x16` — `mov [Reg], Reg` → `mem[ptr] ← src` (indirect store).
pub fn movPtrReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const ptr = vm.mmap.readByte(ip +% 1);
    const src = vm.mmap.readByte(ip +% 2);
    const addr = vm.regs.readByIndex(ptr) orelse return fault(vm, .invalid_register);
    const value = vm.regs.readByIndex(src) orelse return fault(vm, .invalid_register);
    vm.mmap.writeWord(addr, value);
    return ok;
}

/// `0x17` — `mov Addr, Reg, Reg` → `dst ← mem[addr + idx]`
/// (indexed load).
pub fn movIndexed(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const base = vm.mmap.readWord(ip +% 1);
    const idx_reg = vm.mmap.readByte(ip +% 3);
    const dst = vm.mmap.readByte(ip +% 4);
    const offset = vm.regs.readByIndex(idx_reg) orelse return fault(vm, .invalid_register);
    const value = vm.mmap.readWord(base +% offset);
    if (!vm.regs.writeByIndex(dst, value)) return fault(vm, .invalid_register);
    return ok;
}

/// `0x18` — `mov Imm16, [Reg]` → `mem[ptr] ← imm`.
pub fn movImm16Ptr(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const imm = vm.mmap.readWord(ip +% 1);
    const ptr = vm.mmap.readByte(ip +% 3);
    const addr = vm.regs.readByIndex(ptr) orelse return fault(vm, .invalid_register);
    vm.mmap.writeWord(addr, imm);
    return ok;
}

/// `0x19` — `mov Reg, ZP` → `mem[zp] ← reg` (zero-page store).
pub fn movRegZp(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const reg = vm.mmap.readByte(ip +% 1);
    const zp = vm.mmap.readByte(ip +% 2);
    const value = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    vm.mmap.writeWord(zp, value);
    return ok;
}

/// `0x1A` — `mov ZP, Reg` → `reg ← mem[zp]` (zero-page load).
pub fn movZpReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const zp = vm.mmap.readByte(ip +% 1);
    const reg = vm.mmap.readByte(ip +% 2);
    const value = vm.mmap.readWord(zp);
    if (!vm.regs.writeByIndex(reg, value)) return fault(vm, .invalid_register);
    return ok;
}

/// `0x1B` — `mov Imm16, ZP` → `mem[zp] ← imm`.
pub fn movImm16Zp(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const imm = vm.mmap.readWord(ip +% 1);
    const zp = vm.mmap.readByte(ip +% 3);
    vm.mmap.writeWord(zp, imm);
    return ok;
}

/// `0x20` — `mov8 Imm8, Addr` → `mem[addr] ← imm` (1 byte).
pub fn mov8Imm8Addr(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const imm = vm.mmap.readByte(ip +% 1);
    const addr = vm.mmap.readWord(ip +% 2);
    vm.mmap.writeByte(addr, imm);
    return ok;
}

/// `0x21` — `mov8 Imm8, Reg` → `reg.lo ← imm; reg.hi ← 0`.
pub fn mov8Imm8Reg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const imm = vm.mmap.readByte(ip +% 1);
    const reg = vm.mmap.readByte(ip +% 2);
    if (!vm.regs.writeByIndex(reg, imm)) return fault(vm, .invalid_register);
    return ok;
}

/// `0x22` — `mov8 Addr, Reg` → `reg.lo ← mem[addr]; reg.hi ← 0`.
pub fn mov8AddrReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const addr = vm.mmap.readWord(ip +% 1);
    const reg = vm.mmap.readByte(ip +% 3);
    const value = vm.mmap.readByte(addr);
    if (!vm.regs.writeByIndex(reg, value)) return fault(vm, .invalid_register);
    return ok;
}

/// `0x23` — `mov8 Reg, [Reg]` → `mem[ptr] ← reg.lo` (low byte
/// store via pointer register).
pub fn mov8RegPtr(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const src = vm.mmap.readByte(ip +% 1);
    const ptr = vm.mmap.readByte(ip +% 2);
    const value = vm.regs.readByIndex(src) orelse return fault(vm, .invalid_register);
    const addr = vm.regs.readByIndex(ptr) orelse return fault(vm, .invalid_register);
    // safety: truncating the high half is exactly the spec'd
    //         "mem[ptr] ← reg.lo" behavior for `mov8`
    vm.mmap.writeByte(addr, @truncate(value));
    return ok;
}

/// `0x24` — `mov8 [Reg], Reg` → `reg.lo ← mem[ptr]; reg.hi ← 0`.
pub fn mov8PtrReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const ptr = vm.mmap.readByte(ip +% 1);
    const dst = vm.mmap.readByte(ip +% 2);
    const addr = vm.regs.readByIndex(ptr) orelse return fault(vm, .invalid_register);
    const value = vm.mmap.readByte(addr);
    if (!vm.regs.writeByIndex(dst, value)) return fault(vm, .invalid_register);
    return ok;
}

/// `0x25` — `movh Reg, Addr` → `mem[addr] ← reg.hi`.
pub fn movhRegAddr(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const reg = vm.mmap.readByte(ip +% 1);
    const addr = vm.mmap.readWord(ip +% 2);
    const value = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    // safety: isolating the high byte is the spec'd "reg.hi" half
    vm.mmap.writeByte(addr, @truncate(value >> 8));
    return ok;
}

/// `0x26` — `movl Reg, Addr` → `mem[addr] ← reg.lo`.
pub fn movlRegAddr(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const reg = vm.mmap.readByte(ip +% 1);
    const addr = vm.mmap.readWord(ip +% 2);
    const value = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    // safety: isolating the low byte is the spec'd "reg.lo" half
    vm.mmap.writeByte(addr, @truncate(value));
    return ok;
}
