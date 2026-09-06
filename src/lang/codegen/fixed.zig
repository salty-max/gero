const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const opcodes = @import("opcodes.zig");
const isa = @import("isa.zig");

const Emitter = codegen.Emitter;
const Op = opcodes.Op;
const Reg = opcodes.Reg;

/// Low half of a live `fixed`. The high half rides `Emitter.fixed_hi`.
pub const lo = Reg.acu;

/// `true` when `b` is arithmetic over two `fixed` operands, so it needs
/// the two-word lowering rather than the scalar one.
pub fn isFixedArith(self: *const Emitter, b: ast.BinaryExpr) bool {
    if (!self.isPrimitiveType(b.lhs, .fixed) or !self.isPrimitiveType(b.rhs, .fixed)) return false;
    return switch (b.op) {
        .add, .sub, .mul, .div => true,
        else => false,
    };
}

/// Lower `lhs OP rhs` where both are `fixed` (Q16.16, §3.3).
///
/// A live `fixed` occupies two registers, so the scalar stack-machine
/// pattern is widened: both halves of the right operand are parked on
/// the stack while the left is evaluated, then recovered into a scratch
/// pair. Add and subtract are a word each plus the carry; multiply and
/// divide route through runtime helpers, since a 32-bit product and a
/// 32÷32 quotient are too large to splice at every call site.
pub fn emitBinary(self: *Emitter, b: ast.BinaryExpr) error{OutOfMemory}!void {
    try emitOperands(self, b);
    switch (b.op) {
        .add => {
            try isa.addRegToReg(self, Reg.r1, lo);
            try isa.adcRegToReg(self, Reg.r2, Emitter.fixed_hi);
        },
        .sub => {
            try isa.subRegFromReg(self, Reg.r1, lo);
            try isa.sbcRegFromReg(self, Reg.r2, Emitter.fixed_hi);
        },
        .mul => try emitHelperCall(self, .fixed_mul, b.span),
        .div => try emitHelperCall(self, .fixed_div, b.span),
        // allow-strict: `isFixedArith` admits only these four operators.
        else => unreachable,
    }
}

/// Negate the two-word value in `(lo_reg, hi_reg)` in place — the
/// two's-complement `not` / `not` / `+1` / `adc 0` sequence.
fn emitNegatePair(self: *Emitter, lo_reg: u8, hi_reg: u8) !void {
    try isa.notRegOp(self, lo_reg);
    try isa.notRegOp(self, hi_reg);
    try isa.addImmToReg(self, 1, lo_reg);
    // The carry out of the low half feeds the high half; adding zero
    // with carry is how it propagates.
    try isa.adcImmToReg(self, 0, hi_reg);
}

/// Replace `(lo_reg, hi_reg)` with its magnitude, leaving `sign_reg`
/// non-zero when the value was negative. `sign_reg` is clobbered.
fn emitAbsPair(self: *Emitter, lo_reg: u8, hi_reg: u8, sign_reg: u8) !void {
    try isa.movRegToReg(self, hi_reg, sign_reg);
    try isa.shrRegImm(self, sign_reg, 15); // sign_reg = 1 when negative
    try isa.cmpRegImm(self, sign_reg, 0);
    const skip = try isa.emitJumpPlaceholder(self, Op.jeq_addr);
    try emitNegatePair(self, lo_reg, hi_reg);
    try isa.patchJumpTo(self, skip, try self.currentOffset());
}

