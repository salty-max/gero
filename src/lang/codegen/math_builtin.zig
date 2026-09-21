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
const fixed = @import("fixed.zig");
const types = @import("../types.zig");

const Emitter = codegen.Emitter;
const Op = opcodes.Op;
const Reg = opcodes.Reg;

// `rng()` state — a Galois LFSR (taps 0xB400, polynomial x^16+x^15+x^13+
// x^4+1, maximal 65535-period). The 16-bit state lives in a reserved
// zero-page cell at the top of the page, away from `@zero_page` globals
// (which grow from 0x0000). It is zero at boot (RAM zero-inits), so the
// first call lazily seeds it — no entry-prologue setup needed.
const rng_state_addr: u16 = 0x00FE;
const rng_seed: u16 = 0xACE1;
const rng_taps: u16 = 0xB400;

/// How an operand's type drives the lowering: `u16`/`u8` need unsigned
/// comparison; `fixed` uses a signed Q16.16 register pair; everything
/// else is treated as a signed integer.
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
    if (std.mem.eql(u8, name, "sgn")) return emitSgn(self, c);
    if (std.mem.eql(u8, name, "sqrt")) return emitSqrt(self, c);
    if (std.mem.eql(u8, name, "sin")) return emitSin(self, c, 0);
    if (std.mem.eql(u8, name, "cos")) return emitSin(self, c, 0x4000);
    if (std.mem.eql(u8, name, "atan2")) return emitAtan2(self, c);
    if (std.mem.eql(u8, name, "flr")) return emitFloorCeil(self, c, .floor);
    if (std.mem.eql(u8, name, "ceil")) return emitFloorCeil(self, c, .ceil);
    if (std.mem.eql(u8, name, "rng")) return emitRng(self, c);
    try self.diagFatal(c.span, "E_CODEGEN_UNSUPPORTED", "codegen: unknown `math` builtin");
}

/// `rng() -> u16` — advance the Galois LFSR and return the new state.
/// Lazily seeds on the first call (state is 0 at boot). Deterministic:
/// identical programs produce identical sequences.
fn emitRng(self: *Emitter, c: ast.CallExpr) !void {
    _ = c; // no arguments
    _ = try isa.movAddrToReg(self, rng_state_addr, Reg.acu); // acu = state
    // Lazy seed: state 0 → seed (also keeps a 0 cell from sticking at 0).
    try isa.cmpRegImm(self, Reg.acu, 0);
    const seeded = try isa.emitJumpPlaceholder(self, Op.jne_addr);
    try isa.movImmToReg(self, rng_seed, Reg.acu);
    try isa.patchJumpTo(self, seeded, try self.currentOffset());
    // Galois step: lsb = state & 1; state >>= 1; if lsb: state ^= taps.
    try isa.movRegToReg(self, Reg.acu, Reg.r1);
    try isa.movImmToReg(self, 1, Reg.r2);
    try isa.andRegReg(self, Reg.r1, Reg.r2); // r1 = lsb
    try isa.shrRegImm(self, Reg.acu, 1); // logical >> 1
    try isa.cmpRegImm(self, Reg.r1, 0);
    const no_xor = try isa.emitJumpPlaceholder(self, Op.jeq_addr);
    try isa.movImmToReg(self, rng_taps, Reg.r2);
    try isa.xorRegReg(self, Reg.acu, Reg.r2); // state ^= taps
    try isa.patchJumpTo(self, no_xor, try self.currentOffset());
    _ = try isa.movRegToAddr(self, Reg.acu, rng_state_addr); // persist; acu is the result
}

