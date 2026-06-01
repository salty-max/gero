// Lowering for the `math` stdlib module (§5.3). These helpers are
// numeric-polymorphic — the operand type (from the typechecker) picks
// signed vs unsigned comparisons and the fixed-point multiply scaling.
// `abs`/`min`/`max`/`clamp` are cmp + branch; `wrap_*` are plain
// arithmetic with the debug overflow trap deliberately skipped (the raw
// op wraps, matching the ISA's release behavior).

const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const opcodes = @import("opcodes.zig");
const isa = @import("isa.zig");
const types = @import("../types.zig");

const Emitter = codegen.Emitter;
const Op = opcodes.Op;
const Reg = opcodes.Reg;

/// How an operand's type drives the lowering: `u16`/`u8` need unsigned
/// comparison; `fixed` needs Q8.8 multiply scaling; everything else is
/// treated as signed (`i16`/`i8`/`fixed` all compare as signed i16).
const Kind = enum { signed, unsigned, fixed };

fn argKind(self: *Emitter, e: *const ast.Expr) Kind {
    const t = self.typeOf(e) orelse return .signed;
    if (t.* != .primitive) return .signed;
    return switch (t.primitive) {
        .u16, .u8 => .unsigned,
        .fixed => .fixed,
        else => .signed,
    };
}

/// Dispatch a `math.X(args)` call. Arity + numeric operand types are
/// validated by the typechecker; the codegen guard is defensive.
pub fn emitMathCall(self: *Emitter, name: []const u8, c: ast.CallExpr) !void {
    if (std.mem.eql(u8, name, "abs")) return emitAbs(self, c);
    if (std.mem.eql(u8, name, "min")) return emitMinMax(self, c, .min);
    if (std.mem.eql(u8, name, "max")) return emitMinMax(self, c, .max);
    if (std.mem.eql(u8, name, "clamp")) return emitClamp(self, c);
    if (std.mem.eql(u8, name, "wrap_add")) return emitWrapAddSub(self, c, .add);
    if (std.mem.eql(u8, name, "wrap_sub")) return emitWrapAddSub(self, c, .sub);
    if (std.mem.eql(u8, name, "wrap_mul")) return emitWrapMul(self, c);
    if (std.mem.eql(u8, name, "sat_add")) return emitSat(self, c, .add);
    if (std.mem.eql(u8, name, "sat_sub")) return emitSat(self, c, .sub);
    if (std.mem.eql(u8, name, "sat_mul")) return emitSat(self, c, .mul);
    if (std.mem.eql(u8, name, "fixed_sin")) return emitFixedSin(self, c);
    try self.diagFatal(c.span, "E_CODEGEN_UNSUPPORTED", "codegen: unknown `math` builtin");
}

