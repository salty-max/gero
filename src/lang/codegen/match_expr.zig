// `match … end` in value position (§4.8.4). The arm structure is the
// statement form's — materialize the scrutinee once, test each arm's
// pattern, jump to a shared join — but every arm body ends in an
// expression whose value lands in `acu`, the way a `do … end` block's
// tail does.
//
// The type checker requires exhaustive arms and one shared arm type, so
// every path through the chain leaves a value.
//
// The tag jump table the statement form can use (§4.8.6) is not taken
// here: it dispatches to arm bodies emitted as statements.

const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const destructure = @import("destructure.zig");
const do_expr = @import("do_expr.zig");
const isa = @import("isa.zig");
const opcodes = @import("opcodes.zig");

const Emitter = codegen.Emitter;
const Op = opcodes.Op;
const Reg = opcodes.Reg;

/// Lower a `match` used as a value. Mirrors `control_flow.emitMatchStmt`'s
/// sequential path, differing only in that each arm is emitted for its
/// tail value.
pub fn emitScalar(self: *Emitter, me: ast.MatchExpr) !void {
    const scrut_ty = self.typeOf(me.scrutinee);
    const slot = try destructure.materializeScrutinee(self, me.scrutinee, scrut_ty);

    var end_patches: std.ArrayList(usize) = .empty;
    defer end_patches.deinit(self.allocator);

    for (me.arms) |arm| {
        var skip_patches: std.ArrayList(usize) = .empty;
        defer skip_patches.deinit(self.allocator);

        // Binders land before the guard so a `when` clause reads them.
        try destructure.emitMatchPattern(self, arm.pattern, slot, scrut_ty, &skip_patches);
        if (arm.guard) |g| {
            try self.emitExpr(g);
            try isa.cmpRegImm(self, Reg.acu, 0);
            try skip_patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jeq_addr));
        }

        try do_expr.emitBodyValue(self, arm.body);
        try end_patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jmp_addr));

        const after_arm = try self.currentOffset();
        for (skip_patches.items) |p| try isa.patchJumpTo(self, p, after_arm);
    }

    const end_offset = try self.currentOffset();
    for (end_patches.items) |p| try isa.patchJumpTo(self, p, end_offset);
}