/// `sqrt(x: fixed) -> fixed` — Q16.16 square root.
///
/// `√(raw/65536)·65536 = √raw · 256`, so the raw value is its own
/// radicand and the integer root is scaled by 256 afterwards — which
/// keeps the radicand inside 32 bits, where a 48-bit one would not fit.
/// The root is found bit-by-bit high→low, squaring each candidate
/// (16×16→32 `mul`) and keeping the bit when candidate² ≤ radicand (a
/// 32-bit unsigned compare). x ≤ 0 returns 0.
///
/// The `· 256` means the result carries 8 fractional bits rather than
/// 16. That is exact for perfect squares and within ~0.3% mid-range,
/// tightening as x grows.
fn emitSqrtFixed(self: *Emitter, c: ast.CallExpr) !void {
    try self.emitExpr(c.args[0]); // acu:fixed_hi = x_raw
    try isa.cmpRegImm(self, Emitter.fixed_hi, 0);
    const nonneg = try isa.emitJumpPlaceholder(self, Op.jge_addr);
    try isa.movImmToReg(self, 0, Reg.acu); // x < 0 → 0
    try isa.movImmToReg(self, 0, Emitter.fixed_hi);
    const done = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
    try isa.patchJumpTo(self, nonneg, try self.currentOffset());
    // The raw value is the radicand N across (r2 = high, r1 = low).
    try isa.movRegToReg(self, Reg.acu, Reg.r1);
    try isa.movRegToReg(self, Emitter.fixed_hi, Reg.r2);
    try isa.movImmToReg(self, 0, Reg.r3); // result accumulator
    try isa.movImmToReg(self, 0x8000, Reg.r4); // bit = 2^15 (root < 2^16)
    const loop_start = try self.currentOffset();
    // candidate = result | bit → r5.
    try isa.movRegToReg(self, Reg.r3, Reg.r5);
    try isa.orRegReg(self, Reg.r5, Reg.r4);
    // sq = candidate² → acu:r6 (high:low).
    try isa.movRegToReg(self, Reg.r5, Reg.r6);
    try isa.mulRegReg(self, Reg.r5, Reg.r6);
    // Compare (acu:r6) ≤ (r2:r1) unsigned.
    try isa.cmpRegReg(self, Reg.acu, Reg.r2); // sq_hi - N_hi
    const hi_ge = try isa.emitJumpPlaceholder(self, Op.jcc_addr); // sq_hi ≥ N_hi (C=0)
    const acc_lo = try isa.emitJumpPlaceholder(self, Op.jmp_addr); // sq_hi < N_hi → accept
    try isa.patchJumpTo(self, hi_ge, try self.currentOffset());
    const rej_hi = try isa.emitJumpPlaceholder(self, Op.jne_addr); // sq_hi > N_hi → reject
    try isa.cmpRegReg(self, Reg.r1, Reg.r6); // N_lo - sq_lo
    const acc_eq = try isa.emitJumpPlaceholder(self, Op.jcc_addr); // N_lo ≥ sq_lo → sq_lo ≤ N_lo → accept
    const rej_lo = try isa.emitJumpPlaceholder(self, Op.jmp_addr); // sq_lo > N_lo → reject
    // accept: result = candidate.
    const accept = try self.currentOffset();
    try isa.patchJumpTo(self, acc_lo, accept);
    try isa.patchJumpTo(self, acc_eq, accept);
    try isa.movRegToReg(self, Reg.r5, Reg.r3);
    // continue: shift to the next bit, loop while non-zero.
    const cont = try self.currentOffset();
    try isa.patchJumpTo(self, rej_hi, cont);
    try isa.patchJumpTo(self, rej_lo, cont);
    try isa.shrRegImm(self, Reg.r4, 1);
    try isa.cmpRegImm(self, Reg.r4, 0);
    const back = try isa.emitJumpPlaceholder(self, Op.jne_addr);
    try isa.patchJumpTo(self, back, loop_start);
    // Scale the integer root by 256 into the Q16.16 pair.
    try isa.movRegToReg(self, Reg.r3, Reg.acu);
    try isa.movRegToReg(self, Reg.r3, Reg.r1);
    try isa.shrRegImm(self, Reg.r1, 8); // root is non-negative
    try isa.shlRegImm(self, Reg.acu, 8);
    try isa.movRegToReg(self, Reg.r1, Emitter.fixed_hi);
    try isa.patchJumpTo(self, done, try self.currentOffset());
}

