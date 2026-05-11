/// Handlers for the jump family — unconditional `jmp`, the twelve
/// conditional jumps, the `djnz` loop primitive, and the short
/// relative `jr`. Branch targets are written directly into `ip`
/// and the handler returns `.branched` so dispatch skips the
/// auto-advance.
const vm_mod = @import("../vm.zig");
const dispatch = @import("../dispatch.zig");
const VM = vm_mod.VM;
const StepResult = dispatch.StepResult;

const ok = StepResult.cont;

fn fault(vm: *VM, vector: dispatch.Vector) StepResult {
    return dispatch.raiseFault(vm, vector);
}

fn readAddr(vm: *const VM) u16 {
    return vm.mmap.readWord(vm.regs.read(.ip) +% 1);
}

fn taken(vm: *VM, target: u16) StepResult {
    vm.regs.write(.ip, target);
    return .branched;
}

// ---------- unconditional ----------

/// `0x70` — `jmp Addr`.
pub fn jmpAddr(vm: *VM) StepResult {
    return taken(vm, readAddr(vm));
}

/// `0x71` — `jmp Reg` → `ip ← reg`.
pub fn jmpReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const reg = vm.mmap.readByte(ip +% 1);
    const target = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    return taken(vm, target);
}

// ---------- conditional (Addr operand) ----------

/// `0x72` — `jeq Addr` → branch when `Z = 1`.
pub fn jeqAddr(vm: *VM) StepResult {
    if (vm.regs.flagSet(.zero)) return taken(vm, readAddr(vm));
    return ok;
}

/// `0x73` — `jne Addr` → branch when `Z = 0`.
pub fn jneAddr(vm: *VM) StepResult {
    if (!vm.regs.flagSet(.zero)) return taken(vm, readAddr(vm));
    return ok;
}

/// `0x74` — `jlt Addr` → signed less: `N ≠ V`.
pub fn jltAddr(vm: *VM) StepResult {
    if (vm.regs.flagSet(.negative) != vm.regs.flagSet(.overflow))
        return taken(vm, readAddr(vm));
    return ok;
}

/// `0x75` — `jle Addr` → signed less-or-equal: `Z = 1 ∨ N ≠ V`.
pub fn jleAddr(vm: *VM) StepResult {
    const z = vm.regs.flagSet(.zero);
    const lt = vm.regs.flagSet(.negative) != vm.regs.flagSet(.overflow);
    if (z or lt) return taken(vm, readAddr(vm));
    return ok;
}

/// `0x76` — `jgt Addr` → signed greater: `Z = 0 ∧ N = V`.
pub fn jgtAddr(vm: *VM) StepResult {
    const not_z = !vm.regs.flagSet(.zero);
    const ge = vm.regs.flagSet(.negative) == vm.regs.flagSet(.overflow);
    if (not_z and ge) return taken(vm, readAddr(vm));
    return ok;
}

/// `0x77` — `jge Addr` → signed greater-or-equal: `N = V`.
pub fn jgeAddr(vm: *VM) StepResult {
    if (vm.regs.flagSet(.negative) == vm.regs.flagSet(.overflow))
        return taken(vm, readAddr(vm));
    return ok;
}

/// `0x78` — `jcc Addr` → unsigned less / no carry: `C = 0`.
pub fn jccAddr(vm: *VM) StepResult {
    if (!vm.regs.flagSet(.carry)) return taken(vm, readAddr(vm));
    return ok;
}

/// `0x79` — `jcs Addr` → unsigned greater-or-equal: `C = 1`.
pub fn jcsAddr(vm: *VM) StepResult {
    if (vm.regs.flagSet(.carry)) return taken(vm, readAddr(vm));
    return ok;
}

/// `0x7A` — `jvc Addr` → `V = 0`.
pub fn jvcAddr(vm: *VM) StepResult {
    if (!vm.regs.flagSet(.overflow)) return taken(vm, readAddr(vm));
    return ok;
}

/// `0x7B` — `jvs Addr` → `V = 1`.
pub fn jvsAddr(vm: *VM) StepResult {
    if (vm.regs.flagSet(.overflow)) return taken(vm, readAddr(vm));
    return ok;
}

/// `0x7C` — `jz Addr` → alias for `jeq` (`Z = 1`).
pub fn jzAddr(vm: *VM) StepResult {
    return jeqAddr(vm);
}

/// `0x7D` — `jnz Addr` → alias for `jne` (`Z = 0`).
pub fn jnzAddr(vm: *VM) StepResult {
    return jneAddr(vm);
}

// ---------- djnz / jr ----------

/// `0x7E` — `djnz Reg, Addr` → `reg -= 1`; branch when `reg ≠ 0`.
/// Decrement is flag-neutral so the loop primitive doesn't
/// disturb a surrounding `cmp` / `tst` chain.
pub fn djnzRegAddr(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const reg = vm.mmap.readByte(ip +% 1);
    const target = vm.mmap.readWord(ip +% 2);
    const value = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    const new_value = value -% 1;
    if (!vm.regs.writeByIndex(reg, new_value)) return fault(vm, .invalid_register);
    if (new_value != 0) return taken(vm, target);
    return ok;
}

/// `0x7F` — `jr Imm8` → relative jump `ip ← (ip + 2) + signed(imm)`.
/// Offset is post-instruction (the assembler emits `target - (here + 2)`).
pub fn jrImm8(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const offset_byte = vm.mmap.readByte(ip +% 1);
    // safety: u8 → i8 preserves the bit pattern as a signed offset
    const offset_i8: i8 = @bitCast(offset_byte);
    const offset_i16: i16 = offset_i8;
    // safety: i16 → u16 for wrapping pointer arithmetic
    const offset_u16: u16 = @bitCast(offset_i16);
    return taken(vm, ip +% 2 +% offset_u16);
}
