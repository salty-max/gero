const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const typecheck = @import("../typecheck.zig");
const predicates = @import("predicates.zig");
const relations = @import("relations.zig");
const annotations = @import("annotations.zig");
const flow = @import("flow.zig");
const stdlib = @import("stdlib.zig");

const Checker = typecheck.Checker;
const WalkError = error{OutOfMemory};

/// Type-check a regular call expression. Routes `assert` /
/// `debug_assert` through their dedicated path, validates abstract-
/// class instantiation, dispatches variadic callees to
/// `checkVariadicCall`, and otherwise performs the standard arity +
/// per-arg checks.
pub fn checkCall(self: *Checker, c: ast.CallExpr, hint: ?*const types.Type) WalkError!?*const types.Type {
    _ = hint;
    // `assert` / `debug_assert` always-in-scope builtins
    // (§5.3) — no underlying `def`, so they skip the regular
    // callee-resolution path.
    if (c.callee.* == .ident) {
        const callee_name = self.lexeme(c.callee.ident.span);
        if (isAssertBuiltinName(callee_name)) {
            return try checkAssertBuiltin(self, c, callee_name);
        }
        if (isDivergeBuiltinName(callee_name)) {
            return try checkDivergeBuiltin(self, c, callee_name);
        }
    }
    // Stdlib module call in field-callee form (`math.min(a, b)` where
    // the callee parses as a `FieldExpr`). Route to the stdlib checker
    // so numeric-polymorphic args resolve from the call site rather than
    // synthesizing a fn type without them.
    if (c.callee.* == .field) {
        const fe = c.callee.field;
        if (fe.receiver.* == .ident) {
            const recv = self.lexeme(fe.receiver.ident.span);
            if (stdlib.isModule(recv)) {
                return try stdlib.checkCall(self, recv, fe.field, c.args, c.span);
            }
        }
    }
    // Abstract-class instantiation: `ClassName(args)` where
    // `ClassName` is abstract is rejected.
    if (c.callee.* == .ident) {
        const callee_name = self.lexeme(c.callee.ident.span);
        if (self.class_registry.get(callee_name)) |cd| {
            if (annotations.classIsAbstract(self, cd)) {
                const msg = try std.fmt.allocPrint(
                    self.arena,
                    "cannot instantiate `{s}` — class is `@abstract`",
                    .{callee_name},
                );
                try self.emitSpan("E_CLASS_ABSTRACT_INSTANTIATE", c.callee.span(), msg);
            }
        }
    }
    const callee_ty = try self.inferExpr(c.callee, null);
    // Bake-context rule: only `bake def` fns may be called.
    if (self.in_bake) try checkBakeCall(self, c);
    if (callee_ty == null) {
        for (c.args) |a| _ = try self.inferExpr(a, null);
        return null;
    }
    if (callee_ty.?.* != .function) {
        const ty_s = try types.render(self.arena, callee_ty.?.*);
        const msg = try std.fmt.allocPrint(
            self.arena,
            "called value has type `{s}`, expected a function",
            .{ty_s},
        );
        try self.emitSpan("E_TYPE_MISMATCH", c.callee.span(), msg);
        for (c.args) |a| _ = try self.inferExpr(a, null);
        return null;
    }
    const f = callee_ty.?.function;

    // Variadic call: when the callee resolves to a `def` whose
    // last param is variadic, the arity / per-arg checks pivot
    // on the leading fixed params; the trailing args must share
    // a single type.
    if (variadicCalleeDecl(self, c.callee)) |decl| {
        return try checkVariadicCall(self, c, decl, f);
    }

    if (c.args.len != f.params.len) {
        const suffix: []const u8 = if (f.params.len == 1) "" else "s";
        const msg = try std.fmt.allocPrint(
            self.arena,
            "function takes {d} argument{s}, called with {d}",
            .{ f.params.len, suffix, c.args.len },
        );
        try self.emitSpan("E_TYPE_ARG_COUNT", c.span, msg);
        for (c.args) |a| _ = try self.inferExpr(a, null);
        return f.ret;
    }
    for (c.args, 0..) |arg, i| {
        const param_ty = f.params[i];
        // Skip the type check when the param's type is the
        // `nil_` placeholder used for unannotated `def` params —
        // those params accept any caller-supplied type.
        const skip = predicates.isNilType(param_ty.*);
        const arg_ty = try self.inferExpr(arg, if (skip) null else param_ty);
        if (!skip and arg_ty != null) {
            try self.checkStoreCompat(arg.span(), param_ty, arg_ty.?);
        }
    }
    return f.ret;
}

