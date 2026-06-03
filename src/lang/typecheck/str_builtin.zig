// Type-checking for the compiler-known `str` instance surface (§3.2.1):
// the `s.len` property (`u16`) and the `s.at` / `s.cmp` methods. Mirrors
// `vec_builtin` — a fixed set of member signatures on a `str` value.

const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const typecheck = @import("../typecheck.zig");

const Checker = typecheck.Checker;
const WalkError = error{OutOfMemory};

/// Type of a `str` property access `s.<name>`: `len` is `u16`. An unknown
/// property is `E_TYPE_UNDEFINED_FIELD`.
pub fn checkProperty(self: *Checker, f: ast.FieldExpr) WalkError!?*const types.Type {
    const name = self.lexeme(f.field);
    if (std.mem.eql(u8, name, "len")) return try self.primitive(.u16);
    const msg = try std.fmt.allocPrint(self.arena, "`str` has no property `{s}`", .{name});
    try self.emitSpan("E_TYPE_UNDEFINED_FIELD", f.field, msg);
    return null;
}

/// Type-check a `str` instance method `s.<method>(args)`: `at(i: u16) ->
/// u8`, `cmp(other: str) -> i16`. Returns the method's result type.
pub fn checkMethod(self: *Checker, m: ast.MethodCallExpr) WalkError!?*const types.Type {
    const method = self.lexeme(m.method);
    if (std.mem.eql(u8, method, "at")) {
        if (try expectArity(self, m, 1)) return null;
        _ = try self.inferExpr(m.args[0], try self.primitive(.u16));
        return try self.primitive(.u8);
    }
    if (std.mem.eql(u8, method, "cmp")) {
        if (try expectArity(self, m, 1)) return null;
        _ = try self.inferExpr(m.args[0], try self.primitive(.str));
        return try self.primitive(.i16);
    }
    const msg = try std.fmt.allocPrint(self.arena, "`str` has no method `{s}`", .{method});
    try self.emitSpan("E_TYPE_UNDEFINED_METHOD", m.method, msg);
    return null;
}

/// Type-check a `str` module call — `str.format(fmt, args...)` (§3.2.2):
/// the format string is a `str`; the trailing args are the positional
/// values (homogeneous). Returns `str`. The placeholder↔arg contract is
/// runtime (the format string need not be a literal), so it isn't checked.
pub fn checkModuleCall(self: *Checker, m: ast.MethodCallExpr) WalkError!?*const types.Type {
    const method = self.lexeme(m.method);
    if (std.mem.eql(u8, method, "format")) {
        if (m.args.len < 1) {
            try self.emitSpan("E_TYPE_ARG_COUNT", m.span, "`str.format` needs a format string");
            return null;
        }
        _ = try self.inferExpr(m.args[0], try self.primitive(.str));
        var pivot: ?*const types.Type = null;
        for (m.args[1..]) |a| {
            const at = try self.inferExpr(a, pivot);
            if (pivot == null) pivot = at;
        }
        return try self.primitive(.str);
    }
    const msg = try std.fmt.allocPrint(self.arena, "`str` module has no function `{s}`", .{method});
    try self.emitSpan("E_TYPE_UNDEFINED_METHOD", m.method, msg);
    return null;
}

/// Emit `E_TYPE_ARG_COUNT` when `m` doesn't have exactly `n` args; returns
/// `true` on mismatch (the caller bails).
fn expectArity(self: *Checker, m: ast.MethodCallExpr, n: usize) WalkError!bool {
    if (m.args.len == n) return false;
    const msg = try std.fmt.allocPrint(self.arena, "`str.{s}` takes {d} argument(s), got {d}", .{ self.lexeme(m.method), n, m.args.len });
    try self.emitSpan("E_TYPE_ARG_COUNT", m.span, msg);
    return true;
}
