const std = @import("std");
const ast = @import("../ast.zig");
const opcodes = @import("opcodes.zig");
const isa = @import("isa.zig");
const archive = @import("archive.zig");
const strings = @import("strings.zig");
const codegen_mod = @import("../codegen.zig");

const Emitter = codegen_mod.Emitter;
const Op = opcodes.Op;
const Reg = opcodes.Reg;
const Sys = opcodes.Sys;

// allow-strict: gero builtin name; the Zig keyword sense doesn't apply on this line.
const name_unreachable: []const u8 = "unreachable";
// allow-strict: literal printed when the `unreachable` builtin fires.
const msg_unreachable: []const u8 = "unreachable code reached";

/// `true` when `name` is one of the always-in-scope diverging
/// builtins (§5.3): `panic`, `unreachable`, `todo`.
pub fn isDivergeBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "panic") or
        std.mem.eql(u8, name, name_unreachable) or
        std.mem.eql(u8, name, "todo");
}

/// Lower a call to a diverging builtin. Each builtin prints its
/// diagnostic message then halts the VM via `hlt`. Caller has
/// already confirmed the name via `isDivergeBuiltin` and the
/// typechecker has validated the arg shape.
pub fn emitDivergeCall(self: *Emitter, c: ast.CallExpr, name: []const u8) !void {
    if (std.mem.eql(u8, name, "panic")) {
        if (c.args.len == 1) try emitMessage(self, c.args[0]);
        try isa.sys(self, Sys.print_newline);
        try self.emitByte(Op.hlt);
        return;
    }
    if (std.mem.eql(u8, name, name_unreachable)) {
        try emitLiteral(self, msg_unreachable);
        try isa.sys(self, Sys.print_newline);
        try self.emitByte(Op.hlt);
        return;
    }
    if (std.mem.eql(u8, name, "todo")) {
        try emitLiteral(self, if (c.args.len == 1) "TODO: " else "TODO");
        if (c.args.len == 1) try emitMessage(self, c.args[0]);
        try isa.sys(self, Sys.print_newline);
        try self.emitByte(Op.hlt);
        return;
    }
}

/// Emit a `print_str` for a literal byte run interned into the
/// string pool.
fn emitLiteral(self: *Emitter, text: []const u8) !void {
    const id = try strings.internString(self, text);
    try strings.emitMovStringAddrToReg(self, id, Reg.acu);
    try isa.sys(self, Sys.print_str);
}

/// Print a string expression. Plain string literals route through
/// the pooled-address fast path (no runtime alloc); other str
/// expressions evaluate normally and reuse the same syscall on
/// the resulting pointer.
fn emitMessage(self: *Emitter, msg: *const ast.Expr) !void {
    if (msg.* == .str_lit and msg.str_lit.parts.len == 1 and msg.str_lit.parts[0] == .lit) {
        const lit = msg.str_lit.parts[0].lit;
        const raw = self.source[lit.span.start..lit.span.end];
        const decoded = try archive.decodeStringEscapes(self.arena, raw);
        try emitLiteral(self, decoded);
        return;
    }
    try self.emitExpr(msg);
    try isa.sys(self, Sys.print_str);
}
