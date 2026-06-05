// Type-checking for the compiler-provided stdlib modules whose calls
// take a known signature: `math` (numeric-polymorphic helpers), `bank`
// (bank manipulation), and `test` (assertion helpers). `mem` predates
// this and keeps its own resolver (it has the addr-of special case);
// these three route here from both call forms (`recv.fn(args)` parsed as
// a method call, and the field-callee `CallExpr` shape).

const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const typecheck = @import("../typecheck.zig");
const suggestions = @import("suggestions.zig");

const Checker = typecheck.Checker;
const Primitive = types.Primitive;
const WalkError = error{OutOfMemory};

/// How a builtin's result type is derived from its call.
const Shape = union(enum) {
    /// Fixed param + return primitives (monomorphic, like `mem`).
    mono: struct { params: []const Primitive, ret: ?Primitive },
    /// `arity` args sharing one numeric type `T ∈ {i16,u16,fixed}`;
    /// the call returns `T`. Backs abs/min/max/clamp/wrap_*.
    numeric: u8,
    /// `arity` args sharing one integer type `T ∈ {i16,u16}`; returns
    /// `T`. Backs sat_* — saturation clamps to a type's bounds, which
    /// `fixed` (its own range) doesn't share.
    numeric_int: u8,
    /// `assert_eq`/`assert_ne`: two args of one comparable type → nil.
    equatable_pair,
};

const Sig = struct { name: []const u8, shape: Shape };

const math_sigs = [_]Sig{
    .{ .name = "abs", .shape = .{ .numeric = 1 } },
    .{ .name = "min", .shape = .{ .numeric = 2 } },
    .{ .name = "max", .shape = .{ .numeric = 2 } },
    .{ .name = "clamp", .shape = .{ .numeric = 3 } },
    .{ .name = "wrap_add", .shape = .{ .numeric = 2 } },
    .{ .name = "wrap_sub", .shape = .{ .numeric = 2 } },
    .{ .name = "wrap_mul", .shape = .{ .numeric = 2 } },
    .{ .name = "sat_add", .shape = .{ .numeric_int = 2 } },
    .{ .name = "sat_sub", .shape = .{ .numeric_int = 2 } },
    .{ .name = "sat_mul", .shape = .{ .numeric_int = 2 } },
    .{ .name = "fixed_sin", .shape = .{ .mono = .{ .params = &.{.i16}, .ret = .fixed } } },
    .{ .name = "sqrt_fixed", .shape = .{ .mono = .{ .params = &.{.fixed}, .ret = .fixed } } },
    .{ .name = "rng", .shape = .{ .mono = .{ .params = &.{}, .ret = .u16 } } },
};

const bank_sigs = [_]Sig{
    .{ .name = "switch_to", .shape = .{ .mono = .{ .params = &.{.u8}, .ret = null } } },
    .{ .name = "current", .shape = .{ .mono = .{ .params = &.{}, .ret = .u8 } } },
};

const test_sigs = [_]Sig{
    .{ .name = "assert_eq", .shape = .equatable_pair },
    .{ .name = "assert_ne", .shape = .equatable_pair },
};

/// `true` for the modules this file owns. `mem` is excluded — it keeps
/// its own resolver.
pub fn isModule(name: []const u8) bool {
    return std.mem.eql(u8, name, "math") or
        std.mem.eql(u8, name, "bank") or
        std.mem.eql(u8, name, "test");
}

fn sigsFor(recv: []const u8) []const Sig {
    if (std.mem.eql(u8, recv, "math")) return &math_sigs;
    if (std.mem.eql(u8, recv, "bank")) return &bank_sigs;
    return &test_sigs; // isModule gated the caller to math/bank/test
}

