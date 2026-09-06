const std = @import("std");
const codegen = @import("../codegen.zig");
const opcodes = @import("opcodes.zig");

const Emitter = codegen.Emitter;
const Op = opcodes.Op;

/// `mov imm16, reg` (0x10) — `reg ← imm`.
pub fn movImmToReg(self: *Emitter, imm: u16, reg: u8) !void {
    try self.emitByte(Op.mov_imm16_reg);
    try self.emitU16Le(imm);
    try self.emitByte(reg);
}

/// `mov src, dst` (0x11) — `dst ← src`.
pub fn movRegToReg(self: *Emitter, src: u8, dst: u8) !void {
    try self.emitByte(Op.mov_reg_reg);
    try self.emitByte(src);
    try self.emitByte(dst);
}

/// `mov [base + ofs], dst` (0x1C) — load fp-relative into reg.
pub fn movRegOffsetToReg(self: *Emitter, base: u8, ofs: i8, dst: u8) !void {
    try self.emitByte(Op.mov_reg_offset_reg);
    try self.emitByte(base);
    // safety: i8 → u8 bit pattern; reg_offset is signed byte per ISA §5.1.
    try self.emitByte(@bitCast(ofs));
    try self.emitByte(dst);
}

/// `mov src, [base + ofs]` (0x1D) — store reg to fp-relative.
pub fn movRegToRegOffset(self: *Emitter, src: u8, base: u8, ofs: i8) !void {
    try self.emitByte(Op.mov_reg_reg_offset);
    try self.emitByte(src);
    try self.emitByte(base);
    // safety: i8 → u8 bit pattern; reg_offset is signed byte per ISA §5.1.
    try self.emitByte(@bitCast(ofs));
}

/// `mov [addr], reg` (0x13) — load 16-bit word from addr.
pub fn movAddrToReg(self: *Emitter, addr: u16, dst: u8) !void {
    try self.emitByte(Op.mov_addr_to_reg);
    try self.emitU16Le(addr);
    try self.emitByte(dst);
}

/// `mov src, [addr]` (0x12) — store 16-bit word to addr.
pub fn movRegToAddr(self: *Emitter, src: u8, addr: u16) !void {
    try self.emitByte(Op.mov_reg_to_addr);
    try self.emitByte(src);
    try self.emitU16Le(addr);
}

/// `mov imm16, [addr]` (0x14) — store a 16-bit immediate to addr.
pub fn movImmToAddr(self: *Emitter, imm: u16, addr: u16) !void {
    try self.emitByte(Op.mov_imm16_addr);
    try self.emitU16Le(imm);
    try self.emitU16Le(addr);
}

/// `sei` (0xB3) — set the interrupt-disable flag (block IRQs).
pub fn sei(self: *Emitter) !void {
    try self.emitByte(Op.sei_op);
}

/// `mov [zp], reg` (0x1A) — load 16-bit word from zp slot.
pub fn movZpToReg(self: *Emitter, zp: u8, dst: u8) !void {
    try self.emitByte(Op.mov_zp_to_reg);
    try self.emitByte(zp);
    try self.emitByte(dst);
}

/// `mov src, [zp]` (0x19) — store 16-bit word to zp slot.
pub fn movRegToZp(self: *Emitter, src: u8, zp: u8) !void {
    try self.emitByte(Op.mov_reg_to_zp);
    try self.emitByte(src);
    try self.emitByte(zp);
}

/// `mov8 [addr], reg` (0x22) — load 1-byte from addr (zero-
/// extend into the 16-bit dst).
pub fn mov8AddrToReg(self: *Emitter, addr: u16, dst: u8) !void {
    try self.emitByte(Op.mov8_addr_to_reg);
    try self.emitU16Le(addr);
    try self.emitByte(dst);
}

/// `mov8 [zp], reg` (0x29) — load 1-byte from zp slot.
pub fn mov8ZpToReg(self: *Emitter, zp: u8, dst: u8) !void {
    try self.emitByte(Op.mov8_zp_to_reg);
    try self.emitByte(zp);
    try self.emitByte(dst);
}