/// Type-check `assert(cond, msg?)` / `debug_assert(cond, msg?)`.
/// Validates arity (1 or 2 args), bool cond, str msg, and warns
/// when a `debug_assert` arg looks side-effecting (any nested
/// `CallExpr` is the proxy). Returns `nil` — the builtins are
/// statement-shaped even when called in expression position.
pub fn checkAssertBuiltin(
    self: *Checker,
    c: ast.CallExpr,
    name: []const u8,
) WalkError!?*const types.Type {
    if (c.args.len == 0 or c.args.len > 2) {
        const msg = try std.fmt.allocPrint(
            self.arena,
            "`{s}` takes 1 or 2 arguments (cond, msg?), called with {d}",
            .{ name, c.args.len },
        );
        try self.emitSpan("E_ASSERT_ARG_COUNT", c.span, msg);
        for (c.args) |a| _ = try self.inferExpr(a, null);
        return try self.primitive(.nil_);
    }
    const bool_ty = try self.primitive(.bool_);
    const cond_ty = try self.inferExpr(c.args[0], bool_ty);
    if (cond_ty != null and !relations.assignable(cond_ty.?.*, bool_ty.*)) {
        try self.emitMismatch(c.args[0].span(), bool_ty, cond_ty.?);
    }
    if (c.args.len == 2) {
        const str_ty = try self.primitive(.str);
        const msg_ty = try self.inferExpr(c.args[1], str_ty);
        if (msg_ty != null and !relations.assignable(msg_ty.?.*, str_ty.*)) {
            try self.emitMismatch(c.args[1].span(), str_ty, msg_ty.?);
        }
    }
    // `debug_assert` is elided in release — surface any
    // observable side effect (a nested call) so the user
    // doesn't rely on it firing in shipped builds.
    if (std.mem.eql(u8, name, "debug_assert")) {
        for (c.args) |a| if (exprContainsCall(a)) {
            try self.diagnostics.append(self.diag_alloc, .{
                .severity = .warning,
                .code = "W_DEBUG_ASSERT_SIDE_EFFECT",
                .message = "`debug_assert` arguments are elided in release builds — any side effects here will not occur",
                .span = a.span(),
            });
            break;
        };
    }
    return try self.primitive(.nil_);
}

/// Type-check `panic(msg)` / `unreachable()` / `todo(msg?)`.
/// All three diverge — they halt the VM. Returns `nil` so they
/// flow in any statement position (including `match` bail arms).
///
/// - `panic(msg: str)` — exactly 1 arg, must be `str`.
/// - `unreachable()` — exactly 0 args.
/// - `todo(msg: str?)` — 0 or 1 arg; arg must be `str`.
pub fn checkDivergeBuiltin(
    self: *Checker,
    c: ast.CallExpr,
    name: []const u8,
) WalkError!?*const types.Type {
    const is_unreachable = std.mem.eql(u8, name, name_unreachable);
    const is_panic = std.mem.eql(u8, name, "panic");
    const is_todo = std.mem.eql(u8, name, "todo");

    if (is_unreachable) {
        if (c.args.len != 0) {
            try self.emitSpan(
                "E_ASSERT_ARG_COUNT",
                c.span,
                arg_count_msg_unreachable,
            );
            for (c.args) |a| _ = try self.inferExpr(a, null);
        }
    } else if (is_panic) {
        if (c.args.len != 1) {
            try self.emitSpan(
                "E_ASSERT_ARG_COUNT",
                c.span,
                "`panic` takes exactly 1 argument (msg)",
            );
            for (c.args) |a| _ = try self.inferExpr(a, null);
        } else {
            try checkStrArg(self, c.args[0]);
        }
    } else if (is_todo) {
        if (c.args.len > 1) {
            try self.emitSpan(
                "E_ASSERT_ARG_COUNT",
                c.span,
                "`todo` takes 0 or 1 arguments (msg?)",
            );
            for (c.args) |a| _ = try self.inferExpr(a, null);
        } else if (c.args.len == 1) {
            try checkStrArg(self, c.args[0]);
        }
    }
    return try self.primitive(.nil_);
}

fn checkStrArg(self: *Checker, arg: *const ast.Expr) WalkError!void {
    const str_ty = try self.primitive(.str);
    const got = try self.inferExpr(arg, str_ty);
    if (got != null and !relations.assignable(got.?.*, str_ty.*)) {
        try self.emitMismatch(arg.span(), str_ty, got.?);
    }
}