/// Emit `__fixed_mul` — Q16.16 multiply (§3.3).
///
/// Takes `a` in `acu`/`fixed_hi` and `b` in `r1`/`r2`, and leaves the
/// product in `acu`/`fixed_hi`. The full product of two 32-bit values is
/// 64 bits; a Q16.16 result is its middle 32, so the helper forms the
/// four 16×16 partial products and keeps bits 16..47:
///
///     result = (al·bl >> 16) + (al·bh) + (ah·bl) + ((ah·bh) << 16)
///
/// Magnitudes are multiplied and the sign reapplied at the end, since
/// the middle bits of a two's-complement product are not the product of
/// the patterns.
pub fn emitMulHelper(self: *Emitter) !void {
    const saved_bank = self.current_bank;
    self.current_bank = null;
    defer self.current_bank = saved_bank;

    self.fixed_mul_addr = .{ .bank = null, .offset = self.code.items.len };

    // Sign of the result, parked before the operands lose theirs.
    try isa.movRegToReg(self, Emitter.fixed_hi, Reg.r3);
    try isa.xorRegReg(self, Reg.r3, Reg.r2); // dst, src — r3 ^= r2
    try isa.shrRegImm(self, Reg.r3, 15);
    try isa.pushReg(self, Reg.r3);

    try emitAbsPair(self, lo, Emitter.fixed_hi, Reg.r3);
    try emitAbsPair(self, Reg.r1, Reg.r2, Reg.r3);

    // Park the operand halves; `mul` writes its high half to `acu`, so
    // nothing may stay live there across a partial product.
    try isa.pushReg(self, Emitter.fixed_hi); // [ah]
    try isa.pushReg(self, lo); // [al]
    try isa.pushReg(self, Reg.r2); // [bh]
    try isa.pushReg(self, Reg.r1); // [bl]

    // Parked layout, sp pointing at the last push:
    //   [sp+0] bl   [sp+2] bh   [sp+4] al   [sp+6] ah
    const bl_at: i8 = 0;
    const bh_at: i8 = 2;
    const al_at: i8 = 4;
    const ah_at: i8 = 6;

    // acc = al·bl >> 16 — only the high half of the lowest product
    // reaches the result.
    try isa.movRegOffsetToReg(self, Reg.sp, al_at, Reg.r3);
    try isa.movRegOffsetToReg(self, Reg.sp, bl_at, Reg.r4);
    try isa.mulRegReg(self, Reg.r4, Reg.r3); // r3 = low, acu = high
    try isa.movRegToReg(self, lo, Reg.r6); // r6 = acc_lo
    try isa.movImmToReg(self, 0, Emitter.fixed_hi); // acc_hi = 0

    // acc += al·bh
    try isa.movRegOffsetToReg(self, Reg.sp, al_at, Reg.r3);
    try isa.movRegOffsetToReg(self, Reg.sp, bh_at, Reg.r4);
    try isa.mulRegReg(self, Reg.r4, Reg.r3);
    try isa.addRegToReg(self, Reg.r3, Reg.r6);
    try isa.adcRegToReg(self, lo, Emitter.fixed_hi);

    // acc += ah·bl
    try isa.movRegOffsetToReg(self, Reg.sp, ah_at, Reg.r3);
    try isa.movRegOffsetToReg(self, Reg.sp, bl_at, Reg.r4);
    try isa.mulRegReg(self, Reg.r4, Reg.r3);
    try isa.addRegToReg(self, Reg.r3, Reg.r6);
    try isa.adcRegToReg(self, lo, Emitter.fixed_hi);

    // acc_hi += low(ah·bh) — the top product only reaches bits 32..47.
    try isa.movRegOffsetToReg(self, Reg.sp, ah_at, Reg.r3);
    try isa.movRegOffsetToReg(self, Reg.sp, bh_at, Reg.r4);
    try isa.mulRegReg(self, Reg.r4, Reg.r3);
    try isa.addRegToReg(self, Reg.r3, Emitter.fixed_hi);

    try isa.addImmToReg(self, 8, Reg.sp); // drop the four parked halves
    try isa.movRegToReg(self, Reg.r6, lo); // result low

    // Reapply the sign.
    try isa.popReg(self, Reg.r3);
    try isa.cmpRegImm(self, Reg.r3, 0);
    const done = try isa.emitJumpPlaceholder(self, Op.jeq_addr);
    try emitNegatePair(self, lo, Emitter.fixed_hi);
    try isa.patchJumpTo(self, done, try self.currentOffset());

    try self.emitByte(Op.ret_op);
}

