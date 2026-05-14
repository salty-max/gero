/// Handlers for the `mov` family and the byte-sized `mov8` /
/// `movh` / `movl` family. None of these affect flags; ip
/// auto-advances by the instruction size after the handler
/// returns `.cont`.
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
    const imm = vm.readWord(ip +% 1);
    const reg = vm.readByte(ip +% 3);
    if (!vm.regs.writeByIndex(reg, imm)) return fault(vm, .invalid_register);
    return ok;
}

/// `0x11` — `mov Reg, Reg` → `dst ← src` (asm: `mov src, dst`).
pub fn movRegReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const src = vm.readByte(ip +% 1);
    const dst = vm.readByte(ip +% 2);
    const value = vm.regs.readByIndex(src) orelse return fault(vm, .invalid_register);
    if (!vm.regs.writeByIndex(dst, value)) return fault(vm, .invalid_register);
    return ok;
}

/// `0x12` — `mov Reg, Addr` → `mem[addr] ← reg`.
pub fn movRegAddr(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const reg = vm.readByte(ip +% 1);
    const addr = vm.readWord(ip +% 2);
    const value = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    vm.writeWord(addr, value);
    return ok;
}

/// `0x13` — `mov Addr, Reg` → `reg ← mem[addr]`.
pub fn movAddrReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const addr = vm.readWord(ip +% 1);
    const reg = vm.readByte(ip +% 3);
    const value = vm.readWord(addr);
    if (!vm.regs.writeByIndex(reg, value)) return fault(vm, .invalid_register);
    return ok;
}

/// `0x14` — `mov Imm16, Addr` → `mem[addr] ← imm`.
pub fn movImm16Addr(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const imm = vm.readWord(ip +% 1);
    const addr = vm.readWord(ip +% 3);
    vm.writeWord(addr, imm);
    return ok;
}

/// `0x15` — `mov Reg, [Reg]` → `dst ← mem[ptr]` (indirect load,
/// Intel order: dst first, ptr second).
pub fn movRegPtr(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const dst = vm.readByte(ip +% 1);
    const ptr = vm.readByte(ip +% 2);
    const addr = vm.regs.readByIndex(ptr) orelse return fault(vm, .invalid_register);
    const value = vm.readWord(addr);
    if (!vm.regs.writeByIndex(dst, value)) return fault(vm, .invalid_register);
    return ok;
}

/// `0x16` — `mov [Reg], Reg` → `mem[ptr] ← src` (indirect store).
pub fn movPtrReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const ptr = vm.readByte(ip +% 1);
    const src = vm.readByte(ip +% 2);
    const addr = vm.regs.readByIndex(ptr) orelse return fault(vm, .invalid_register);
    const value = vm.regs.readByIndex(src) orelse return fault(vm, .invalid_register);
    vm.writeWord(addr, value);
    return ok;
}

/// `0x17` — `mov Addr, Reg, Reg` → `dst ← mem[addr + idx]`
/// (indexed load).
pub fn movIndexed(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const base = vm.readWord(ip +% 1);
    const idx_reg = vm.readByte(ip +% 3);
    const dst = vm.readByte(ip +% 4);
    const offset = vm.regs.readByIndex(idx_reg) orelse return fault(vm, .invalid_register);
    const value = vm.readWord(base +% offset);
    if (!vm.regs.writeByIndex(dst, value)) return fault(vm, .invalid_register);
    return ok;
}

/// `0x18` — `mov Imm16, [Reg]` → `mem[ptr] ← imm`.
pub fn movImm16Ptr(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const imm = vm.readWord(ip +% 1);
    const ptr = vm.readByte(ip +% 3);
    const addr = vm.regs.readByIndex(ptr) orelse return fault(vm, .invalid_register);
    vm.writeWord(addr, imm);
    return ok;
}

/// `0x19` — `mov Reg, ZP` → `mem[zp] ← reg` (zero-page store).
pub fn movRegZp(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const reg = vm.readByte(ip +% 1);
    const zp = vm.readByte(ip +% 2);
    const value = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    vm.writeWord(zp, value);
    return ok;
}