/// `movl reg, [addr]` (0x27) — store reg's low byte to addr.
/// Used for 1-byte global stores so neighboring bytes stay
/// untouched (critical for MMIO).
pub fn movlRegToAddr(self: *Emitter, src: u8, addr: u16) !void {
    try self.emitByte(Op.movl_reg_to_addr);
    try self.emitByte(src);
    try self.emitU16Le(addr);
}

/// `movl reg, [zp]` (0x2B) — store reg's low byte to zp slot.
pub fn movlRegToZp(self: *Emitter, src: u8, zp: u8) !void {
    try self.emitByte(Op.movl_reg_to_zp);
    try self.emitByte(src);
    try self.emitByte(zp);
}

/// `push imm16` (0x30) — push a 16-bit immediate.
pub fn pushImm16(self: *Emitter, imm: u16) !void {
    try self.emitByte(Op.push_imm16);
    try self.emitU16Le(imm);
}

/// `push reg` (0x31).
pub fn pushReg(self: *Emitter, reg: u8) !void {
    try self.emitByte(Op.push_reg);
    try self.emitByte(reg);
}

/// `pop reg` (0x32).
pub fn popReg(self: *Emitter, reg: u8) !void {
    try self.emitByte(Op.pop_reg);
    try self.emitByte(reg);
}

/// `add imm16, reg` (0x40) — `reg ← reg + imm`.
pub fn addImmToReg(self: *Emitter, imm: u16, reg: u8) !void {
    try self.emitByte(Op.add_imm16_reg);
    try self.emitU16Le(imm);
    try self.emitByte(reg);
}

/// `sub imm16, reg` (0x43) — `reg ← reg - imm`.
pub fn subImmFromReg(self: *Emitter, imm: u16, reg: u8) !void {
    try self.emitByte(Op.sub_imm16_reg);
    try self.emitU16Le(imm);
    try self.emitByte(reg);
}

/// `add reg` (0x42) — `acu ← acu + reg`.
pub fn addRegToAcu(self: *Emitter, reg: u8) !void {
    try self.emitByte(Op.add_reg_acu);
    try self.emitByte(reg);
}

/// `add src, dst` (0x41) — `dst ← dst + src`. Sets the carry the
/// matching `adc` consumes.
pub fn addRegToReg(self: *Emitter, src: u8, dst: u8) !void {
    try self.emitByte(Op.add_reg_reg);
    try self.emitByte(src);
    try self.emitByte(dst);
}

/// `sub src, dst` (0x44) — `dst ← dst - src`. Sets the borrow the
/// matching `sbc` consumes.
pub fn subRegFromReg(self: *Emitter, src: u8, dst: u8) !void {
    try self.emitByte(Op.sub_reg_reg);
    try self.emitByte(src);
    try self.emitByte(dst);
}

/// `clc` (0xB0) — clear carry. Precedes a `rol` chain so the first
/// rotate shifts a zero into bit 0.
pub fn clc(self: *Emitter) !void {
    try self.emitByte(Op.clc_op);
}

/// `rol reg, imm8` (0x76) — rotate left through carry: the bit shifted
/// out becomes C, and the old C becomes bit 0. Chaining one per word
/// shifts a multi-word value left.
pub fn rolRegImm(self: *Emitter, reg: u8, imm: u8) !void {
    try self.emitByte(Op.rol_reg_imm);
    try self.emitByte(reg);
    try self.emitByte(imm);
}

/// `adc imm16, reg` (0x50) — `reg ← reg + imm + C`. Adding zero with
/// carry is how a borrow propagates into a high half.
pub fn adcImmToReg(self: *Emitter, imm: u16, reg: u8) !void {
    try self.emitByte(Op.adc_imm16_reg);
    try self.emitU16Le(imm);
    try self.emitByte(reg);
}

/// `adc src, dst` (0x51) — `dst ← dst + src + C`. The high half of a
/// two-word add; pair it with `addRegToReg` on the low half.
pub fn adcRegToReg(self: *Emitter, src: u8, dst: u8) !void {
    try self.emitByte(Op.adc_reg_reg);
    try self.emitByte(src);
    try self.emitByte(dst);
}

