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
    try self.diagFatal(c.span, "E_CODEGEN_UNSUPPORTED", "codegen: unknown `math` builtin");
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