/// `sin(t: fixed) -> fixed` / `cos(t: fixed) -> fixed` — angle in
/// **turns**, Q16.16. `quarter_turn` is added first, which is the only
/// difference between the two.
///
/// A full turn is `1.0`, so the turn fraction is the low word and
/// wrapping is free — no `mod`, no range reduction, which is what
/// degrees cost. Folds `[0.5, 1)` to a negated `[0, 0.5)`, then
/// Bhaskara I over the half turn:
///   sin(πz) ≈ 16z(1-z) / (5 - 4z(1-z)),  P = z(1-z) in Q15
/// rearranged to `4P / (40960 - P)`, the form whose intermediates stay
/// inside 32 bits. Accurate to 0.17%, and exact at every quarter turn.
fn emitSin(self: *Emitter, c: ast.CallExpr, quarter_turn: u16) !void {
    try self.emitExpr(c.args[0]); // acu:fixed_hi = t_raw
    if (quarter_turn != 0) {
        // cos(t) = sin(t + ¼). Only the low word is read below, so the
        // carry into the high half is deliberately not propagated.
        try isa.movImmToReg(self, quarter_turn, Reg.r1);
        try isa.addRegToReg(self, Reg.r1, Reg.acu);
    }
    // negate = bit 15 of the fraction; x = the remaining 15 bits.
    try isa.movRegToReg(self, Reg.acu, Reg.r6);
    try isa.movImmToReg(self, 0x8000, Reg.r1);
    try isa.andRegReg(self, Reg.r6, Reg.r1); // r6 = 0 or 0x8000
    try isa.movImmToReg(self, 0x7FFF, Reg.r1);
    try isa.andRegReg(self, Reg.acu, Reg.r1); // acu = x ∈ [0, 32768)
    // prod = x(32768 - x) → acu:r2, then P = prod >> 15.
    try isa.movRegToReg(self, Reg.acu, Reg.r1); // r1 = x
    try isa.movImmToReg(self, 0x7FFF, Reg.acu);
    try isa.subRegFromAcu(self, Reg.r1);
    try isa.addImmToReg(self, 1, Reg.acu); // acu = 32768 - x, without overflowing i16
    try isa.movRegToReg(self, Reg.acu, Reg.r2);
    try isa.mulRegReg(self, Reg.r1, Reg.r2); // r2 = low, acu = high
    try isa.shlRegImm(self, Reg.acu, 1); // high << 1
    try isa.shrRegImm(self, Reg.r2, 15); // low >> 15 (logical)
    try isa.orRegReg(self, Reg.acu, Reg.r2); // acu = P ≤ 8192
    try isa.movRegToReg(self, Reg.acu, Reg.r1); // r1 = P
    // den_half = (40960 − P) >> 1 ∈ [16384, 20480]. Halved because the
    // divide is signed and 40960 is negative as an i16.
    try isa.movImmToReg(self, 40960, Reg.acu);
    try isa.subRegFromAcu(self, Reg.r1);
    try isa.shrRegImm(self, Reg.acu, 1);
    try isa.movRegToReg(self, Reg.acu, Reg.r4); // r4 = den_half
    // num32 = 32768·P: P >> 1 in the high half, P << 15 in the low.
    try isa.movRegToReg(self, Reg.r1, Reg.r2);
    try isa.shlRegImm(self, Reg.r2, 15); // r2 = low
    try isa.movRegToReg(self, Reg.r1, Reg.acu);
    try isa.shrRegImm(self, Reg.acu, 1); // acu = high
    try isa.divsRegReg(self, Reg.r4, Reg.r2); // r2 = quarter ≤ 16384
    try isa.movRegToReg(self, Reg.r2, Reg.acu);
    try isa.cmpRegImm(self, Reg.r6, 0);
    const positive = try isa.emitJumpPlaceholder(self, Op.jeq_addr);
    try isa.negReg(self, Reg.acu);
    try isa.patchJumpTo(self, positive, try self.currentOffset());
    // Widen the quarter-scale word to the Q16.16 pair.
    try isa.movRegToReg(self, Reg.acu, Reg.r1);
    try isa.asrRegImm(self, Reg.r1, 14);
    try isa.shlRegImm(self, Reg.acu, 2);
    try isa.movRegToReg(self, Reg.r1, Emitter.fixed_hi);
}