/// `0x1A` — `mov ZP, Reg` → `reg ← mem[zp]` (zero-page load).
pub fn movZpReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const zp = vm.readByte(ip +% 1);
    const reg = vm.readByte(ip +% 2);
    const value = vm.readWord(zp);
    if (!vm.regs.writeByIndex(reg, value)) return fault(vm, .invalid_register);
    return ok;
}

/// `0x1B` — `mov Imm16, ZP` → `mem[zp] ← imm`.
pub fn movImm16Zp(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const imm = vm.readWord(ip +% 1);
    const zp = vm.readByte(ip +% 3);
    vm.writeWord(zp, imm);
    return ok;
}

/// `0x20` — `mov8 Imm8, Addr` → `mem[addr] ← imm` (1 byte).
pub fn mov8Imm8Addr(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const imm = vm.readByte(ip +% 1);
    const addr = vm.readWord(ip +% 2);
    vm.writeByte(addr, imm);
    return ok;
}

/// `0x21` — `mov8 Imm8, Reg` → `reg.lo ← imm; reg.hi ← 0`.
pub fn mov8Imm8Reg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const imm = vm.readByte(ip +% 1);
    const reg = vm.readByte(ip +% 2);
    if (!vm.regs.writeByIndex(reg, imm)) return fault(vm, .invalid_register);
    return ok;
}

/// `0x22` — `mov8 Addr, Reg` → `reg.lo ← mem[addr]; reg.hi ← 0`.
pub fn mov8AddrReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const addr = vm.readWord(ip +% 1);
    const reg = vm.readByte(ip +% 3);
    const value = vm.readByte(addr);
    if (!vm.regs.writeByIndex(reg, value)) return fault(vm, .invalid_register);
    return ok;
}

/// `0x23` — `mov8 Reg, [Reg]` → `mem[ptr] ← reg.lo` (low byte
/// store via pointer register).
pub fn mov8RegPtr(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const src = vm.readByte(ip +% 1);
    const ptr = vm.readByte(ip +% 2);
    const value = vm.regs.readByIndex(src) orelse return fault(vm, .invalid_register);
    const addr = vm.regs.readByIndex(ptr) orelse return fault(vm, .invalid_register);
    // safety: truncating the high half is exactly the spec'd
    //         "mem[ptr] ← reg.lo" behavior for `mov8`
    vm.writeByte(addr, @truncate(value));
    return ok;
}

/// `0x24` — `mov8 [Reg], Reg` → `reg.lo ← mem[ptr]; reg.hi ← 0`.
pub fn mov8PtrReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const ptr = vm.readByte(ip +% 1);
    const dst = vm.readByte(ip +% 2);
    const addr = vm.regs.readByIndex(ptr) orelse return fault(vm, .invalid_register);
    const value = vm.readByte(addr);
    if (!vm.regs.writeByIndex(dst, value)) return fault(vm, .invalid_register);
    return ok;
}

/// `0x29` — `mov8 [Addr + Reg], Reg` → byte-level indexed load:
/// `dst.lo ← mem[addr + idx]; dst.hi ← 0`. Use for stepping
/// through `data8` byte arrays (the word-sized `0x17` overlaps
/// adjacent bytes on each iteration).
pub fn mov8Indexed(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const base = vm.readWord(ip +% 1);
    const idx_reg = vm.readByte(ip +% 3);
    const dst = vm.readByte(ip +% 4);
    const offset = vm.regs.readByIndex(idx_reg) orelse return fault(vm, .invalid_register);
    const value = vm.readByte(base +% offset);
    if (!vm.regs.writeByIndex(dst, value)) return fault(vm, .invalid_register);
    return ok;
}

/// `0x25` — `movh Reg, Addr` → `mem[addr] ← reg.hi`.
pub fn movhRegAddr(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const reg = vm.readByte(ip +% 1);
    const addr = vm.readWord(ip +% 2);
    const value = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    // safety: isolating the high byte is the spec'd "reg.hi" half
    vm.writeByte(addr, @truncate(value >> 8));
    return ok;
}

/// `0x26` — `movl Reg, Addr` → `mem[addr] ← reg.lo`.
pub fn movlRegAddr(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const reg = vm.readByte(ip +% 1);
    const addr = vm.readWord(ip +% 2);
    const value = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    // safety: isolating the low byte is the spec'd "reg.lo" half
    vm.writeByte(addr, @truncate(value));
    return ok;
}