/// Call a runtime fixed helper with `a` in `acu`/`fixed_hi` and `b` in
/// `r1`/`r2`. The helper's address is not known until it is emitted, so
/// the site records a patch the same way a forward call does.
fn emitHelperCall(self: *Emitter, target: codegen.CallPatch.Target, span: ast.Span) !void {
    switch (target) {
        .fixed_mul => self.needs_fixed_mul = true,
        .fixed_div => self.needs_fixed_div = true,
        else => {},
    }
    try self.emitByte(Op.call_addr);
    const slot = try self.currentOffset();
    try self.emitU16Le(0);
    try self.call_patches.append(self.allocator, .{
        .bank = self.current_bank,
        .code_offset = slot,
        .target = target,
        .span = span,
    });
}

/// Evaluate both operands of `b` into the pairs the two-word
/// operations expect: the left in `acu`/`fixed_hi`, the right in
/// `r1`/`r2`. The right is parked on the stack while the left is
/// evaluated, since evaluating the left may use every register.
pub fn emitOperands(self: *Emitter, b: ast.BinaryExpr) error{OutOfMemory}!void {
    try self.emitExpr(b.rhs);
    try isa.pushReg(self, Emitter.fixed_hi);
    try isa.pushReg(self, lo);

    try self.emitExpr(b.lhs);
    // Popped in push order's reverse: low half first.
    try isa.popReg(self, Reg.r1); // r1 = rhs low
    try isa.popReg(self, Reg.r2); // r2 = rhs high
}

/// One restoring-division step, shared by both phases of `__fixed_div`.
/// `rem` (r3:r4) has already taken its next numerator bit; subtract the
/// divisor (r1:r2) and keep the result only when it did not borrow,
/// recording the quotient bit in bit 0 of `num`'s low half.
fn emitDivStep(self: *Emitter) !void {
    try isa.subRegFromReg(self, Reg.r1, Reg.r3);
    try isa.sbcRegFromReg(self, Reg.r2, Reg.r4);
    // C is set on borrow (ISA §2), so a borrow means rem < divisor.
    const restore = try isa.emitJumpPlaceholder(self, Op.jcs_addr);
    // No borrow — the bit belongs in the quotient. `num`'s bit 0 is
    // clear from the rotate, so adding one cannot carry.
    try isa.addImmToReg(self, 1, lo);
    const done = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
    try isa.patchJumpTo(self, restore, try self.currentOffset());
    try isa.addRegToReg(self, Reg.r1, Reg.r3);
    try isa.adcRegToReg(self, Reg.r2, Reg.r4);
    try isa.patchJumpTo(self, done, try self.currentOffset());
}