/// `atan(z)` for `z ∈ [0,1]` in **Q14** → turns in Q16.16, left in `acu`.
///
/// `atan(z) ≈ z / (1 + 0.2734375·z²)`, within 0.02% across the octant.
/// `35/128` is the constant that puts `atan(1)` on π/4; the widely
/// quoted `0.28125` misses it by 0.6%. Converting radians to turns is
/// folded into the numerator as `65536/(2π) = 10430`.
///
/// Q14 rather than Q15 because a ratio of exactly 1 is 32768, which is
/// negative as an i16 and would divide as such.
/// Expects `z` in `r3`; clobbers `r1`, `r2`, `r4`. It must not touch
/// `r5` or `r6`, which carry the signs the quadrant test still needs.
fn emitAtanOctant(self: *Emitter) !void {
    try isa.movRegToReg(self, Reg.r3, Reg.r1);
    try isa.mulRegReg(self, Reg.r3, Reg.r1); // r1 = low(z²), acu = high
    // z² ≤ 2^28, so z²>>21 is the high half >> 5 and never exceeds 128.
    try isa.shrRegImm(self, Reg.acu, 5);
    try isa.movImmToReg(self, 35, Reg.r2);
    try isa.mulRegReg(self, Reg.acu, Reg.r2); // r2 = 35·(z²>>21) ≤ 4480
    try isa.movImmToReg(self, 16384, Reg.r4);
    try isa.addRegToReg(self, Reg.r2, Reg.r4); // r4 = den ≤ 20864
    // 10430·z → acu:r2, a 32-bit dividend.
    try isa.movImmToReg(self, 10430, Reg.r2);
    try isa.mulRegReg(self, Reg.r3, Reg.r2);
    try isa.divsRegReg(self, Reg.r4, Reg.r2);
    try isa.movRegToReg(self, Reg.r2, Reg.acu); // acu = turns ≤ 8192
}

/// Divide `num << 14` by `den`, both `u16`, leaving the Q14 ratio in
/// `r3`. The shifted numerator spans 32 bits, so it is assembled as a
/// high/low pair rather than shifted in place.
fn emitRatioQ14(self: *Emitter, num: u8, den: u8) !void {
    try isa.movRegToReg(self, num, Reg.r3);
    try isa.shlRegImm(self, Reg.r3, 14); // low half
    try isa.movRegToReg(self, num, Reg.acu);
    try isa.shrRegImm(self, Reg.acu, 2); // high half
    try isa.divsRegReg(self, den, Reg.r3); // r3 = z ≤ 16384
}