fn lookup(recv: []const u8, name: []const u8) ?Sig {
    for (sigsFor(recv)) |s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

/// `true` when `name` is a function of stdlib module `recv` (gated by
/// `isModule`). Lets `use <name> from <module>` validate the member at
/// registration rather than only at the call site.
pub fn isMember(recv: []const u8, name: []const u8) bool {
    return lookup(recv, name) != null;
}

fn suggest(recv: []const u8, name: []const u8) ?[]const u8 {
    const sigs = sigsFor(recv);
    var pool: [16][]const u8 = undefined;
    for (sigs, 0..) |s, i| pool[i] = s.name;
    return suggestions.bestMatch(name, pool[0..sigs.len]);
}

fn isNumeric(t: *const types.Type) bool {
    return t.* == .primitive and switch (t.primitive) {
        .i16, .u16, .fixed => true,
        else => false,
    };
}

fn isIntScalar(t: *const types.Type) bool {
    return t.* == .primitive and switch (t.primitive) {
        .i16, .u16 => true,
        else => false,
    };
}

/// Types that fit a register and compare with a single `cmp` — what
/// `test.assert_eq` / `assert_ne` accept. Excludes `str` (content
/// compare) and aggregates (no primitive form here).
fn isRegScalar(t: *const types.Type) bool {
    return t.* == .primitive and switch (t.primitive) {
        .i8, .u8, .i16, .u16, .bool_, .char, .fixed => true,
        .nil_, .str => false,
    };
}

/// Type-check a `recv.name(args)` call against the module's signature.
/// Returns the call's result type (`nil` for void helpers), or `null`
/// when the member is unknown (a diagnostic is emitted).
pub fn checkCall(
    self: *Checker,
    recv: []const u8,
    name_span: ast.Span,
    args: []const *ast.Expr,
    call_span: ast.Span,
) WalkError!?*const types.Type {
    return checkCallName(self, recv, self.lexeme(name_span), name_span, args, call_span);
}

/// `checkCall` resolved by an explicit function `name` rather than its
/// source span — used when a selectively-imported (and possibly
/// renamed) stdlib function is called bare (`use rng as random from
/// math` then `random()`). `diag_span` anchors any error.
pub fn checkCallName(
    self: *Checker,
    recv: []const u8,
    name: []const u8,
    diag_span: ast.Span,
    args: []const *ast.Expr,
    call_span: ast.Span,
) WalkError!?*const types.Type {
    const sig = lookup(recv, name) orelse {
        const msg = try std.fmt.allocPrint(self.arena, "stdlib module `{s}` has no member `{s}`", .{ recv, name });
        try self.emitSpanWithSuggestion("E_TYPE_UNDEFINED_METHOD", diag_span, msg, suggest(recv, name));
        for (args) |a| _ = try self.inferExpr(a, null);
        return null;
    };
    switch (sig.shape) {
        .mono => |m| {
            try checkArity(self, recv, name, call_span, args.len, m.params.len);
            const n = @min(args.len, m.params.len);
            for (args[0..n], m.params[0..n]) |a, p| {
                _ = try self.inferExpr(a, try self.primitive(p));
            }
            for (args[n..]) |a| _ = try self.inferExpr(a, null);
            return if (m.ret) |r| try self.primitive(r) else try self.primitive(.nil_);
        },
        .numeric => |arity| {
            try checkArity(self, recv, name, call_span, args.len, arity);
            if (args.len == 0) return try self.primitive(.i16);
            // The first arg fixes the type; it must be numeric, and the
            // rest must match it.
            const first = try self.inferExpr(args[0], null);
            const result: *const types.Type = if (first != null and isNumeric(first.?))
                first.?
            else blk: {
                if (first != null) {
                    const ty_s = try types.render(self.arena, first.?.*);
                    const msg = try std.fmt.allocPrint(self.arena, "`math.{s}` expects a numeric type (i16, u16, or fixed), got `{s}`", .{ name, ty_s });
                    try self.emitSpan("E_TYPE_MISMATCH", args[0].span(), msg);
                }
                break :blk try self.primitive(.i16);
            };
            for (args[1..]) |a| _ = try self.inferExpr(a, result);
            return result;
        },
        .numeric_int => |arity| {
            try checkArity(self, recv, name, call_span, args.len, arity);
            if (args.len == 0) return try self.primitive(.i16);
            const first = try self.inferExpr(args[0], null);
            const result: *const types.Type = if (first != null and isIntScalar(first.?))
                first.?
            else blk: {
                if (first != null) {
                    const ty_s = try types.render(self.arena, first.?.*);
                    const msg = try std.fmt.allocPrint(self.arena, "`math.{s}` expects an integer type (i16 or u16), got `{s}`", .{ name, ty_s });
                    try self.emitSpan("E_TYPE_MISMATCH", args[0].span(), msg);
                }
                break :blk try self.primitive(.i16);
            };
            for (args[1..]) |a| _ = try self.inferExpr(a, result);
            return result;
        },
        .equatable_pair => {
            try checkArity(self, recv, name, call_span, args.len, 2);
            if (args.len == 0) return try self.primitive(.nil_);
            // Both args must share one register-scalar type; the first
            // fixes it (the lowering compares them in registers).
            const first = try self.inferExpr(args[0], null);
            if (first != null and !isRegScalar(first.?)) {
                const ty_s = try types.render(self.arena, first.?.*);
                const msg = try std.fmt.allocPrint(self.arena, "`test.{s}` compares scalar values (int / bool / char / fixed), got `{s}`", .{ name, ty_s });
                try self.emitSpan("E_TYPE_MISMATCH", args[0].span(), msg);
            }
            for (args[1..]) |a| _ = try self.inferExpr(a, first);
            return try self.primitive(.nil_);
        },
    }
}

fn checkArity(self: *Checker, recv: []const u8, name: []const u8, span: ast.Span, got: usize, want: usize) WalkError!void {
    if (got == want) return;
    const suffix: []const u8 = if (want == 1) "" else "s";
    const msg = try std.fmt.allocPrint(self.arena, "`{s}.{s}` takes {d} argument{s}, called with {d}", .{ recv, name, want, suffix, got });
    try self.emitSpan("E_TYPE_ARG_COUNT", span, msg);
}
