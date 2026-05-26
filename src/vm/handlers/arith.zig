const vm_mod = @import("../vm.zig");
const dispatch = @import("../dispatch.zig");
const VM = vm_mod.VM;
const StepResult = dispatch.StepResult;

const ok = StepResult.cont;

fn fault(vm: *VM, vector: dispatch.Vector) StepResult {
    return dispatch.raiseFault(vm, vector);
}

/// Output of an ALU add or sub: the 16-bit truncated result and
/// the two condition bits the operation would set.
const AluEffect = struct {
    result: u16,
    carry: bool,
    overflow: bool,
};

fn addWithCarry(a: u16, b: u16, carry_in: u1) AluEffect {
    // @as: widen u16 operands to u32 so the sum can't wrap before C-detect
    const wide: u32 = @as(u32, a) + @as(u32, b) + carry_in;
    // @as: truncate the wide sum back to u16 (the high bit is carry)
    const result: u16 = @as(u16, @truncate(wide));
    const same_sign = ((a ^ b) & 0x8000) == 0;
    const result_flipped = ((a ^ result) & 0x8000) != 0;
    return .{
        .result = result,
        .carry = wide > 0xFFFF,
        .overflow = same_sign and result_flipped,
    };
}

fn subWithBorrow(a: u16, b: u16, borrow_in: u1) AluEffect {
    // @as: widen u16 operands to u32 so the wrapping sub keeps the full result
    const wide: u32 = @as(u32, a) -% @as(u32, b) -% borrow_in;
    // @as: truncate the wide difference back to u16
    const result: u16 = @as(u16, @truncate(wide));
    const diff_sign = ((a ^ b) & 0x8000) != 0;
    const result_matches_b = ((b ^ result) & 0x8000) == 0;
    return .{
        .result = result,
        // @as: widen both operands to u32 for the borrow comparison
        .carry = @as(u32, a) < @as(u32, b) +% borrow_in,
        .overflow = diff_sign and result_matches_b,
    };
}

fn setZN(vm: *VM, result: u16) void {
    vm.regs.setFlag(.zero, result == 0);
    vm.regs.setFlag(.negative, (result & 0x8000) != 0);
}

fn writeAddSub(vm: *VM, dst: u8, eff: AluEffect) StepResult {
    if (!vm.regs.writeByIndex(dst, eff.result)) return fault(vm, .invalid_register);
    setZN(vm, eff.result);
    vm.regs.setFlag(.carry, eff.carry);
    vm.regs.setFlag(.overflow, eff.overflow);
    return ok;
}

// ---------- add ----------

/// `0x40` — `add Imm16, Reg` → `reg ← reg + imm`.
pub fn addImm16Reg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const imm = vm.readWord(ip +% 1);
    const reg = vm.readByte(ip +% 3);
    const a = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    return writeAddSub(vm, reg, addWithCarry(a, imm, 0));
}

/// `0x41` — `add Reg, Reg` → `dst ← dst + src` (asm: `add src, dst`).
pub fn addRegReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const src = vm.readByte(ip +% 1);
    const dst = vm.readByte(ip +% 2);
    const a = vm.regs.readByIndex(dst) orelse return fault(vm, .invalid_register);
    const b = vm.regs.readByIndex(src) orelse return fault(vm, .invalid_register);
    return writeAddSub(vm, dst, addWithCarry(a, b, 0));
}

/// `0x42` — `add Reg` → `acu ← acu + reg` (implicit-acu short form).
pub fn addRegAcu(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const src = vm.readByte(ip +% 1);
    const b = vm.regs.readByIndex(src) orelse return fault(vm, .invalid_register);
    const a = vm.regs.read(.acu);
    const eff = addWithCarry(a, b, 0);
    vm.regs.write(.acu, eff.result);
    setZN(vm, eff.result);
    vm.regs.setFlag(.carry, eff.carry);
    vm.regs.setFlag(.overflow, eff.overflow);
    return ok;
}

// ---------- sub ----------

/// `0x43` — `sub Imm16, Reg` → `reg ← reg - imm`.
pub fn subImm16Reg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const imm = vm.readWord(ip +% 1);
    const reg = vm.readByte(ip +% 3);
    const a = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    return writeAddSub(vm, reg, subWithBorrow(a, imm, 0));
}

/// `0x44` — `sub Reg, Reg` → `dst ← dst - src` (asm: `sub src, dst`).
pub fn subRegReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const src = vm.readByte(ip +% 1);
    const dst = vm.readByte(ip +% 2);
    const a = vm.regs.readByIndex(dst) orelse return fault(vm, .invalid_register);
    const b = vm.regs.readByIndex(src) orelse return fault(vm, .invalid_register);
    return writeAddSub(vm, dst, subWithBorrow(a, b, 0));
}