/// `fixed_sin(deg: i16) -> fixed` — sine of an angle in degrees, Q8.8.
/// Reduces `deg` mod 360 into `[0, 360)`, folds `[180, 360)` to a
/// negated `[0, 180)`, then Bhaskara I on `[0, 180]`:
///   sin(x°) ≈ 4x(180-x) / (40500 - x(180-x))
/// In Q8.8 that is `(512·prod) / ((40500-prod) >> 1)` with
/// `prod = x(180-x)` — the denominator exceeds i16 before the `>>1`, and
/// the halving keeps signed `divs` (a positive 32-bit / positive i16)
/// valid. Accurate to ~1% (a few Q8.8 LSB).
fn emitFixedSin(self: *Emitter, c: ast.CallExpr) !void {
    try self.emitExpr(c.args[0]); // acu = deg
    // deg mod 360 → remainder in acu (sign of deg). Sign-extend deg into
    // the high half for the 32/16 signed divide.
    try isa.movRegToReg(self, Reg.acu, Reg.r1); // r1 = deg (low / quotient dst)
    try isa.asrRegImm(self, Reg.acu, 15); // acu = sign extension
    try isa.movImmToReg(self, 360, Reg.r2);
    try isa.divsRegReg(self, Reg.r2, Reg.r1); // r1 = deg/360, acu = deg mod 360
    // Fold the remainder into [0, 360).
    try isa.cmpRegImm(self, Reg.acu, 0);
    const nonneg = try isa.emitJumpPlaceholder(self, Op.jge_addr);
    try isa.addImmToReg(self, 360, Reg.acu);
    try isa.patchJumpTo(self, nonneg, try self.currentOffset());
    // Fold [180, 360) to a negated [0, 180): r6 = negate flag.
    try isa.movImmToReg(self, 0, Reg.r6);
    try isa.cmpRegImm(self, Reg.acu, 180);
    const lo_half = try isa.emitJumpPlaceholder(self, Op.jlt_addr);
    try isa.movImmToReg(self, 1, Reg.r6);
    try isa.subImmFromReg(self, 180, Reg.acu);
    try isa.patchJumpTo(self, lo_half, try self.currentOffset());
    // prod = x(180-x). acu = x ∈ [0, 180).
    try isa.movRegToReg(self, Reg.acu, Reg.r1); // r1 = x
    try isa.movImmToReg(self, 180, Reg.acu);
    try isa.subRegFromAcu(self, Reg.r1); // acu = 180 - x
    try isa.movRegToReg(self, Reg.acu, Reg.r2); // r2 = 180 - x
    try isa.mulRegReg(self, Reg.r1, Reg.r2); // r2 = prod (≤ 8100, high half 0)
    try isa.movRegToReg(self, Reg.r2, Reg.r1); // r1 = prod
    // den_half = (40500 - prod) >> 1 → r4 (uses acu, so before building num).
    try isa.movImmToReg(self, 40500, Reg.acu);
    try isa.subRegFromAcu(self, Reg.r1); // acu = 40500 - prod
    try isa.shrRegImm(self, Reg.acu, 1); // (40500 - prod) / 2 ≤ 20250
    try isa.movRegToReg(self, Reg.acu, Reg.r4); // r4 = den_half
    // num32 = 512 * prod → acu:r2 (32-bit dividend).
    try isa.movImmToReg(self, 512, Reg.r2);
    try isa.mulRegReg(self, Reg.r1, Reg.r2); // r2 = low(512·prod), acu = high
    try isa.divsRegReg(self, Reg.r4, Reg.r2); // r2 = num32 / den_half = result
    try isa.movRegToReg(self, Reg.r2, Reg.acu);
    // Negate for the [180, 360) half.
    try isa.cmpRegImm(self, Reg.r6, 0);
    const positive = try isa.emitJumpPlaceholder(self, Op.jeq_addr);
    try isa.negReg(self, Reg.acu);
    try isa.patchJumpTo(self, positive, try self.currentOffset());
}

/// Emit `jge` (signed) / `jcc` (unsigned ≥, i.e. no borrow) after a
/// `cmp a, b` — jumps when `a >= b`. Returns the placeholder to patch.
fn branchGE(self: *Emitter, kind: Kind) !usize {
    const op: u8 = if (kind == .unsigned) Op.jcc_addr else Op.jge_addr;
    return isa.emitJumpPlaceholder(self, op);
}

/// `acu = min(r_a, acu)` — keep `acu` (b) when `a >= b`, else move `a`.
fn minStep(self: *Emitter, r_a: u8, kind: Kind) !void {
    try isa.cmpRegReg(self, r_a, Reg.acu);
    const keep_b = try branchGE(self, kind);
    try isa.movRegToReg(self, r_a, Reg.acu);
    try isa.patchJumpTo(self, keep_b, try self.currentOffset());
}

/// `acu = max(r_a, acu)` — move `a` when `a >= b`, else keep `acu` (b).
fn maxStep(self: *Emitter, r_a: u8, kind: Kind) !void {
    try isa.cmpRegReg(self, r_a, Reg.acu);
    const take_a = try branchGE(self, kind);
    const keep_b = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
    try isa.patchJumpTo(self, take_a, try self.currentOffset());
    try isa.movRegToReg(self, r_a, Reg.acu);
    try isa.patchJumpTo(self, keep_b, try self.currentOffset());
}

fn emitAbs(self: *Emitter, c: ast.CallExpr) !void {
    try self.emitExpr(c.args[0]); // acu = x
    // Unsigned values are already non-negative — abs is the identity.
    if (argKind(self, c.args[0]) == .unsigned) return;
    try isa.cmpRegImm(self, Reg.acu, 0);
    const skip = try isa.emitJumpPlaceholder(self, Op.jge_addr);
    try isa.negReg(self, Reg.acu);
    try isa.patchJumpTo(self, skip, try self.currentOffset());
}

const MinMax = enum { min, max };