/// `atan2(y: i16, x: i16) -> fixed` — the direction of `(x, y)` as
/// turns in `[0, 1)`, counter-clockwise from `+X`.
///
/// Deltas are integers because that is what a caller has: the vector
/// between two positions. No screen-space inversion — a caller whose Y
/// axis points down passes a down-positive `y` and gets the angle it
/// means, which is the only sense in which one function can be right
/// for both conventions.
fn emitAtan2(self: *Emitter, c: ast.CallExpr) !void {
    try self.emitExpr(c.args[0]); // y
    try isa.pushReg(self, Reg.acu);
    try self.emitExpr(c.args[1]); // x
    try isa.movRegToReg(self, Reg.acu, Reg.r6); // r6 = x
    try isa.popReg(self, Reg.r5); // r5 = y
    // r1 = |x|, r2 = |y|.
    try isa.movRegToReg(self, Reg.r6, Reg.r1);
    try isa.cmpRegImm(self, Reg.r1, 0);
    const x_pos = try isa.emitJumpPlaceholder(self, Op.jge_addr);
    try isa.negReg(self, Reg.r1);
    try isa.patchJumpTo(self, x_pos, try self.currentOffset());
    try isa.movRegToReg(self, Reg.r5, Reg.r2);
    try isa.cmpRegImm(self, Reg.r2, 0);
    const y_pos = try isa.emitJumpPlaceholder(self, Op.jge_addr);
    try isa.negReg(self, Reg.r2);
    try isa.patchJumpTo(self, y_pos, try self.currentOffset());
    // The zero vector has no direction; report 0 rather than dividing.
    try isa.movRegToReg(self, Reg.r1, Reg.acu);
    try isa.orRegReg(self, Reg.acu, Reg.r2);
    try isa.cmpRegImm(self, Reg.acu, 0);
    const nonzero = try isa.emitJumpPlaceholder(self, Op.jne_addr);
    try isa.movImmToReg(self, 0, Reg.r3);
    const zero_done = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
    try isa.patchJumpTo(self, nonzero, try self.currentOffset());
    // Take the octant whose ratio cannot exceed 1.
    try isa.cmpRegReg(self, Reg.r2, Reg.r1); // |y| - |x|
    const steep = try isa.emitJumpPlaceholder(self, Op.jgt_addr);
    try emitRatioQ14(self, Reg.r2, Reg.r1); // z = |y|/|x|
    try emitAtanOctant(self);
    try isa.movRegToReg(self, Reg.acu, Reg.r3); // r3 = base
    const shallow_done = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
    try isa.patchJumpTo(self, steep, try self.currentOffset());
    try emitRatioQ14(self, Reg.r1, Reg.r2); // z = |x|/|y|
    try emitAtanOctant(self);
    try isa.movRegToReg(self, Reg.acu, Reg.r3);
    try isa.movImmToReg(self, 16384, Reg.acu); // a quarter turn
    try isa.subRegFromAcu(self, Reg.r3);
    try isa.movRegToReg(self, Reg.acu, Reg.r3); // r3 = ¼ − atan(z)
    try isa.patchJumpTo(self, shallow_done, try self.currentOffset());
    try isa.patchJumpTo(self, zero_done, try self.currentOffset());
    // Quadrant, from the signs kept in r6 (x) and r5 (y).
    try isa.cmpRegImm(self, Reg.r6, 0);
    const x_neg = try isa.emitJumpPlaceholder(self, Op.jlt_addr);
    try isa.cmpRegImm(self, Reg.r5, 0);
    const q4 = try isa.emitJumpPlaceholder(self, Op.jlt_addr);
    try isa.movRegToReg(self, Reg.r3, Reg.acu); // x≥0, y≥0 → base
    const done_q1 = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
    try isa.patchJumpTo(self, q4, try self.currentOffset());
    // x≥0, y<0 → 1 − base. A full turn is 0x10000, so subtracting from
    // zero leaves exactly the low word wanted.
    try isa.movImmToReg(self, 0, Reg.acu);
    try isa.subRegFromAcu(self, Reg.r3);
    const done_q4 = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
    try isa.patchJumpTo(self, x_neg, try self.currentOffset());
    try isa.cmpRegImm(self, Reg.r5, 0);
    const q3 = try isa.emitJumpPlaceholder(self, Op.jlt_addr);
    try isa.movImmToReg(self, 32768, Reg.acu); // x<0, y≥0 → ½ − base
    try isa.subRegFromAcu(self, Reg.r3);
    const done_q2 = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
    try isa.patchJumpTo(self, q3, try self.currentOffset());
    try isa.movImmToReg(self, 32768, Reg.acu); // x<0, y<0 → ½ + base
    try isa.addRegToReg(self, Reg.r3, Reg.acu);
    const end = try self.currentOffset();
    try isa.patchJumpTo(self, done_q1, end);
    try isa.patchJumpTo(self, done_q4, end);
    try isa.patchJumpTo(self, done_q2, end);
    // Always below a full turn, so the high half is zero.
    try isa.movImmToReg(self, 0, Emitter.fixed_hi);
}

const Rounding = enum { floor, ceil };