/// `0x45` — `sub Reg` → `acu ← acu - reg`.
pub fn subRegAcu(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const src = vm.readByte(ip +% 1);
    const b = vm.regs.readByIndex(src) orelse return fault(vm, .invalid_register);
    const a = vm.regs.read(.acu);
    const eff = subWithBorrow(a, b, 0);
    vm.regs.write(.acu, eff.result);
    setZN(vm, eff.result);
    vm.regs.setFlag(.carry, eff.carry);
    vm.regs.setFlag(.overflow, eff.overflow);
    return ok;
}

// ---------- mul ----------

fn doMul(vm: *VM, dst: u8, a: u16, b: u16) StepResult {
    // @as: widen u16 operands to u32 to retain the full 32-bit product
    const wide: u32 = @as(u32, a) * @as(u32, b);
    // @as: split the 32-bit product into two 16-bit halves
    const low: u16 = @as(u16, @truncate(wide));
    // @as: high half carries the overflow bits
    const high: u16 = @as(u16, @truncate(wide >> 16));
    if (!vm.regs.writeByIndex(dst, low)) return fault(vm, .invalid_register);
    vm.regs.write(.acu, high);
    vm.regs.setFlag(.zero, wide == 0);
    vm.regs.setFlag(.negative, (high & 0x8000) != 0);
    // Carry + overflow signal that the product didn't fit in 16
    // bits — the high half is the "extra" portion.
    vm.regs.setFlag(.carry, high != 0);
    vm.regs.setFlag(.overflow, high != 0);
    return ok;
}

/// `0x46` — `mul Imm16, Reg` → `acu:reg ← reg × imm`.
pub fn mulImm16Reg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const imm = vm.readWord(ip +% 1);
    const reg = vm.readByte(ip +% 3);
    const a = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    return doMul(vm, reg, a, imm);
}

/// `0x47` — `mul Reg, Reg` → `acu:dst ← dst × src` (asm: `mul src, dst`).
pub fn mulRegReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const src = vm.readByte(ip +% 1);
    const dst = vm.readByte(ip +% 2);
    const a = vm.regs.readByIndex(dst) orelse return fault(vm, .invalid_register);
    const b = vm.regs.readByIndex(src) orelse return fault(vm, .invalid_register);
    return doMul(vm, dst, a, b);
}

/// Signed-multiply helper. Reinterprets both operands as `i16`,
/// computes the full 32-bit signed product, stores the low half in
/// `dst` and the high half in `acu`. Sets `V` (and `C`) when the
/// signed result doesn't fit in `i16` — i.e., the high half isn't
/// the sign-extension of the low half. This is the lang's signed-
/// overflow detector for `*`; `mul` (unsigned) can't be reused
/// because its V flag is `high != 0`, which false-positives on
/// legitimate signed products like `(-1) * 5 = -5`.
fn doMuls(vm: *VM, dst: u8, a: u16, b: u16) StepResult {
    // safety: reinterpret u16 → i16 (same bit pattern, signed view).
    const sa_i16: i16 = @bitCast(a);
    // safety: same bit-pattern reinterpret for b.
    const sb_i16: i16 = @bitCast(b);
    // @as: widen i16 → i32 so the full 32-bit signed product fits.
    const sa: i32 = @as(i32, sa_i16);
    // @as: widen the second operand the same way.
    const sb: i32 = @as(i32, sb_i16);
    const wide: i32 = sa * sb;
    // @as: truncate the 32-bit product's low 16 bits (signed).
    const low_signed: i16 = @as(i16, @truncate(wide));
    // safety: signed → unsigned bit reinterpret for the reg write.
    const low: u16 = @bitCast(low_signed);
    // @as: truncate the 32-bit product's high 16 bits (signed).
    const high_signed: i16 = @as(i16, @truncate(wide >> 16));
    // safety: signed → unsigned bit reinterpret for the reg write.
    const high: u16 = @bitCast(high_signed);
    if (!vm.regs.writeByIndex(dst, low)) return fault(vm, .invalid_register);
    vm.regs.write(.acu, high);
    vm.regs.setFlag(.zero, wide == 0);
    vm.regs.setFlag(.negative, (low & 0x8000) != 0);
    // Signed overflow: the result fits in i16 iff the high half is
    // the sign-extension of the low half (all 0s when low ≥ 0, all
    // 1s when low < 0). Mirror that in C for symmetry with `mul`.
    const fits = wide >= -32768 and wide <= 32767;
    vm.regs.setFlag(.overflow, !fits);
    vm.regs.setFlag(.carry, !fits);
    return ok;
}

