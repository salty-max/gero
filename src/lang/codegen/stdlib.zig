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

const Emitter = codegen.Emitter;

/// `true` for the modules this router lowers (`mem` excluded).
pub fn isModule(name: []const u8) bool {
    return std.mem.eql(u8, name, "math") or
        std.mem.eql(u8, name, "bank") or
        std.mem.eql(u8, name, "test");
}

/// Lower a `recv.name(args)` stdlib call. `recv` is gated by `isModule`.
pub fn emitCall(self: *Emitter, recv: []const u8, fe: ast.FieldExpr, c: ast.CallExpr) !void {
    const name = self.source[fe.field.start..fe.field.end];
    if (std.mem.eql(u8, recv, "bank")) return bank_builtin.emitBankCall(self, name, c);
    if (std.mem.eql(u8, recv, "test")) return test_builtin.emitTestCall(self, name, c);
    return math_builtin.emitMathCall(self, name, c);
}