/// `flr(x: fixed) -> i16` / `ceil(x: fixed) -> i16`.
///
/// The high half of a Q16.16 pair *is* the arithmetic shift by 16, so
/// floor is a register move — which is exactly why `as i16` is not a
/// substitute: that truncates toward zero, and the two disagree on
/// every negative value with a fraction.
fn emitFloorCeil(self: *Emitter, c: ast.CallExpr, mode: Rounding) !void {
    try self.emitExpr(c.args[0]); // acu = low, fixed_hi = high
    if (mode == .ceil) {
        try isa.cmpRegImm(self, Reg.acu, 0);
        const exact = try isa.emitJumpPlaceholder(self, Op.jeq_addr);
        try isa.addImmToReg(self, 1, Emitter.fixed_hi);
        try isa.patchJumpTo(self, exact, try self.currentOffset());
    }
    try isa.movRegToReg(self, Emitter.fixed_hi, Reg.acu);
}

/// `sgn(x) -> T` — `-1`, `0` or `1` in the operand's own type.
fn emitSgn(self: *Emitter, c: ast.CallExpr) !void {
    const kind = argKind(self, c.args[0]);
    try self.emitExpr(c.args[0]);
    if (kind == .fixed) {
        try isa.orRegReg(self, Reg.acu, Emitter.fixed_hi); // zero iff both halves are
        try isa.cmpRegImm(self, Reg.acu, 0);
        const is_zero = try isa.emitJumpPlaceholder(self, Op.jeq_addr);
        try isa.cmpRegImm(self, Emitter.fixed_hi, 0);
        const is_neg = try isa.emitJumpPlaceholder(self, Op.jlt_addr);
        try isa.movImmToReg(self, 0, Reg.acu); // +1.0
        try isa.movImmToReg(self, 1, Emitter.fixed_hi);
        const done_pos = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
        try isa.patchJumpTo(self, is_neg, try self.currentOffset());
        try isa.movImmToReg(self, 0, Reg.acu); // -1.0
        try isa.movImmToReg(self, 0xFFFF, Emitter.fixed_hi);
        const done_neg = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
        try isa.patchJumpTo(self, is_zero, try self.currentOffset());
        try isa.movImmToReg(self, 0, Reg.acu);
        try isa.movImmToReg(self, 0, Emitter.fixed_hi);
        const end = try self.currentOffset();
        try isa.patchJumpTo(self, done_pos, end);
        try isa.patchJumpTo(self, done_neg, end);
        return;
    }
    try isa.cmpRegImm(self, Reg.acu, 0);
    const zero = try isa.emitJumpPlaceholder(self, Op.jeq_addr);
    if (kind == .signed) {
        const neg = try isa.emitJumpPlaceholder(self, Op.jlt_addr);
        try isa.movImmToReg(self, 1, Reg.acu);
        const done_p = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
        try isa.patchJumpTo(self, neg, try self.currentOffset());
        try isa.movImmToReg(self, 0xFFFF, Reg.acu);
        try isa.patchJumpTo(self, done_p, try self.currentOffset());
    } else {
        try isa.movImmToReg(self, 1, Reg.acu);
    }
    try isa.patchJumpTo(self, zero, try self.currentOffset());
}

/// `sqrt(x)` — Q16.16 for `fixed`, integer otherwise.
fn emitSqrt(self: *Emitter, c: ast.CallExpr) !void {
    if (argKind(self, c.args[0]) == .fixed) return emitSqrtFixed(self, c);
    return emitSqrtInt(self, c);
}

