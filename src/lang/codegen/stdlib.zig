// Router for the stdlib modules whose calls lower to fixed code:
// `math`, `bank`, `test`. `mem` predates this and keeps its own
// dispatch (it has the addr-of special case). Both call forms —
// `recv.fn(args)` parsed as a method call and the field-callee shape —
// flow through `emitCall`.

const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const bank_builtin = @import("bank_builtin.zig");
const test_builtin = @import("test_builtin.zig");
const math_builtin = @import("math_builtin.zig");
const mem_builtin = @import("mem_builtin.zig");

const Emitter = codegen.Emitter;

/// `true` for the modules a qualified `recv.name(...)` routes here.
///
/// `mem` and `str` are absent on purpose: the qualified forms of
/// those are dispatched by the caller before it reaches this router.
pub fn isModule(name: []const u8) bool {
    return std.mem.eql(u8, name, "math") or
        std.mem.eql(u8, name, "bank") or
        std.mem.eql(u8, name, "test");
}

/// Lower a `recv.name(args)` stdlib call. `recv` is gated by `isModule`.
pub fn emitCall(self: *Emitter, recv: []const u8, fe: ast.FieldExpr, c: ast.CallExpr) !void {
    return emitCallName(self, recv, self.source[fe.field.start..fe.field.end], c);
}

/// `emitCall` resolved by an explicit function `name` — used when a
/// selectively-imported (and possibly renamed) stdlib function is
/// called bare (`use rng as random from math` then `random()`).
pub fn emitCallName(self: *Emitter, recv: []const u8, name: []const u8, c: ast.CallExpr) !void {
    if (std.mem.eql(u8, recv, "bank")) return bank_builtin.emitBankCall(self, name, c);
    if (std.mem.eql(u8, recv, "test")) return test_builtin.emitTestCall(self, name, c);
    // `mem` is lowered by its own emitter rather than this router,
    // and a bare member of it arrives here too.
    if (std.mem.eql(u8, recv, "mem")) return mem_builtin.emitMemCallName(self, name, c);
    return math_builtin.emitMathCall(self, name, c);
}

/// `true` for every module `emitCallName` can lower — which is what
/// a bare member of one needs, whether it got its name from a
/// selective `use` or from an ambient set.
///
/// Wider than `isModule`: `mem` has no qualified route through this
/// file but does have a bare one.
pub fn isRoutable(name: []const u8) bool {
    return isModule(name) or std.mem.eql(u8, name, "mem");
}
