const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const opcodes = @import("opcodes.zig");
const isa = @import("isa.zig");
const codegen_mod = @import("../codegen.zig");

const Emitter = codegen_mod.Emitter;
const Op = opcodes.Op;

/// Vector raised by the lang's debug-mode overflow trap. Matches
/// the ISA's reserved arithmetic-overflow slot — `int 5` jumps
/// through `mem[0x100A]`; default address `0` halts with a
/// host-visible fault marker.
pub const overflow_vector: u8 = 0x05;

/// Whether the operand pair an arithmetic op was emitted for is
/// signed or unsigned — drives the flag picked for the trap.
pub const Signedness = enum { signed, unsigned };

/// Classify `t` into signed / unsigned for the purpose of picking
/// the overflow flag. `null` falls back to `signed` — i16 is the
/// default integer type, so an unannotated literal is treated
/// signed. Non-integer types should not call this in the first
/// place (callers guard on `isIntegerArith`).
pub fn signednessOf(t: ?*const types.Type) Signedness {
    const ty = t orelse return .signed;
    if (ty.* != .primitive) return .signed;
    return switch (ty.primitive) {
        // `char` is byte-equivalent to `u8` (spec §2.5, §3.5.1 cast
        // table) — arithmetic on it uses unsigned-overflow semantics.
        .u8, .u16, .char => .unsigned,
        .i8, .i16 => .signed,
        else => .signed,
    };
}

/// `true` when `t` is one of the integer types the overflow check
/// applies to. Fixed-point and bool / nil are excluded — fixed
/// wraps per spec, bool / nil don't participate in arithmetic.
pub fn isIntegerArith(t: ?*const types.Type) bool {
    const ty = t orelse return false;
    if (ty.* != .primitive) return false;
    return switch (ty.primitive) {
        .i8, .u8, .i16, .u16, .char => true,
        else => false,
    };
}

/// Emit the per-op conditional trap. In release / size mode this
/// is a no-op; in debug mode it emits 5 bytes:
///
/// ```
///   jvc skip   ; (or jcc for unsigned) — Z=skip past trap on no-overflow
///   int 5      ; raise arithmetic-overflow
/// skip:
/// ```
///
/// The trap fires through the standard interrupt mechanism —
/// when vector `$05` is unset (default at boot), the VM halts
/// with a host-visible fault marker; programs can install a
/// custom handler if they want diagnostic recovery.
pub fn emitOverflowTrap(self: *Emitter, signedness: Signedness) !void {
    if (self.optimize != .debug) return;
    const skip_op: u8 = switch (signedness) {
        .signed => Op.jvc_addr,
        .unsigned => Op.jcc_addr,
    };
    const skip_patch = try isa.emitJumpPlaceholder(self, skip_op);
    try self.emitByte(Op.int_imm8);
    try self.emitByte(overflow_vector);
    const target = try self.currentOffset();
    try isa.patchJumpTo(self, skip_patch, target);
}

/// Fault vector raised by the array-bounds trap (out-of-bounds, ISA §6).
pub const bounds_vector: u8 = 0x02;

/// Emit a debug-mode bounds check for a runtime array index in `reg`
/// against the fixed length `len`: when `reg >= len` (unsigned), raise
/// vector `$02`. Elided in release / size mode (matches the overflow
/// trap). `cmp` sets `C = 0` exactly when `reg >= len`; there is no
/// jump-on-carry-set, so the in-bounds path skips via an extra `jmp`.
pub fn emitBoundsTrap(self: *Emitter, reg: u8, len: u16) !void {
    if (self.optimize != .debug) return;
    try isa.cmpRegImm(self, reg, len); // reg - len; C = 0 ⇒ reg >= len (OOB)
    const oob = try isa.emitJumpPlaceholder(self, Op.jcc_addr); // OOB → trap
    const in_bounds = try isa.emitJumpPlaceholder(self, Op.jmp_addr); // else skip
    try isa.patchJumpTo(self, oob, try self.currentOffset());
    try self.emitByte(Op.int_imm8);
    try self.emitByte(bounds_vector);
    try isa.patchJumpTo(self, in_bounds, try self.currentOffset());
}

/// Like `emitBoundsTrap` but against a runtime length in `len_reg` — used
/// for `Vec` indexing, whose length isn't known at compile time.
pub fn emitBoundsTrapReg(self: *Emitter, reg: u8, len_reg: u8) !void {
    if (self.optimize != .debug) return;
    try isa.cmpRegReg(self, reg, len_reg); // reg - len; C = 0 ⇒ reg >= len (OOB)
    const oob = try isa.emitJumpPlaceholder(self, Op.jcc_addr);
    const in_bounds = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
    try isa.patchJumpTo(self, oob, try self.currentOffset());
    try self.emitByte(Op.int_imm8);
    try self.emitByte(bounds_vector);
    try isa.patchJumpTo(self, in_bounds, try self.currentOffset());
}
