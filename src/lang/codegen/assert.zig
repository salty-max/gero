/// Builtin lowering for `assert(cond, msg?)` and
/// `debug_assert(cond, msg?)` per spec §5.3. Both shapes parse as
/// regular `CallExpr { callee: ident, args: ... }` — the
/// typechecker validates the signature; the codegen dispatches on
/// the callee name before the generic call path.
///
/// `assert` always emits the check (in every build mode).
/// `debug_assert` is elided to zero bytecode when the active
/// `Options.optimize` is anything other than `.debug` — argument
/// expressions are not evaluated either, per spec.
///
/// On `false` the emitted sequence prints the optional message
/// (via `sys print_str` when the arg is a string literal) and
/// halts the VM. The host sees a clean halt with the assertion
/// message in `Host.out` — matching the spec's "diagnostic"
/// guarantee without reserving a new ISA fault vector.
const std = @import("std");
const ast = @import("../ast.zig");
const opcodes = @import("opcodes.zig");
const codegen_mod = @import("../codegen.zig");
const archive = @import("archive.zig");
const strings = @import("strings.zig");

const Emitter = codegen_mod.Emitter;
const Op = opcodes.Op;
const Reg = opcodes.Reg;
const Sys = opcodes.Sys;

/// `true` when `name` is one of the always-in-scope assert
/// builtins recognized at call sites.
pub fn isAssertBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "assert") or std.mem.eql(u8, name, "debug_assert");
}

/// Lower a call to `assert` or `debug_assert`. Caller must have
/// confirmed `c.callee` is an ident with name matching
/// `isAssertBuiltin`. Returns without emitting when the call is
/// a `debug_assert` and the build mode elides debug checks.
pub fn emitAssertCall(self: *Emitter, c: ast.CallExpr, name: []const u8) !void {
    const is_debug = std.mem.eql(u8, name, "debug_assert");
    if (is_debug and self.optimize != .debug) return;

    // `cond` evaluated into `acu`; falsy ⇒ acu == 0 ⇒ Z flag set.
    try self.emitExpr(c.args[0]);
    try self.cmpRegImm(Reg.acu, 0);
    // `jne skip` — when cond is truthy (Z = 0), jump past the
    // trap. Patched after the trap body emits.
    const skip_patch = try self.emitJumpPlaceholder(Op.jne_addr);

    // Trap body. Message printed only when provided so the host
    // gets a contextual diagnostic before the halt.
    if (c.args.len >= 2) try emitMessage(self, c.args[1]);

    try self.emitByte(Op.hlt);

    const skip_target = try self.currentOffset();
    try self.patchJumpTo(skip_patch, skip_target);
}

/// Emit the print syscall for the optional assert message. Plain
/// string literals route to the pooled-address fast path
/// (`mov str_addr, acu; sys print_str`); other str expressions
/// evaluate normally and reuse the same syscall on the resulting
/// pointer.
fn emitMessage(self: *Emitter, msg: *const ast.Expr) !void {
    if (msg.* == .str_lit and msg.str_lit.parts.len == 1 and msg.str_lit.parts[0] == .lit) {
        const lit = msg.str_lit.parts[0].lit;
        const raw = self.source[lit.span.start..lit.span.end];
        const decoded = try archive.decodeStringEscapes(self.arena, raw);
        const id = try strings.internString(self, decoded);
        try strings.emitMovStringAddrToReg(self, id, Reg.acu);
        try self.sys(Sys.print_str);
        return;
    }
    try self.emitExpr(msg);
    try self.sys(Sys.print_str);
}
