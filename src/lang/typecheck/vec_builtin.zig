// Type-checking for the compiler-known `Vec(T)` surface (§3.4.3). Mirrors
// `mem_builtin` — a fixed set of method signatures, generic over the
// receiver's element type `T`. Includes `pop` / `get`, which return `T?`.

const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const typecheck = @import("../typecheck.zig");

const Checker = typecheck.Checker;
const WalkError = error{OutOfMemory};

/// `true` when `name` is a `Vec.<name>(...)` constructor.
pub fn isConstructor(name: []const u8) bool {
    return std.mem.eql(u8, name, "new") or
        std.mem.eql(u8, name, "with_capacity") or
        std.mem.eql(u8, name, "from");
}

/// Type-check `Vec.<ctor>(args)`, returning the constructed `Vec(T)`. `T`
/// comes from the annotation hint (`new` / `with_capacity`) or the array
/// argument's element type (`from`).
pub fn checkConstructor(self: *Checker, m: ast.MethodCallExpr, hint: ?*const types.Type) WalkError!?*const types.Type {
    const method = self.lexeme(m.method);
    if (std.mem.eql(u8, method, "from")) {
        if (try expectArity(self, m, 1)) return null;
        const arg_ty = try self.inferExpr(m.args[0], null);
        if (arg_ty) |at| if (at.* == .array) return try types.mkVec(self.arena, at.array.elem);
        try self.emitSpan("E_TYPE_MISMATCH", m.span, "`Vec.from` expects a fixed-array argument");
        return null;
    }
    const vec_ty: *const types.Type = if (hint != null and hint.?.* == .vec)
        hint.?
    else {
        try self.emitSpan("E_TYPE_AMBIGUOUS_INFER", m.span, "cannot infer `Vec` element type — annotate the binding (`let v: Vec(T) = …`)");
        return null;
    };
    if (std.mem.eql(u8, method, "new")) {
        if (try expectArity(self, m, 0)) return null;
        return vec_ty;
    }
    // `with_capacity(n)` — `n: u16`.
    if (try expectArity(self, m, 1)) return null;
    _ = try self.inferExpr(m.args[0], try types.mkPrimitive(self.arena, .u16));
    return vec_ty;
}

/// Type-check a Vec instance method `v.<method>(args)`; `elem` is the
/// receiver's element type. Returns the method's result type.
pub fn checkMethod(self: *Checker, m: ast.MethodCallExpr, elem: *const types.Type) WalkError!?*const types.Type {
    const method = self.lexeme(m.method);
    const u16_ty = try types.mkPrimitive(self.arena, .u16);
    const nil_ty = try types.mkPrimitive(self.arena, .nil_);
    if (std.mem.eql(u8, method, "len") or std.mem.eql(u8, method, "cap")) {
        if (try expectArity(self, m, 0)) return null;
        return u16_ty;
    }
    if (std.mem.eql(u8, method, "clear")) {
        if (try expectArity(self, m, 0)) return null;
        return nil_ty;
    }
    if (std.mem.eql(u8, method, "at")) {
        if (try expectArity(self, m, 1)) return null;
        _ = try self.inferExpr(m.args[0], u16_ty);
        return elem;
    }
    if (std.mem.eql(u8, method, "set")) {
        if (try expectArity(self, m, 2)) return null;
        _ = try self.inferExpr(m.args[0], u16_ty);
        _ = try self.inferExpr(m.args[1], elem);
        return nil_ty;
    }
    if (std.mem.eql(u8, method, "push")) {
        if (try expectArity(self, m, 1)) return null;
        _ = try self.inferExpr(m.args[0], elem);
        return nil_ty;
    }
    if (std.mem.eql(u8, method, "slice")) {
        if (try expectArity(self, m, 2)) return null;
        _ = try self.inferExpr(m.args[0], u16_ty);
        _ = try self.inferExpr(m.args[1], u16_ty);
        return try types.mkVec(self.arena, elem);
    }
    if (std.mem.eql(u8, method, "pop")) {
        if (try expectArity(self, m, 0)) return null;
        return try types.mkOptional(self.arena, elem);
    }
    if (std.mem.eql(u8, method, "get")) {
        if (try expectArity(self, m, 1)) return null;
        _ = try self.inferExpr(m.args[0], u16_ty);
        return try types.mkOptional(self.arena, elem);
    }
    const msg = try std.fmt.allocPrint(self.arena, "`Vec` has no method `{s}`", .{method});
    try self.emitSpan("E_TYPE_UNDEFINED_METHOD", m.method, msg);
    return null;
}

/// Emit `E_TYPE_ARG_COUNT` when `m` doesn't have exactly `n` args; returns
/// `true` on mismatch (the caller bails).
fn expectArity(self: *Checker, m: ast.MethodCallExpr, n: usize) WalkError!bool {
    if (m.args.len == n) return false;
    const msg = try std.fmt.allocPrint(self.arena, "`Vec.{s}` takes {d} argument(s), got {d}", .{ self.lexeme(m.method), n, m.args.len });
    try self.emitSpan("E_TYPE_ARG_COUNT", m.span, msg);
    return true;
}