/// `sbc src, dst` (0x53) — `dst ← dst - src - C`. The high half of a
/// two-word subtract; pair it with `subRegFromReg` on the low half.
pub fn sbcRegFromReg(self: *Emitter, src: u8, dst: u8) !void {
    try self.emitByte(Op.sbc_reg_reg);
    try self.emitByte(src);
    try self.emitByte(dst);
}

/// `bcpy dst, src, len` (0x2C) — copy `len` (register) bytes from `[src]`
/// to `[dst]`. All three operands are registers holding addresses / count.
pub fn bcpy(self: *Emitter, dst: u8, src: u8, len: u8) !void {
    try self.emitByte(Op.bcpy);
    try self.emitByte(dst);
    try self.emitByte(src);
    try self.emitByte(len);
}

/// `sub reg` (0x45) — `acu ← acu - reg`.
pub fn subRegFromAcu(self: *Emitter, reg: u8) !void {
    try self.emitByte(Op.sub_reg_acu);
    try self.emitByte(reg);
}

/// `mul src, dst` (0x47) — `dst ← dst * src` (unsigned 32-bit
/// product; V/C set when `high != 0`).
pub fn mulRegReg(self: *Emitter, src: u8, dst: u8) !void {
    try self.emitByte(Op.mul_reg_reg);
    try self.emitByte(src);
    try self.emitByte(dst);
}

/// `muls src, dst` (0x55) — signed `dst ← dst * src`. V/C set
/// when the signed result overflows `i16` — the lang's debug
/// overflow trap on `*` branches on V without false positives
/// that the unsigned `mul`'s V flag would produce on legitimate
/// negative operands.
pub fn mulsRegReg(self: *Emitter, src: u8, dst: u8) !void {
    try self.emitByte(Op.muls_reg_reg);
    try self.emitByte(src);
    try self.emitByte(dst);
}

/// `divs src, dst` (0x4E) — signed `dst ← dst / src`.
pub fn divsRegReg(self: *Emitter, src: u8, dst: u8) !void {
    try self.emitByte(Op.divs_reg_reg);
    try self.emitByte(src);
    try self.emitByte(dst);
}

/// `neg reg` (0x4A) — `reg ← -reg` (two's complement).
pub fn negReg(self: *Emitter, reg: u8) !void {
    try self.emitByte(Op.neg_reg);
    try self.emitByte(reg);
}

/// `cmp reg, imm16` (0x80) — flags ← reg - imm. Result discarded.
pub fn cmpRegImm(self: *Emitter, reg: u8, imm: u16) !void {
    try self.emitByte(Op.cmp_reg_imm16);
    try self.emitByte(reg);
    try self.emitU16Le(imm);
}

/// `cmp dst, src` (0x81) — flags ← dst - src.
pub fn cmpRegReg(self: *Emitter, dst: u8, src: u8) !void {
    try self.emitByte(Op.cmp_reg_reg);
    try self.emitByte(dst);
    try self.emitByte(src);
}

/// `and src, dst` (0x61) — `dst ← dst & src`. Source-first byte
/// per `bitwise.andRegReg` decode.
pub fn andRegReg(self: *Emitter, dst: u8, src: u8) !void {
    try self.emitByte(Op.and_reg_reg);
    try self.emitByte(src);
    try self.emitByte(dst);
}

/// `or src, dst` (0x63).
pub fn orRegReg(self: *Emitter, dst: u8, src: u8) !void {
    try self.emitByte(Op.or_reg_reg);
    try self.emitByte(src);
    try self.emitByte(dst);
}

/// `xor src, dst` (0x65).
pub fn xorRegReg(self: *Emitter, dst: u8, src: u8) !void {
    try self.emitByte(Op.xor_reg_reg);
    try self.emitByte(src);
    try self.emitByte(dst);
}

/// `not reg` (0x66) — `reg ← ~reg`.
pub fn notRegOp(self: *Emitter, reg: u8) !void {
    try self.emitByte(Op.not_reg);
    try self.emitByte(reg);
}