// ---------- Zero-page byte-mov variants ----------
//
// Same semantics as their Addr counterparts (0x20 / 0x22 / 0x25 /
// 0x26) but reading a 1-byte address operand. Peephole-picked when
// an `&XX` literal fits in `0..0xFF`.

/// `0x2A` — `mov8 Imm8, ZP` → `mem[zp] ← imm` (zero-page byte store).
pub fn mov8Imm8Zp(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const imm = vm.readByte(ip +% 1);
    const addr: u16 = vm.readByte(ip +% 2);
    vm.writeByte(addr, imm);
    return ok;
}

/// `0x2B` — `mov8 ZP, Reg` → `reg.lo ← mem[zp]; reg.hi ← 0`.
pub fn mov8ZpReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const addr: u16 = vm.readByte(ip +% 1);
    const reg = vm.readByte(ip +% 2);
    const value = vm.readByte(addr);
    if (!vm.regs.writeByIndex(reg, value)) return fault(vm, .invalid_register);
    return ok;
}

/// `0x2C` — `movh Reg, ZP` → `mem[zp] ← reg.hi` (zero-page hi-byte store).
pub fn movhRegZp(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const reg = vm.readByte(ip +% 1);
    const addr: u16 = vm.readByte(ip +% 2);
    const value = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    // safety: isolating the high byte is the spec'd "reg.hi" half
    vm.writeByte(addr, @truncate(value >> 8));
    return ok;
}

/// `0x2D` — `movl Reg, ZP` → `mem[zp] ← reg.lo` (zero-page lo-byte store).
pub fn movlRegZp(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const reg = vm.readByte(ip +% 1);
    const addr: u16 = vm.readByte(ip +% 2);
    const value = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    // safety: isolating the low byte is the spec'd "reg.lo" half
    vm.writeByte(addr, @truncate(value));
    return ok;
}

/// `0x27` — `bcpy Reg, Reg, Reg` → block copy.
/// `mem[dst..dst+len] ← mem[src..src+len]`, byte-by-byte from
/// low to high (so overlapping ranges with `dst > src` will see
/// corrupted bytes — callers should split or use disjoint
/// regions). Reads three register indices: dst-addr, src-addr,
/// length (in bytes, u16). Maximum transfer is 65535 bytes.
/// Address arithmetic wraps at the 16-bit boundary.
pub fn bcpyRegRegReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const dst_reg = vm.readByte(ip +% 1);
    const src_reg = vm.readByte(ip +% 2);
    const len_reg = vm.readByte(ip +% 3);
    const dst_addr = vm.regs.readByIndex(dst_reg) orelse return fault(vm, .invalid_register);
    const src_addr = vm.regs.readByIndex(src_reg) orelse return fault(vm, .invalid_register);
    const len = vm.regs.readByIndex(len_reg) orelse return fault(vm, .invalid_register);
    var i: u16 = 0;
    while (i < len) : (i +%= 1) {
        const b = vm.readByte(src_addr +% i);
        vm.writeByte(dst_addr +% i, b);
    }
    return ok;
}

/// `0x28` — `bset Reg, Reg, Reg` → block byte-fill.
/// `mem[addr..addr+len] ← val.lo` for each byte. Reads three
/// register indices: dst-addr, length (u16), value (low byte
/// used; high byte ignored). Address arithmetic wraps at the
/// 16-bit boundary.
pub fn bsetRegRegReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const addr_reg = vm.readByte(ip +% 1);
    const len_reg = vm.readByte(ip +% 2);
    const val_reg = vm.readByte(ip +% 3);
    const addr = vm.regs.readByIndex(addr_reg) orelse return fault(vm, .invalid_register);
    const len = vm.regs.readByIndex(len_reg) orelse return fault(vm, .invalid_register);
    const val_word = vm.regs.readByIndex(val_reg) orelse return fault(vm, .invalid_register);
    // safety: truncating to the low byte is the spec'd "val.lo" half
    const val_byte: u8 = @truncate(val_word);
    var i: u16 = 0;
    while (i < len) : (i +%= 1) {
        vm.writeByte(addr +% i, val_byte);
    }
    return ok;
}
