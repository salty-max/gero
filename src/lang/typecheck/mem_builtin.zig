/// Stdlib `mem.*` builtin signatures + the two typechecker
/// dispatch helpers that consume them. The `mem` module is
/// compiler-recognized (not a source-level module) so callers
/// hit these resolvers directly instead of going through the
/// regular module-lookup path.
const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const typecheck = @import("../typecheck.zig");

const Checker = typecheck.Checker;
const WalkError = error{OutOfMemory};

/// Signature description for one `mem.X` stdlib builtin — used
/// by both the typechecker (to synthesize a function type during
/// resolution) and the codegen (to dispatch lowering). The
/// `is_addr_of` flag flags the one builtin whose argument type
/// can't be expressed in the regular primitive shape.
pub const MemBuiltinSig = struct {
    name: []const u8,
    params: []const types.Primitive,
    ret: ?types.Primitive,
    is_addr_of: bool = false,
};

const mem_builtins = [_]MemBuiltinSig{
    .{ .name = "read_u8", .params = &.{.u16}, .ret = .u8 },
    .{ .name = "read_u16", .params = &.{.u16}, .ret = .u16 },
    .{ .name = "read_i8", .params = &.{.u16}, .ret = .i8 },
    .{ .name = "read_i16", .params = &.{.u16}, .ret = .i16 },
    .{ .name = "write_u8", .params = &.{ .u16, .u8 }, .ret = null },
    .{ .name = "write_u16", .params = &.{ .u16, .u16 }, .ret = null },
    .{ .name = "write_i8", .params = &.{ .u16, .i8 }, .ret = null },
    .{ .name = "write_i16", .params = &.{ .u16, .i16 }, .ret = null },
    .{ .name = "memcpy", .params = &.{ .u16, .u16, .u16 }, .ret = null },
    .{ .name = "memset", .params = &.{ .u16, .u8, .u16 }, .ret = null },
    .{ .name = "peek", .params = &.{.u16}, .ret = .u8 }, // alias for read_u8
    .{ .name = "poke", .params = &.{ .u16, .u8 }, .ret = null }, // alias for write_u8
    .{ .name = "addr_of", .params = &.{}, .ret = .u16, .is_addr_of = true },
};

/// Look up a `mem.X` builtin by name. Returns `null` for unknown
/// names so the typechecker can surface a clean diagnostic.
pub fn lookupMemBuiltin(name: []const u8) ?MemBuiltinSig {
    for (mem_builtins) |b| {
        if (std.mem.eql(u8, b.name, name)) return b;
    }
    return null;
}

/// Type-check `mem.X(args)` as a method-call expression. The
/// stdlib `mem` module is compiler-recognized; the call's
/// arity + per-arg types are validated against the builtin's
/// declared signature. `mem.addr_of` accepts any addressable
/// argument so it skips per-arg checking — codegen rejects
/// non-addressable targets later.
pub fn checkMemMethodCall(self: *Checker, m: ast.MethodCallExpr) WalkError!?*const types.Type {
    const fn_name = self.lexeme(m.method);
    const sig: ?MemBuiltinSig = lookupMemBuiltin(fn_name);
    if (sig == null) {
        const msg = try std.fmt.allocPrint(
            self.arena,
            "stdlib module `mem` has no member `{s}`",
            .{fn_name},
        );
        try self.emitSpan("E_TYPE_UNDEFINED_METHOD", m.method, msg);
        for (m.args) |a| _ = try self.inferExpr(a, null);
        return null;
    }
    if (sig.?.is_addr_of) {
        if (m.args.len != 1) {
            try self.emitSpan("E_TYPE_ARG_COUNT", m.span, "`mem.addr_of` takes exactly one argument");
        }
        // Walk the arg to populate `expr_types` + run nested
        // checks; codegen handles the "must be addressable" rule.
        for (m.args) |a| _ = try self.inferExpr(a, null);
        return try self.primitive(.u16);
    }
    if (m.args.len != sig.?.params.len) {
        const suffix: []const u8 = if (sig.?.params.len == 1) "" else "s";
        const msg = try std.fmt.allocPrint(
            self.arena,
            "`mem.{s}` takes {d} argument{s}, called with {d}",
            .{ fn_name, sig.?.params.len, suffix, m.args.len },
        );
        try self.emitSpan("E_TYPE_ARG_COUNT", m.span, msg);
    }
    const n = @min(m.args.len, sig.?.params.len);
    for (m.args[0..n], sig.?.params[0..n]) |a, p| {
        const expected = try self.primitive(p);
        _ = try self.inferExpr(a, expected);
    }
    // Walk extras (when arg count mismatched) so per-arg
    // diagnostics still surface.
    if (m.args.len > n) {
        for (m.args[n..]) |a| _ = try self.inferExpr(a, null);
    }
    if (sig.?.ret) |r| return try self.primitive(r);
    return try self.primitive(.nil_);
}

/// Resolve `mem.X` builtin field expressions. Each entry
/// synthesizes a function type so the wrapping `CallExpr` flows
/// through the normal `checkCall` path (arity + per-arg type
/// check). `mem.addr_of` accepts any addressable argument and
/// surfaces as `fn(<anything>) -> u16`, deferring the
/// param-type validation to codegen.
pub fn resolveMemBuiltin(self: *Checker, f: ast.FieldExpr) WalkError!?*const types.Type {
    const fn_name = self.lexeme(f.field);
    const sig: ?MemBuiltinSig = lookupMemBuiltin(fn_name);
    if (sig == null) {
        const msg = try std.fmt.allocPrint(
            self.arena,
            "stdlib module `mem` has no member `{s}`",
            .{fn_name},
        );
        try self.emitSpan("E_TYPE_UNDEFINED_METHOD", f.field, msg);
        return null;
    }
    if (sig.?.is_addr_of) {
        var params: std.ArrayList(*const types.Type) = .empty;
        errdefer params.deinit(self.arena);
        const nil_ty = try self.primitive(.nil_);
        try params.append(self.arena, nil_ty);
        const ret = try self.primitive(.u16);
        const fn_ty = try self.arena.create(types.Type);
        fn_ty.* = .{ .function = .{
            .params = try params.toOwnedSlice(self.arena),
            .ret = ret,
        } };
        return fn_ty;
    }
    var params: std.ArrayList(*const types.Type) = .empty;
    errdefer params.deinit(self.arena);
    for (sig.?.params) |p| {
        const t = try self.primitive(p);
        try params.append(self.arena, t);
    }
    const ret = if (sig.?.ret) |r| try self.primitive(r) else try self.primitive(.nil_);
    const fn_ty = try self.arena.create(types.Type);
    fn_ty.* = .{ .function = .{
        .params = try params.toOwnedSlice(self.arena),
        .ret = ret,
    } };
    return fn_ty;
}