/// Verify a `def`'s param list places the (optional) variadic
/// param last. Parser may already enforce; this check routes any
/// out-of-place variadic through `E_VAR_NOT_LAST`.
pub fn checkVariadicPosition(self: *Checker, d: ast.DefDecl) WalkError!void {
    var is_variadic = false;
    for (d.params, 0..) |p, i| {
        if (!p.variadic) continue;
        is_variadic = true;
        if (i != d.params.len - 1) {
            try self.emitSpan("E_VAR_NOT_LAST", p.span, "variadic parameter must be the last in the parameter list");
            return;
        }
    }
    // A variadic def specializes per call-site arity (§4.6.2); `@inline`
    // splices one shared body, which can't express a per-arity layout.
    if (is_variadic and annotations.hasAnnotation(self, d.annotations, "inline")) {
        try self.emitSpan("E_VAR_INLINE", d.name, "a variadic function cannot be `@inline` — it already specializes per call-site arity (§4.6.2)");
    }
}

/// Type-check a call whose callee has a trailing variadic param.
/// The leading fixed params match positionally; every arg passed
/// into the variadic slot must share a single type.
pub fn checkVariadicCall(
    self: *Checker,
    c: ast.CallExpr,
    decl: *const ast.DefDecl,
    f: types.Function,
) WalkError!?*const types.Type {
    const fixed_count = decl.params.len - 1;
    if (c.args.len < fixed_count) {
        const suffix: []const u8 = if (fixed_count == 1) "" else "s";
        const msg = try std.fmt.allocPrint(
            self.arena,
            "variadic function requires at least {d} fixed argument{s}, called with {d}",
            .{ fixed_count, suffix, c.args.len },
        );
        try self.emitSpan("E_TYPE_ARG_COUNT", c.span, msg);
        for (c.args) |a| _ = try self.inferExpr(a, null);
        return f.ret;
    }
    // Fixed params: standard per-arg type check.
    for (c.args[0..fixed_count], 0..) |arg, i| {
        const param_ty = f.params[i];
        const skip = predicates.isNilType(param_ty.*);
        const arg_ty = try self.inferExpr(arg, if (skip) null else param_ty);
        if (!skip and arg_ty != null) {
            try self.checkStoreCompat(arg.span(), param_ty, arg_ty.?);
        }
    }
    // Variadic slot: all trailing args must share a type.
    var pivot: ?*const types.Type = null;
    for (c.args[fixed_count..]) |arg| {
        const arg_ty = try self.inferExpr(arg, pivot);
        const at = arg_ty orelse continue;
        if (pivot) |p| {
            if (!relations.assignable(at.*, p.*)) {
                const exp_s = try types.render(self.arena, p.*);
                const got_s = try types.render(self.arena, at.*);
                const msg = try std.fmt.allocPrint(
                    self.arena,
                    "variadic argument has type `{s}` but earlier variadic arg was `{s}` — all variadic args must share a single type",
                    .{ got_s, exp_s },
                );
                try self.emitSpan("E_VAR_HETEROGENEOUS", arg.span(), msg);
            }
        } else {
            pivot = at;
        }
    }
    // Fold this call's element type + arity into the callee's
    // whole-program variadic facts (§4.6.2) so the body can be
    // type-checked once against `args: (T, …, T)` of the max arity.
    if (directCalleeName(self, c.callee)) |name| {
        const arity: u32 = @intCast(c.args.len - fixed_count);
        try recordVariadic(self, name, pivot, arity, c.span);
    }
    return f.ret;
}

/// Fold one call site's `(elem, arity)` into the callee's whole-program
/// variadic facts (§4.6.2). The element type unifies across call sites;
/// a divergent type is reported through `E_VAR_INCONSISTENT_TYPE`.
fn recordVariadic(
    self: *Checker,
    name: []const u8,
    elem: ?*const types.Type,
    arity: u32,
    span: ast.Span,
) WalkError!void {
    const gop = try self.variadic_info.getOrPut(self.arena, name);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    if (gop.value_ptr.min_arity) |lo| {
        if (arity < lo) gop.value_ptr.min_arity = arity;
    } else gop.value_ptr.min_arity = arity;
    try addArity(self, &gop.value_ptr.arities, arity);
    const e = elem orelse return;
    if (gop.value_ptr.elem) |existing| {
        if (!relations.assignable(e.*, existing.*) or !relations.assignable(existing.*, e.*)) {
            const had = try types.render(self.arena, existing.*);
            const got = try types.render(self.arena, e.*);
            const msg = try std.fmt.allocPrint(
                self.arena,
                "variadic `{s}` is called with element type `{s}` here but `{s}` elsewhere — a variadic function has one element type across all call sites",
                .{ name, got, had },
            );
            try self.emitSpan("E_VAR_INCONSISTENT_TYPE", span, msg);
        }
    } else {
        gop.value_ptr.elem = e;
    }
}

/// Add `arity` to a variadic def's distinct-arity set (deduped). The
/// set drives one codegen specialization per arity (§4.6.2).
fn addArity(self: *Checker, set: *std.ArrayListUnmanaged(u32), arity: u32) WalkError!void {
    for (set.items) |a| if (a == arity) return;
    try set.append(self.arena, arity);
}