/// Integer square root, by the same bit-by-bit method the fixed version
/// uses so both agree exactly on perfect squares. A negative signed
/// input has no root and returns 0.
fn emitSqrtInt(self: *Emitter, c: ast.CallExpr) !void {
    const kind = argKind(self, c.args[0]);
    try self.emitExpr(c.args[0]);
    if (kind == .signed) {
        try isa.cmpRegImm(self, Reg.acu, 0);
        const nonneg = try isa.emitJumpPlaceholder(self, Op.jge_addr);
        try isa.movImmToReg(self, 0, Reg.acu);
        try isa.patchJumpTo(self, nonneg, try self.currentOffset());
    }
    try isa.movRegToReg(self, Reg.acu, Reg.r1); // r1 = N
    try isa.movImmToReg(self, 0, Reg.r3); // result
    try isa.movImmToReg(self, 0x80, Reg.r4); // bit = 2^7 (root < 2^8)
    const loop_start = try self.currentOffset();
    try isa.movRegToReg(self, Reg.r3, Reg.r5);
    try isa.orRegReg(self, Reg.r5, Reg.r4); // r5 = candidate
    try isa.movRegToReg(self, Reg.r5, Reg.r6);
    try isa.mulRegReg(self, Reg.r5, Reg.r6); // r6 = candidate² (fits 16 bits)
    try isa.cmpRegReg(self, Reg.r1, Reg.r6); // N - cand²
    const reject = try isa.emitJumpPlaceholder(self, Op.jcs_addr); // borrow → cand² > N
    try isa.movRegToReg(self, Reg.r5, Reg.r3);
    try isa.patchJumpTo(self, reject, try self.currentOffset());
    try isa.shrRegImm(self, Reg.r4, 1);
    try isa.cmpRegImm(self, Reg.r4, 0);
    const back = try isa.emitJumpPlaceholder(self, Op.jne_addr);
    try isa.patchJumpTo(self, back, loop_start);
    try isa.movRegToReg(self, Reg.r3, Reg.acu);
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
    const kind = argKind(self, c.args[0]);
    if (kind == .unsigned) return;
    try isa.cmpRegImm(self, if (kind == .fixed) Emitter.fixed_hi else Reg.acu, 0);
    const skip = try isa.emitJumpPlaceholder(self, Op.jge_addr);
    if (kind == .fixed) {
        try fixed.emitNegate(self);
    } else {
        try isa.negReg(self, Reg.acu);
    }
    try isa.patchJumpTo(self, skip, try self.currentOffset());
}

const MinMax = enum { min, max };

fn emitMinMax(self: *Emitter, c: ast.CallExpr, which: MinMax) !void {
    const kind = argKind(self, c.args[0]);
    if (kind == .fixed) return emitFixedMinMax(self, c.args[0], c.args[1], which);
    try self.emitExpr(c.args[0]); // a
    try isa.pushReg(self, Reg.acu);
    try self.emitExpr(c.args[1]); // acu = b
    try isa.popReg(self, Reg.r1); // r1 = a
    switch (which) {
        .min => try minStep(self, Reg.r1, kind),
        .max => try maxStep(self, Reg.r1, kind),
    }
}

/// Select the smaller or larger of two fixed values without narrowing
/// either half to the VM's native word.
fn emitFixedMinMax(self: *Emitter, a: *const ast.Expr, b: *const ast.Expr, which: MinMax) !void {
    try self.emitExpr(a);
    try isa.pushReg(self, Emitter.fixed_hi);
    try isa.pushReg(self, Reg.acu);
    try self.emitExpr(b);
    try isa.pushReg(self, Emitter.fixed_hi);
    try isa.pushReg(self, Reg.acu);

    try fixed.loadPairAt(self, Reg.sp, 4); // lhs
    try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.r1); // rhs low
    try isa.movRegOffsetToReg(self, Reg.sp, 2, Reg.r2); // rhs high
    try fixed.emitCompare(self);
    const take_a = try isa.emitJumpPlaceholder(self, switch (which) {
        .min => Op.jlt_addr,
        .max => Op.jge_addr,
    });
    try fixed.loadPairAt(self, Reg.sp, 0); // b
    const done = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
    try isa.patchJumpTo(self, take_a, try self.currentOffset());
    try fixed.loadPairAt(self, Reg.sp, 4); // a
    try isa.patchJumpTo(self, done, try self.currentOffset());
    try isa.addImmToReg(self, 8, Reg.sp);
}

