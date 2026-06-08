// `do … end` in expression position (§4.3). The block opens a fresh
// lexical scope, runs its statements, and evaluates to its LAST
// expression (or `nil` if the last item is a statement). A trailing
// bare `do … end` is itself a value-producing block, so the walk
// descends through it, opening a scope per level. `popBlock`'s defer
// cleanup preserves `acu`, so a scalar value survives any of the
// blocks' defers; an aggregate value lands in a dest slot the defers
// don't touch.

const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const control_flow = @import("control_flow.zig");
const isa = @import("isa.zig");
const opcodes = @import("opcodes.zig");

const Emitter = codegen.Emitter;
const Reg = opcodes.Reg;

/// The result of opening a do-block's scope(s) and emitting its prefix:
/// the innermost tail value expression (or `null` when the innermost
/// block ends in a statement), how many scopes were opened, and the
/// name→slot map snapshot to restore at `emitSuffix` (so the block's
/// `let`s — incl. ones shadowing an enclosing binding — are scoped out).
pub const Prefix = struct {
    tail: ?*const ast.Expr,
    scopes: u8,
    saved_locals: std.StringHashMapUnmanaged(i8),
};

fn emitBodyPrefix(self: *Emitter, body: []const ast.Statement, scopes: *u8) error{OutOfMemory}!?*const ast.Expr {
    try control_flow.pushBlock(self);
    scopes.* += 1;
    if (body.len == 0) return null;
    for (body[0 .. body.len - 1]) |s| try self.emitStatement(s);
    return switch (body[body.len - 1]) {
        .expr_stmt => |es| es.expr,
        // A trailing `do … end` parses as a block statement; it is the
        // value-producing tail, so descend (opening its own scope).
        .block => |b| try emitBodyPrefix(self, b.body, scopes),
        else => blk: {
            try self.emitStatement(body[body.len - 1]);
            break :blk null;
        },
    };
}

/// Open the do-block scope(s) and emit the statements before the tail.
/// Pair with `emitSuffix(p.scopes)`; between them the caller emits /
/// materializes `p.tail` (still inside the innermost scope).
pub fn emitPrefix(self: *Emitter, de: ast.DoExpr) error{OutOfMemory}!Prefix {
    const saved_locals = try self.locals.clone(self.arena);
    var scopes: u8 = 0;
    const tail = try emitBodyPrefix(self, de.body, &scopes);
    return .{ .tail = tail, .scopes = scopes, .saved_locals = saved_locals };
}

/// Close the do-block scope(s), firing their defers (which preserve
/// `acu`) and restoring the name→slot map.
pub fn emitSuffix(self: *Emitter, prefix: Prefix) error{OutOfMemory}!void {
    var i: u8 = 0;
    while (i < prefix.scopes) : (i += 1) try control_flow.popBlockWithDefers(self);
    self.locals = prefix.saved_locals;
}

/// Lower a `do … end` used as a value expression whose result is a
/// scalar (or an aggregate addressed by reference) — the tail's value
/// lands in `acu`. Aggregate-literal tails are materialized by the
/// value-aggregate path (`value_struct`), which intercepts `do_expr`
/// sources and recurses through `emitPrefix` / `emitSuffix`.
pub fn emitScalar(self: *Emitter, de: ast.DoExpr) error{OutOfMemory}!void {
    const p = try emitPrefix(self, de);
    if (p.tail) |t| {
        try self.emitExpr(t);
    } else {
        try isa.movImmToReg(self, 0, Reg.acu);
    }
    try emitSuffix(self, p);
}