/// Emit `__fixed_div` — Q16.16 divide (§3.3).
///
/// Takes `a` in `acu`/`fixed_hi` and `b` in `r1`/`r2`, and leaves the
/// quotient in `acu`/`fixed_hi`.
///
/// The quotient of two Q16.16 values is `(a << 16) / b` — a 48-bit
/// numerator over a 32-bit divisor, which the ISA's 32÷16 `divs` cannot
/// do in one step. This is restoring division: 48 shift-and-subtract
/// steps, with each quotient bit shifted into the low end of `num` as
/// the numerator vacates it, so no separate quotient register is
/// needed. The first 32 steps feed `a`'s own bits; the last 16 feed the
/// zeros `<< 16` appended, and are a separate loop because by then
/// `num` holds quotient bits rather than numerator bits.
///
/// Roughly 48 iterations of a dozen instructions. Division is the
/// expensive operation on this machine — §5.4 tells carts to keep it
/// out of per-frame loops.
pub fn emitDivHelper(self: *Emitter) !void {
    const saved_bank = self.current_bank;
    self.current_bank = null;
    defer self.current_bank = saved_bank;

    self.fixed_div_addr = .{ .bank = null, .offset = self.code.items.len };

    // A zero divisor raises the same fault integer division does
    // (vector $03), rather than running the loop to a meaningless
    // all-ones quotient.
    try isa.movRegToReg(self, Reg.r1, Reg.r3);
    try isa.orRegReg(self, Reg.r3, Reg.r2); // dst, src — r3 |= r2
    try isa.cmpRegImm(self, Reg.r3, 0);
    const nonzero = try isa.emitJumpPlaceholder(self, Op.jne_addr);
    try self.emitByte(Op.int_imm8);
    try self.emitByte(0x03);
    try isa.patchJumpTo(self, nonzero, try self.currentOffset());

    // Result sign, parked before the operands lose theirs.
    try isa.movRegToReg(self, Emitter.fixed_hi, Reg.r3);
    try isa.xorRegReg(self, Reg.r3, Reg.r2); // dst, src — r3 ^= r2
    try isa.shrRegImm(self, Reg.r3, 15);
    try isa.pushReg(self, Reg.r3);

    try emitAbsPair(self, lo, Emitter.fixed_hi, Reg.r3);
    try emitAbsPair(self, Reg.r1, Reg.r2, Reg.r3);

    // rem = 0.
    try isa.movImmToReg(self, 0, Reg.r3);
    try isa.movImmToReg(self, 0, Reg.r4);

    // Phase 1 — 32 steps feeding `a`'s own bits into the remainder.
    try isa.movImmToReg(self, 32, Reg.r6);
    const phase1 = try self.currentOffset();
    try isa.clc(self);
    try isa.rolRegImm(self, lo, 1);
    try isa.rolRegImm(self, Emitter.fixed_hi, 1);
    try isa.rolRegImm(self, Reg.r3, 1);
    try isa.rolRegImm(self, Reg.r4, 1);
    try emitDivStep(self);
    try isa.subImmFromReg(self, 1, Reg.r6);
    const back1 = try isa.emitJumpPlaceholder(self, Op.jne_addr);
    try isa.patchJumpTo(self, back1, phase1);

    // Phase 2 — 16 steps feeding the zeros the `<< 16` appended. `num`
    // now carries quotient bits, so its high end must not reach `rem`.
    try isa.movImmToReg(self, 16, Reg.r6);
    const phase2 = try self.currentOffset();
    try isa.clc(self);
    try isa.rolRegImm(self, Reg.r3, 1);
    try isa.rolRegImm(self, Reg.r4, 1);
    try isa.clc(self);
    try isa.rolRegImm(self, lo, 1);
    try isa.rolRegImm(self, Emitter.fixed_hi, 1);
    try emitDivStep(self);
    try isa.subImmFromReg(self, 1, Reg.r6);
    const back2 = try isa.emitJumpPlaceholder(self, Op.jne_addr);
    try isa.patchJumpTo(self, back2, phase2);

    // Reapply the sign.
    try isa.popReg(self, Reg.r3);
    try isa.cmpRegImm(self, Reg.r3, 0);
    const done = try isa.emitJumpPlaceholder(self, Op.jeq_addr);
    try emitNegatePair(self, lo, Emitter.fixed_hi);
    try isa.patchJumpTo(self, done, try self.currentOffset());

    try self.emitByte(Op.ret_op);
}

/// `true` when `e` evaluates to a `fixed`, and so occupies the register
/// pair rather than `acu` alone.
pub fn isFixed(self: *const Emitter, e: *const ast.Expr) bool {
    return self.isPrimitiveType(e, .fixed);
}

/// Complete a frame-relative load of `e`: the scalar path has already
/// fetched the low word into `acu`, so fetch the high word when the
/// value is a `fixed`. A no-op for every other type, which keeps the
/// scalar path unchanged.
pub fn loadHighFromFrame(self: *Emitter, e: *const ast.Expr, ofs: i8) !void {
    if (!isFixed(self, e)) return;
    // @as: a frame slot's high half is 2 bytes past its low half; both
    // stay inside the i8 fp-offset range the frame check enforces.
    try isa.movRegOffsetToReg(self, Reg.fp, ofs +| 2, Emitter.fixed_hi);
}

/// Same for an absolute address — globals and statics.
pub fn loadHighFromAddr(self: *Emitter, e: *const ast.Expr, addr: u16) !void {
    if (!isFixed(self, e)) return;
    try isa.movAddrToReg(self, addr +% 2, Emitter.fixed_hi);
}