/// `clamp(x, lo, hi)` = `min(max(x, lo), hi)`. Evaluate all three, then
/// `max` against `lo` and `min` against `hi` in registers.
fn emitClamp(self: *Emitter, c: ast.CallExpr) !void {
    const kind = argKind(self, c.args[0]);
    if (kind == .fixed) return emitFixedClamp(self, c.args[0], c.args[1], c.args[2]);
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

/// Clamp a fixed value while retaining both words of all three operands.
fn emitFixedClamp(self: *Emitter, x: *const ast.Expr, lo_expr: *const ast.Expr, hi_expr: *const ast.Expr) !void {
    try self.emitExpr(x);
    try isa.pushReg(self, Emitter.fixed_hi);
    try isa.pushReg(self, Reg.acu);
    try self.emitExpr(lo_expr);
    try isa.pushReg(self, Emitter.fixed_hi);
    try isa.pushReg(self, Reg.acu);
    try self.emitExpr(hi_expr);
    try isa.pushReg(self, Emitter.fixed_hi);
    try isa.pushReg(self, Reg.acu);

    // candidate = min(x, hi), stored over the parked hi pair.
    try fixed.loadPairAt(self, Reg.sp, 8); // x
    try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.r1); // hi low
    try isa.movRegOffsetToReg(self, Reg.sp, 2, Reg.r2); // hi high
    try fixed.emitCompare(self);
    const take_x = try isa.emitJumpPlaceholder(self, Op.jle_addr);
    try fixed.loadPairAt(self, Reg.sp, 0); // hi
    const have_min = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
    try isa.patchJumpTo(self, take_x, try self.currentOffset());
    try fixed.loadPairAt(self, Reg.sp, 8); // x
    try isa.patchJumpTo(self, have_min, try self.currentOffset());
    try fixed.storePairAt(self, Reg.sp, 0, Reg.acu, Emitter.fixed_hi);

    // result = max(candidate, lo).
    try fixed.loadPairAt(self, Reg.sp, 0); // candidate
    try isa.movRegOffsetToReg(self, Reg.sp, 4, Reg.r1); // lo low
    try isa.movRegOffsetToReg(self, Reg.sp, 6, Reg.r2); // lo high
    try fixed.emitCompare(self);
    const take_candidate = try isa.emitJumpPlaceholder(self, Op.jge_addr);
    try fixed.loadPairAt(self, Reg.sp, 4); // lo
    const done = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
    try isa.patchJumpTo(self, take_candidate, try self.currentOffset());
    try fixed.loadPairAt(self, Reg.sp, 0); // candidate
    try isa.patchJumpTo(self, done, try self.currentOffset());
    try isa.addImmToReg(self, 12, Reg.sp);
}

const AddSub = enum { add, sub };

/// `wrap_add` / `wrap_sub` — plain add/sub, no overflow trap (the op
/// wraps). Subtraction needs `a` in `acu`, so it pushes `b` first.
fn emitWrapAddSub(self: *Emitter, c: ast.CallExpr, op: AddSub) !void {
    if (argKind(self, c.args[0]) == .fixed) {
        return fixed.emitBinary(self, .{
            .op = if (op == .add) .add else .sub,
            .lhs = c.args[0],
            .rhs = c.args[1],
            .span = c.span,
        });
    }
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
/// low half); Q16.16 multiplication for `fixed`. No overflow trap.
fn emitWrapMul(self: *Emitter, c: ast.CallExpr) !void {
    const kind = argKind(self, c.args[0]);
    if (kind == .fixed) {
        return fixed.emitBinary(self, .{
            .op = .mul,
            .lhs = c.args[0],
            .rhs = c.args[1],
            .span = c.span,
        });
    }
    try self.emitExpr(c.args[0]); // a
    try isa.pushReg(self, Reg.acu);
    try self.emitExpr(c.args[1]); // acu = b
    try isa.popReg(self, Reg.r1); // r1 = a
    // `mul`/`muls` land the low half in the dst reg and the high half in
    // acu, so land the product in r2 to avoid clobbering it.
    try isa.movRegToReg(self, Reg.acu, Reg.r2);
    try isa.mulRegReg(self, Reg.r1, Reg.r2); // r2 = low(a*b)
    try isa.movRegToReg(self, Reg.r2, Reg.acu);
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