/// `0x54` — `muls Imm16, Reg` → signed mul, `acu:reg ← reg ×s imm`.
/// Same shape as `mul` but the operands and product are interpreted
/// as `i16` → `i32`. `V` is set when the signed result overflows
/// `i16` (used by the lang's debug overflow trap on `*`).
pub fn mulsImm16Reg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const imm = vm.readWord(ip +% 1);
    const reg = vm.readByte(ip +% 3);
    const a = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    return doMuls(vm, reg, a, imm);
}

/// `0x55` — `muls Reg, Reg` → signed mul (asm: `muls src, dst`).
pub fn mulsRegReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const src = vm.readByte(ip +% 1);
    const dst = vm.readByte(ip +% 2);
    const a = vm.regs.readByIndex(dst) orelse return fault(vm, .invalid_register);
    const b = vm.regs.readByIndex(src) orelse return fault(vm, .invalid_register);
    return doMuls(vm, dst, a, b);
}

// ---------- inc / dec / neg ----------

/// `0x48` — `inc Reg` → `reg ← reg + 1`. Sets `Z`/`N`/`V`,
/// leaves `C` intact so the op composes with `adc` sequences.
pub fn incReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const reg = vm.readByte(ip +% 1);
    const a = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    const eff = addWithCarry(a, 1, 0);
    if (!vm.regs.writeByIndex(reg, eff.result)) return fault(vm, .invalid_register);
    setZN(vm, eff.result);
    vm.regs.setFlag(.overflow, eff.overflow);
    return ok;
}

/// `0x49` — `dec Reg` → `reg ← reg - 1`. Same flag policy as `inc`.
pub fn decReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const reg = vm.readByte(ip +% 1);
    const a = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    const eff = subWithBorrow(a, 1, 0);
    if (!vm.regs.writeByIndex(reg, eff.result)) return fault(vm, .invalid_register);
    setZN(vm, eff.result);
    vm.regs.setFlag(.overflow, eff.overflow);
    return ok;
}

/// `0x4A` — `neg Reg` → `reg ← -reg` (twos-complement). Sets
/// every ALU flag.
pub fn negReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const reg = vm.readByte(ip +% 1);
    const a = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    return writeAddSub(vm, reg, subWithBorrow(0, a, 0));
}

// ---------- div / divs ----------

fn doDiv(vm: *VM, dst: u8, dividend: u32, divisor: u32) StepResult {
    if (divisor == 0) return fault(vm, .div_by_zero);
    const quotient = dividend / divisor;
    if (quotient > 0xFFFF) return fault(vm, .arith_overflow);
    const remainder = dividend % divisor;
    // @as: truncate from u32 — guarded by the overflow check above
    const q16: u16 = @as(u16, @truncate(quotient));
    // @as: remainder of a u16 divisor always fits in u16
    const r16: u16 = @as(u16, @truncate(remainder));
    if (!vm.regs.writeByIndex(dst, q16)) return fault(vm, .invalid_register);
    vm.regs.write(.acu, r16);
    setZN(vm, q16);
    vm.regs.setFlag(.carry, false);
    vm.regs.setFlag(.overflow, false);
    return ok;
}

fn doDivs(vm: *VM, dst: u8, dividend: i32, divisor: i32) StepResult {
    if (divisor == 0) return fault(vm, .div_by_zero);
    // i32 MIN / -1 would trap in @divTrunc — handle as overflow
    // before reaching the builtin.
    if (divisor == -1 and dividend == -0x80000000) {
        return fault(vm, .arith_overflow);
    }
    const quotient = @divTrunc(dividend, divisor);
    if (quotient < -0x8000 or quotient > 0x7FFF) return fault(vm, .arith_overflow);
    const remainder = @rem(dividend, divisor);
    const q_i16: i16 = @intCast(quotient);
    // safety: i16 → u16 preserves the twos-complement bit pattern
    const q16: u16 = @bitCast(q_i16);
    const r_i16: i16 = @intCast(remainder);
    // safety: same bit-pattern preservation as the quotient
    const r16: u16 = @bitCast(r_i16);
    if (!vm.regs.writeByIndex(dst, q16)) return fault(vm, .invalid_register);
    vm.regs.write(.acu, r16);
    setZN(vm, q16);
    vm.regs.setFlag(.carry, false);
    vm.regs.setFlag(.overflow, false);
    return ok;
}