/// `shl dst, src` (0x71). Source register holds the shift count.
pub fn shlRegReg(self: *Emitter, dst: u8, src: u8) !void {
    try self.emitByte(Op.shl_reg_reg);
    try self.emitByte(dst);
    try self.emitByte(src);
}

/// `shr dst, src` (0x73).
pub fn shrRegReg(self: *Emitter, dst: u8, src: u8) !void {
    try self.emitByte(Op.shr_reg_reg);
    try self.emitByte(dst);
    try self.emitByte(src);
}

/// `shl reg, imm8` (0x70) — `reg ← reg << imm`.
pub fn shlRegImm(self: *Emitter, reg: u8, imm: u8) !void {
    try self.emitByte(Op.shl_reg_imm8);
    try self.emitByte(reg);
    try self.emitByte(imm);
}

/// `shr reg, imm8` (0x72) — `reg ← reg >> imm` (zero-fill).
pub fn shrRegImm(self: *Emitter, reg: u8, imm: u8) !void {
    try self.emitByte(Op.shr_reg_imm8);
    try self.emitByte(reg);
    try self.emitByte(imm);
}

/// `asr reg, imm8` (0x74) — `reg ← reg >>arith imm` (sign-fill).
pub fn asrRegImm(self: *Emitter, reg: u8, imm: u8) !void {
    try self.emitByte(Op.asr_reg_imm8);
    try self.emitByte(reg);
    try self.emitByte(imm);
}

/// Sign-extend the low byte of `reg` into its high byte: `shl 8 ; asr 8`.
/// The byte sits in `reg.lo`; shifting it into the top half and back via
/// an arithmetic shift propagates the sign bit through the high byte.
pub fn signExtendByte(self: *Emitter, reg: u8) !void {
    try shlRegImm(self, reg, 8);
    try asrRegImm(self, reg, 8);
}

/// Emit a forward jump with a placeholder address slot. Returns
/// the offset of the 2-byte slot inside the current code buffer —
/// pass it to `patchJumpTo` once the target offset is known.
pub fn emitJumpPlaceholder(self: *Emitter, op: u8) !usize {
    try self.emitByte(op);
    const slot = try self.currentOffset();
    try self.emitU16Le(0); // placeholder
    return slot;
}

/// Resolve a forward-jump patch: writes the absolute address
/// `currentBufferBase() + target_offset` into the 2-byte slot at
/// `patch_offset`. `target_offset` is a byte offset inside the
/// current code buffer.
pub fn patchJumpTo(self: *Emitter, patch_offset: usize, target_offset: usize) !void {
    // Recorded rather than written: the buffer's base is a link-step
    // quantity, so the emitted bytes stay position-independent.
    try self.relocations.append(self.allocator, .{
        .bank = self.current_bank,
        .patch_offset = patch_offset,
        .target_offset = target_offset,
    });
}

/// Emit an unconditional jump to a known target offset within
/// the current buffer. Used for loop back-edges.
pub fn emitJumpBack(self: *Emitter, target_offset: usize) !void {
    try self.emitByte(Op.jmp_addr);
    const slot = try self.currentOffset();
    try self.emitU16Le(0); // resolved at link
    try self.relocations.append(self.allocator, .{
        .bank = self.current_bank,
        .patch_offset = slot,
        .target_offset = target_offset,
    });
}

/// `jmp reg` (0x91) — indirect jump via the register's value.
/// `ip` becomes whatever the register holds.
pub fn jmpReg(self: *Emitter, reg: u8) !void {
    try self.emitByte(Op.jmp_reg);
    try self.emitByte(reg);
}

/// `sys imm8` (0xFB) — host-callback syscall, identifier in the
/// immediate operand byte.
pub fn sys(self: *Emitter, id: u8) !void {
    try self.emitByte(Op.sys);
    try self.emitByte(id);
}

/// `hlt` (0xFF).
pub fn hlt(self: *Emitter) !void {
    try self.emitByte(Op.hlt);
}
