// Lowering for the `test` stdlib module (§5.3): `test.assert_eq(a, b)`
// and `test.assert_ne(a, b)`, used in `@test` functions. Both compare
// two register-scalar operands and trap on a failed assertion — the
// same compare / skip-jump / print shape as the `assert` builtin, with
// the skip condition picking eq vs ne, ending in `sys trap` so the
// halt is distinguishable from a clean one.

const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const opcodes = @import("opcodes.zig");
const isa = @import("isa.zig");
const strings = @import("strings.zig");

const Emitter = codegen.Emitter;
const Op = opcodes.Op;
const Reg = opcodes.Reg;
const Sys = opcodes.Sys;

/// Dispatch a `test.X(args)` call. Arity + scalar operand types are
/// validated by the typechecker; the codegen guard is defensive.
pub fn emitTestCall(self: *Emitter, name: []const u8, c: ast.CallExpr) !void {
    const skip_on_equal = std.mem.eql(u8, name, "assert_eq");
    if (!skip_on_equal and !std.mem.eql(u8, name, "assert_ne")) {
        try self.diagFatal(c.span, "E_CODEGEN_UNSUPPORTED", "codegen: unknown `test` builtin");
        return;
    }
    if (c.args.len != 2) {
        try self.diagFatal(c.span, "E_CODEGEN_UNSUPPORTED", "codegen: `test.assert_*` takes two arguments");
        return;
    }
    try self.emitExpr(c.args[0]); // acu = a
    try isa.pushReg(self, Reg.acu);
    try self.emitExpr(c.args[1]); // acu = b
    try isa.popReg(self, Reg.r1); // r1 = a
    try isa.cmpRegReg(self, Reg.r1, Reg.acu); // Z set iff a == b
    // assert_eq skips the trap when equal (Z = 1 → jeq); assert_ne skips
    // when not equal (Z = 0 → jne).
    const skip = try isa.emitJumpPlaceholder(self, if (skip_on_equal) Op.jeq_addr else Op.jne_addr);
    // Trap: report + halt. The message is fixed (the helpers take no
    // message arg); the host sees it before the VM stops.
    const id = try strings.internString(self, "test assertion failed\n");
    try strings.emitMovStringAddrToReg(self, id, Reg.acu);
    try isa.sys(self, Sys.print_str);
    try isa.sys(self, Sys.trap);
    const skip_target = try self.currentOffset();
    try isa.patchJumpTo(self, skip, skip_target);
}