fn dividend32(vm: *const VM, reg_low: u16) u32 {
    const high: u32 = vm.regs.read(.acu);
    const low: u32 = reg_low;
    return (high << 16) | low;
}

fn dividend32Signed(vm: *const VM, reg_low: u16) i32 {
    // safety: u32 → i32 preserves the twos-complement bit pattern
    return @bitCast(dividend32(vm, reg_low));
}

/// `0x4B` — `div Imm16, Reg` → unsigned 32÷16: `acu:reg ÷ imm`,
/// quotient in `reg`, remainder in `acu`.
pub fn divImm16Reg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const imm = vm.readWord(ip +% 1);
    const reg = vm.readByte(ip +% 3);
    const low = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    const divisor: u32 = imm;
    return doDiv(vm, reg, dividend32(vm, low), divisor);
}

/// `0x4C` — `div Reg, Reg` → unsigned 32÷16: `acu:dst ÷ src` (asm: `div src, dst`).
pub fn divRegReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const src = vm.readByte(ip +% 1);
    const dst = vm.readByte(ip +% 2);
    const low = vm.regs.readByIndex(dst) orelse return fault(vm, .invalid_register);
    const src_value = vm.regs.readByIndex(src) orelse return fault(vm, .invalid_register);
    const divisor: u32 = src_value;
    return doDiv(vm, dst, dividend32(vm, low), divisor);
}

/// `0x4D` — `divs Imm16, Reg` → signed 32÷16, same shape as `div`.
pub fn divsImm16Reg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const imm = vm.readWord(ip +% 1);
    const reg = vm.readByte(ip +% 3);
    const low = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    // safety: u16 immediate → i16 preserves the sign bit for signed division
    const divisor_i16: i16 = @bitCast(imm);
    const divisor_signed: i32 = divisor_i16;
    return doDivs(vm, reg, dividend32Signed(vm, low), divisor_signed);
}

/// `0x4E` — `divs Reg, Reg` → signed 32÷16 (asm: `divs src, dst`).
pub fn divsRegReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const src = vm.readByte(ip +% 1);
    const dst = vm.readByte(ip +% 2);
    const low = vm.regs.readByIndex(dst) orelse return fault(vm, .invalid_register);
    const divisor = vm.regs.readByIndex(src) orelse return fault(vm, .invalid_register);
    // safety: u16 → i16 preserves the sign bit
    const divisor_i16: i16 = @bitCast(divisor);
    const divisor_signed: i32 = divisor_i16;
    return doDivs(vm, dst, dividend32Signed(vm, low), divisor_signed);
}

// ---------- adc / sbc ----------

fn carryIn(vm: *const VM) u1 {
    return if (vm.regs.flagSet(.carry)) 1 else 0;
}

/// `0x64` — `adc Imm16, Reg` → `reg ← reg + imm + C`.
pub fn adcImm16Reg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const imm = vm.readWord(ip +% 1);
    const reg = vm.readByte(ip +% 3);
    const a = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    return writeAddSub(vm, reg, addWithCarry(a, imm, carryIn(vm)));
}

/// `0x65` — `adc Reg, Reg` → `dst ← dst + src + C` (asm: `adc src, dst`).
pub fn adcRegReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const src = vm.readByte(ip +% 1);
    const dst = vm.readByte(ip +% 2);
    const a = vm.regs.readByIndex(dst) orelse return fault(vm, .invalid_register);
    const b = vm.regs.readByIndex(src) orelse return fault(vm, .invalid_register);
    return writeAddSub(vm, dst, addWithCarry(a, b, carryIn(vm)));
}

/// `0x66` — `sbc Imm16, Reg` → `reg ← reg - imm - C`.
pub fn sbcImm16Reg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const imm = vm.readWord(ip +% 1);
    const reg = vm.readByte(ip +% 3);
    const a = vm.regs.readByIndex(reg) orelse return fault(vm, .invalid_register);
    return writeAddSub(vm, reg, subWithBorrow(a, imm, carryIn(vm)));
}

/// `0x67` — `sbc Reg, Reg` → `dst ← dst - src - C` (asm: `sbc src, dst`).
pub fn sbcRegReg(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const src = vm.readByte(ip +% 1);
    const dst = vm.readByte(ip +% 2);
    const a = vm.regs.readByIndex(dst) orelse return fault(vm, .invalid_register);
    const b = vm.regs.readByIndex(src) orelse return fault(vm, .invalid_register);
    return writeAddSub(vm, dst, subWithBorrow(a, b, carryIn(vm)));
}