fn emitMinMax(self: *Emitter, c: ast.CallExpr, which: MinMax) !void {
    const kind = argKind(self, c.args[0]);
    try self.emitExpr(c.args[0]); // a
    try isa.pushReg(self, Reg.acu);
    try self.emitExpr(c.args[1]); // acu = b
    try isa.popReg(self, Reg.r1); // r1 = a
    switch (which) {
        .min => try minStep(self, Reg.r1, kind),
        .max => try maxStep(self, Reg.r1, kind),
    }
}

/// `clamp(x, lo, hi)` = `min(max(x, lo), hi)`. Evaluate all three, then
/// `max` against `lo` and `min` against `hi` in registers.
fn emitClamp(self: *Emitter, c: ast.CallExpr) !void {
    const kind = argKind(self, c.args[0]);
    try self.emitExpr(c.args[0]); // x
    try isa.pushReg(self, Reg.acu);
    try self.emitExpr(c.args[1]); // lo
    try isa.pushReg(self, Reg.acu);
    try self.emitExpr(c.args[2]); // acu = hi
    try isa.popReg(self, Reg.r2); // r2 = lo
    try isa.popReg(self, Reg.r1); // r1 = x
    // acu = min(x, hi): x in r1, hi in acu.
    try minStep(self, Reg.r1, kind);
    // acu = max(lo, that): lo in r2.
    try maxStep(self, Reg.r2, kind);
}

const AddSub = enum { add, sub };

/// `wrap_add` / `wrap_sub` — plain add/sub, no overflow trap (the op
/// wraps). Subtraction needs `a` in `acu`, so it pushes `b` first.
fn emitWrapAddSub(self: *Emitter, c: ast.CallExpr, op: AddSub) !void {
    switch (op) {
        .add => {
            try self.emitExpr(c.args[0]); // a
            try isa.pushReg(self, Reg.acu);
            try self.emitExpr(c.args[1]); // acu = b
            try isa.popReg(self, Reg.r1); // r1 = a
            try isa.addRegToAcu(self, Reg.r1); // acu = b + a
        },
        .sub => {
            try self.emitExpr(c.args[1]); // b
            try isa.pushReg(self, Reg.acu);
            try self.emitExpr(c.args[0]); // acu = a
            try isa.popReg(self, Reg.r1); // r1 = b
            try isa.subRegFromAcu(self, Reg.r1); // acu = a - b
        },
    }
}

/// `wrap_mul` — low-16 product for ints (signed + unsigned share the
/// low half); Q8.8 scaling for `fixed`. No overflow trap.
fn emitWrapMul(self: *Emitter, c: ast.CallExpr) !void {
    const kind = argKind(self, c.args[0]);
    try self.emitExpr(c.args[0]); // a
    try isa.pushReg(self, Reg.acu);
    try self.emitExpr(c.args[1]); // acu = b
    try isa.popReg(self, Reg.r1); // r1 = a
    // `mul`/`muls` land the low half in the dst reg and the high half in
    // acu, so land the product in r2 to avoid clobbering it.
    try isa.movRegToReg(self, Reg.acu, Reg.r2);
    if (kind == .fixed) {
        try isa.mulsRegReg(self, Reg.r1, Reg.r2); // signed Q8.8 product
        // Q8.8 result = (acu << 8) | (r2 >> 8) — bits 8..23 of the 32-bit
        // product straddling acu:r2 (ISA §5.4.1; magnitude > 127.99 wraps).
        try isa.shrRegImm(self, Reg.r2, 8);
        try isa.shlRegImm(self, Reg.acu, 8);
        try isa.orRegReg(self, Reg.acu, Reg.r2);
    } else {
        try isa.mulRegReg(self, Reg.r1, Reg.r2); // r2 = low(a*b)
        try isa.movRegToReg(self, Reg.r2, Reg.acu);
    }
}

const SatOp = enum { add, sub, mul };

/// `sat_*` — clamp to the operand type's bounds on overflow. The
/// typechecker restricts these to i16 / u16, so `argKind` is never
/// `.fixed` here.
fn emitSat(self: *Emitter, c: ast.CallExpr, op: SatOp) !void {
    const unsigned = argKind(self, c.args[0]) == .unsigned;
    switch (op) {
        .add => try emitSatAdd(self, c, unsigned),
        .sub => try emitSatSub(self, c, unsigned),
        .mul => try emitSatMul(self, c, unsigned),
    }
}

