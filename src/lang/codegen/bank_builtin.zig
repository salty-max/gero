// Lowering for the `bank` stdlib module (§5.3): direct manipulation of
// the `mb` bank-selector register. `bank.switch_to(n)` writes it,
// `bank.current()` reads it. These are the raw primitive — unlike the
// `@bank` cross-bank call trampoline, the program owns the window after
// a manual switch (canonical use: selecting an SRAM bank for saves).

const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const opcodes = @import("opcodes.zig");
const isa = @import("isa.zig");

const Emitter = codegen.Emitter;
const Reg = opcodes.Reg;

/// Dispatch a `bank.X(args)` call. Arity is validated by the
/// typechecker; the codegen guard is defensive.
pub fn emitBankCall(self: *Emitter, name: []const u8, c: ast.CallExpr) !void {
    if (std.mem.eql(u8, name, "switch_to")) {
        if (c.args.len != 1) {
            try self.diagFatal(c.span, "E_CODEGEN_UNSUPPORTED", "codegen: `bank.switch_to` takes one argument");
            return;
        }
        try self.emitExpr(c.args[0]); // acu = bank id
        try isa.movRegToReg(self, Reg.acu, Reg.mb);
        return;
    }
    if (std.mem.eql(u8, name, "current")) {
        if (c.args.len != 0) {
            try self.diagFatal(c.span, "E_CODEGEN_UNSUPPORTED", "codegen: `bank.current` takes no arguments");
            return;
        }
        try isa.movRegToReg(self, Reg.mb, Reg.acu); // acu = current bank id
        return;
    }
    try self.diagFatal(c.span, "E_CODEGEN_UNSUPPORTED", "codegen: unknown `bank` builtin");
}
