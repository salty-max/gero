// `if … else … end` in value position (§4.4.2). The branch structure
// is the statement form's — each arm tests, runs its body, then jumps
// to a shared join — but every body ends in an expression whose value
// lands in `acu`, the way a `do … end` block's tail does.
//
// The type checker requires an `else` and one shared branch type, so
// every path through the chain leaves a value and the join needs no
// fixup.

const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const control_flow = @import("control_flow.zig");
const do_expr = @import("do_expr.zig");
const isa = @import("isa.zig");
const opcodes = @import("opcodes.zig");

const Emitter = codegen.Emitter;
const Op = opcodes.Op;
const Reg = opcodes.Reg;

/// Lower an `if` chain used as a value. Mirrors `control_flow.emitIfStmt`,
/// differing only in that each body is emitted for its value.
pub fn emitScalar(self: *Emitter, ie: ast.IfExpr) !void {
    var end_patches: std.ArrayList(usize) = .empty;
    defer end_patches.deinit(self.allocator);

    for (ie.arms) |arm| {
        const skip_body_patch = try control_flow.emitIfArmTest(self, arm);
        try do_expr.emitBodyValue(self, arm.body);
        try end_patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jmp_addr));
        const after_body = try self.currentOffset();
        try isa.patchJumpTo(self, skip_body_patch, after_body);
    }

    if (ie.else_body) |eb| {
        try do_expr.emitBodyValue(self, eb);
    } else {
        // Unreachable for a checked program; a bare `0` keeps codegen
        // total if diagnostics were suppressed.
        try isa.movImmToReg(self, 0, Reg.acu);
    }

    const end_offset = try self.currentOffset();
    for (end_patches.items) |p| try isa.patchJumpTo(self, p, end_offset);
}