/// Clamp `acu` to the i16 bounds picked by `sign_reg`: `>= 0` saturates
/// to `0x7FFF` (max), `< 0` to `0x8000` (min). For add/sub the sign of
/// an operand gives the overflow direction; for mul it's the product's
/// high half.
fn emitSignedClamp(self: *Emitter, sign_reg: u8) !void {
    try isa.cmpRegImm(self, sign_reg, 0);
    const pos = try isa.emitJumpPlaceholder(self, Op.jge_addr);
    try isa.movImmToReg(self, 0x8000, Reg.acu); // negative → i16 min
    const done = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
    try isa.patchJumpTo(self, pos, try self.currentOffset());
    try isa.movImmToReg(self, 0x7FFF, Reg.acu); // positive → i16 max
    try isa.patchJumpTo(self, done, try self.currentOffset());
}

fn emitSatAdd(self: *Emitter, c: ast.CallExpr, unsigned: bool) !void {
    try self.emitExpr(c.args[0]); // a
    try isa.pushReg(self, Reg.acu);
    try self.emitExpr(c.args[1]); // acu = b
    try isa.popReg(self, Reg.r1); // r1 = a
    try isa.addRegToAcu(self, Reg.r1); // acu = a + b (C on carry, V on signed overflow)
    if (unsigned) {
        const ok = try isa.emitJumpPlaceholder(self, Op.jcc_addr); // no carry → fits
        try isa.movImmToReg(self, 0xFFFF, Reg.acu);
        try isa.patchJumpTo(self, ok, try self.currentOffset());
    } else {
        const ok = try isa.emitJumpPlaceholder(self, Op.jvc_addr); // no overflow → fits
        try emitSignedClamp(self, Reg.r1); // direction = sign of a (operands agree on overflow)
        try isa.patchJumpTo(self, ok, try self.currentOffset());
    }
}

fn emitSatSub(self: *Emitter, c: ast.CallExpr, unsigned: bool) !void {
    try self.emitExpr(c.args[1]); // b
    try isa.pushReg(self, Reg.acu);
    try self.emitExpr(c.args[0]); // acu = a
    if (!unsigned) try isa.movRegToReg(self, Reg.acu, Reg.r2); // r2 = a (sign for clamp)
    try isa.popReg(self, Reg.r1); // r1 = b
    try isa.subRegFromAcu(self, Reg.r1); // acu = a - b (C on borrow, V on signed overflow)
    if (unsigned) {
        const ok = try isa.emitJumpPlaceholder(self, Op.jcc_addr); // no borrow → fits
        try isa.movImmToReg(self, 0, Reg.acu); // borrow → underflow → 0
        try isa.patchJumpTo(self, ok, try self.currentOffset());
    } else {
        const ok = try isa.emitJumpPlaceholder(self, Op.jvc_addr);
        try emitSignedClamp(self, Reg.r2); // direction = sign of a (the minuend)
        try isa.patchJumpTo(self, ok, try self.currentOffset());
    }
}

fn emitSatMul(self: *Emitter, c: ast.CallExpr, unsigned: bool) !void {
    try self.emitExpr(c.args[0]); // a
    try isa.pushReg(self, Reg.acu);
    try self.emitExpr(c.args[1]); // acu = b
    try isa.popReg(self, Reg.r1); // r1 = a
    try isa.movRegToReg(self, Reg.acu, Reg.r2); // r2 = b
    if (unsigned) {
        try isa.mulRegReg(self, Reg.r1, Reg.r2); // r2 = low(a*b), acu = high
        try isa.cmpRegImm(self, Reg.acu, 0);
        const fits = try isa.emitJumpPlaceholder(self, Op.jeq_addr); // high == 0 → fits u16
        try isa.movImmToReg(self, 0xFFFF, Reg.acu);
        const done = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
        try isa.patchJumpTo(self, fits, try self.currentOffset());
        try isa.movRegToReg(self, Reg.r2, Reg.acu); // result = low half
        try isa.patchJumpTo(self, done, try self.currentOffset());
    } else {
        try isa.mulsRegReg(self, Reg.r1, Reg.r2); // r2 = low, acu = high, V if ∉ i16
        const fits = try isa.emitJumpPlaceholder(self, Op.jvc_addr);
        try emitSignedClamp(self, Reg.acu); // direction = product sign (high-half sign bit)
        const done = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
        try isa.patchJumpTo(self, fits, try self.currentOffset());
        try isa.movRegToReg(self, Reg.r2, Reg.acu); // result = low half
        try isa.patchJumpTo(self, done, try self.currentOffset());
    }
}