/// Complete a frame-relative store of `e`: the scalar path has already
/// written the low word from `acu`, so write the high word when the
/// value is a `fixed`.
pub fn storeHighToFrame(self: *Emitter, e: *const ast.Expr, ofs: i8) !void {
    if (!isFixed(self, e)) return;
    try isa.movRegToRegOffset(self, Emitter.fixed_hi, Reg.fp, ofs +| 2);
}

/// Frame-slot width for a scalar binding: a `fixed` needs both words,
/// everything else a single one. Aggregates size themselves before
/// reaching the scalar path.
pub fn scalarSlotWidth(self: *const Emitter, init: ?*const ast.Expr, ann: ?*const ast.TypeAnn) u16 {
    if (ann) |t| return self.widthOfTypeAnn(t.*);
    if (init) |e| {
        if (isFixed(self, e)) return Emitter.fixed_size;
    }
    return 2;
}

/// Negate a `fixed` in place, for unary `-`.
pub fn emitNegate(self: *Emitter) !void {
    try emitNegatePair(self, lo, Emitter.fixed_hi);
}

/// Lower a comparison between two `fixed` values, leaving flags a
/// conditional branch can read.
///
/// A two-word subtract sets `N` and `V` for the full 32-bit signed
/// difference, but `Z` only reflects the high word — so `==`, `>=`,
/// `<=` and `>` would all read a stale zero. Rather than synthesise a
/// flag state, this reduces the comparison to the sign of the
/// difference (-1, 0 or +1) and compares that against zero, which every
/// conditional then reads correctly.
pub fn emitCompare(self: *Emitter) !void {
    try isa.subRegFromReg(self, Reg.r1, lo);
    try isa.sbcRegFromReg(self, Reg.r2, Emitter.fixed_hi);

    // Capture "less than" while the subtract's flags are still live.
    try isa.movImmToReg(self, 0, Reg.r4);
    const not_less = try isa.emitJumpPlaceholder(self, Op.jge_addr);
    try isa.movImmToReg(self, 1, Reg.r4);
    try isa.patchJumpTo(self, not_less, try self.currentOffset());

    // Equal when both halves of the difference are zero.
    try isa.movRegToReg(self, lo, Reg.r3);
    try isa.orRegReg(self, Reg.r3, Emitter.fixed_hi); // dst, src — r3 |= hi
    try isa.cmpRegImm(self, Reg.r3, 0);
    const unequal = try isa.emitJumpPlaceholder(self, Op.jne_addr);
    try isa.movImmToReg(self, 0, lo);
    const done_eq = try isa.emitJumpPlaceholder(self, Op.jmp_addr);

    try isa.patchJumpTo(self, unequal, try self.currentOffset());
    try isa.cmpRegImm(self, Reg.r4, 0);
    const greater = try isa.emitJumpPlaceholder(self, Op.jeq_addr);
    try isa.movImmToReg(self, 0xFFFF, lo); // -1
    const done_lt = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
    try isa.patchJumpTo(self, greater, try self.currentOffset());
    try isa.movImmToReg(self, 1, lo);

    try isa.patchJumpTo(self, done_eq, try self.currentOffset());
    try isa.patchJumpTo(self, done_lt, try self.currentOffset());
    try isa.cmpRegImm(self, lo, 0);
}

/// `true` when `b` compares two `fixed` operands.
pub fn isFixedCompare(self: *const Emitter, b: ast.BinaryExpr) bool {
    if (!isFixed(self, b.lhs) or !isFixed(self, b.rhs)) return false;
    return switch (b.op) {
        .eq, .neq, .lt, .lte, .gt, .gte => true,
        else => false,
    };
}

/// Complete an absolute store of `e`: the scalar path has already
/// written the low word from `acu`, so write the high word when the
/// value is a `fixed`.
pub fn storeHighToAddr(self: *Emitter, e: *const ast.Expr, addr: u16) !void {
    if (!isFixed(self, e)) return;
    try isa.movRegToAddr(self, Emitter.fixed_hi, addr +% 2);
}