/// Bake-context call rule (§3.8): only `bake def` functions may be
/// called from inside a `bake` body. Emits `E_BAKE_FORBIDDEN_CALL`
/// for any other callee resolvable to a registered def.
pub fn checkBakeCall(self: *Checker, c: ast.CallExpr) WalkError!void {
    const callee_name = directCalleeName(self, c.callee) orelse return;
    const decl = self.def_registry.get(callee_name) orelse return;
    if (!decl.is_bake) {
        const msg = try std.fmt.allocPrint(
            self.arena,
            "cannot call non-`bake` function `{s}` from inside a `bake` context",
            .{callee_name},
        );
        try self.emitSpan("E_BAKE_FORBIDDEN_CALL", c.callee.span(), msg);
    }
}

/// Per spec §3.8, `bake` cannot combine with `@cold`, `@inline`,
/// `@interrupt`, `@bank`, or `@no_capture` — those describe
/// runtime codegen and have no meaning at compile-time evaluation.
/// Reuses `E_ANN_CONFLICT` with a bake-flavored message so editors
/// / filters match the same code as other mutual-exclusion checks.
pub fn checkBakeAnnotationConflicts(self: *Checker, anns: []const ast.Annotation) WalkError!void {
    const forbidden = [_][]const u8{ "cold", "inline", "interrupt", "bank", "no_capture" };
    for (anns) |ann| {
        const name = self.lexeme(ann.name);
        for (forbidden) |f| {
            if (std.mem.eql(u8, name, f)) {
                const msg = try std.fmt.allocPrint(
                    self.arena,
                    "annotation `@{s}` cannot be combined with `bake` — `@{s}` describes runtime codegen, which has no meaning for compile-time evaluation (§3.8)",
                    .{ name, name },
                );
                try self.emitSpan("E_ANN_CONFLICT", ann.name, msg);
            }
        }
    }
}

// ---------- callee resolution helpers ----------

/// Extract the lexeme of a callee that is a bare ident (possibly
/// wrapped in `paren`). Used by call-site rules that need to find
/// the underlying decl (bake-call check, variadic detection).
fn directCalleeName(c: *const Checker, callee: *const ast.Expr) ?[]const u8 {
    return flow.identName(c, callee);
}

/// When `callee` resolves to a `def` decl whose last param is
/// variadic, return that decl. Returns `null` otherwise — callers
/// fall back to the regular fixed-arity path.
fn variadicCalleeDecl(c: *const Checker, callee: *const ast.Expr) ?*const ast.DefDecl {
    const name = flow.identName(c, callee) orelse return null;
    const decl = c.def_registry.get(name) orelse return null;
    if (decl.params.len == 0) return null;
    if (!decl.params[decl.params.len - 1].variadic) return null;
    return decl;
}

/// `true` when `name` is one of the always-in-scope assert
/// builtins per spec §5.3. Recognized at call sites before any
/// generic callee resolution.
fn isAssertBuiltinName(name: []const u8) bool {
    return std.mem.eql(u8, name, "assert") or std.mem.eql(u8, name, "debug_assert");
}

/// `true` when `name` is one of the always-in-scope diverging
/// builtins per spec §5.3. Recognized at call sites before any
/// generic callee resolution.
fn isDivergeBuiltinName(name: []const u8) bool {
    return std.mem.eql(u8, name, "panic") or
        std.mem.eql(u8, name, name_unreachable) or
        std.mem.eql(u8, name, "todo");
}

// allow-strict: gero builtin name; Zig keyword sense doesn't apply on this line.
const name_unreachable: []const u8 = "unreachable";
// allow-strict: arg-count diagnostic text printed when the `unreachable` builtin is called wrong.
const arg_count_msg_unreachable: []const u8 = "`unreachable` takes no arguments";

/// `true` when `e` contains a `CallExpr` anywhere in its sub-tree.
/// Used as a side-effect proxy for the
/// `W_DEBUG_ASSERT_SIDE_EFFECT` warning — observable mutations
/// happen through function calls in gero, so any call inside a
/// `debug_assert` arg is worth flagging.
fn exprContainsCall(e: *const ast.Expr) bool {
    return switch (e.*) {
        .call, .method_call => true,
        .paren => |p| exprContainsCall(p.inner),
        .unary => |u| exprContainsCall(u.operand),
        .binary => |b| exprContainsCall(b.lhs) or exprContainsCall(b.rhs),
        .field => |f| exprContainsCall(f.receiver),
        .index => |ix| exprContainsCall(ix.receiver) or exprContainsCall(ix.index),
        .cast => |c| exprContainsCall(c.inner),
        .ref_of => |r| exprContainsCall(r.inner),
        .is_test => |it| exprContainsCall(it.lhs),
        else => false,
    };
}
