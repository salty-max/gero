const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const typecheck = @import("../typecheck.zig");
const diag_mod = @import("../diagnostic.zig");
const annotations = @import("annotations.zig");
const calls = @import("calls.zig");
const predicates = @import("predicates.zig");
const type_resolve = @import("type_resolve.zig");
const scope_mod = @import("../scope.zig");

const Checker = typecheck.Checker;
const Scope = scope_mod.Scope;
const T = annotations.T;
const WalkError = error{OutOfMemory};

// Declaration-level checking for `def`s and `class`es: signatures,
// method annotations, inheritance + override rules, and abstract-method
// implementation enforcement.

/// Type-check a `def`: annotations, variadic position, params +
/// return type, and the body in a fresh scope.
///
/// A variadic `def` has no concrete element type at its declaration —
/// `T` is pinned by call sites (§4.6.2). Its body walk is deferred to
/// `resolveDeferredVariadics`, run after the whole program is seen, so
/// `args` binds to the unified `(T, …, T)` tuple rather than an
/// untyped slot.
pub fn checkDefDecl(self: *Checker, d: ast.DefDecl) WalkError!void {
    try annotations.validateAnnotations(self, d.annotations, T.DEF);
    if (d.is_bake) try calls.checkBakeAnnotationConflicts(self, d.annotations);
    try calls.checkVariadicPosition(self, d);

    // Bake fn return type must be bakeable. `Vec(T)` and `&T`
    // are runtime-only.
    if (d.is_bake) if (d.ret_type) |r| {
        const rt = try type_resolve.resolveType(self, r);
        if (!predicates.isBakeableType(rt.*)) {
            const ty_s = try types.render(self.arena, rt.*);
            const msg = try std.fmt.allocPrint(
                self.arena,
                "`bake def` cannot return `{s}` — only types representable as static data are bakeable",
                .{ty_s},
            );
            try self.emitSpan("E_BAKE_NON_BAKEABLE_VALUE", r.span(), msg);
        }
    };

    if (d.ret_type == null and self.bodyMentions(d.body, self.lexeme(d.name))) {
        const msg = try std.fmt.allocPrint(
            self.arena,
            "recursive function `{s}` needs an explicit return type",
            .{self.lexeme(d.name)},
        );
        try self.emitSpan("E_TYPE_RECURSIVE_NO_RET", d.name, msg);
    }

    if (isVariadicDef(d)) {
        // A variadic def/method is monomorphized: defer its body until
        // call sites pin `T` + the arity. Inside a class it's a method —
        // carry the declaring class so the deferred walk restores `self`
        // / fields / `super`; at top level it's a free def. The registries
        // hold the stable decl pointer the deferred walk replays from.
        if (self.current_class_name) |cn| {
            if (self.class_registry.get(cn)) |class| {
                if (stableMethod(self, class, self.lexeme(d.name))) |method| {
                    try self.deferred_variadic_methods.append(self.arena, .{ .class = class, .method = method });
                    return;
                }
            }
        } else if (self.def_registry.get(self.lexeme(d.name))) |ptr| {
            try self.deferred_variadic.append(self.arena, ptr);
            return;
        }
    }

    try walkDefBody(self, d, null);
}

/// `true` when `d`'s last parameter is the variadic `name: ...` slot.
pub fn isVariadicDef(d: ast.DefDecl) bool {
    return d.params.len > 0 and d.params[d.params.len - 1].variadic;
}

/// Walk a `def` body in a fresh scope: bind params, set the bake /
/// no-capture / return-type context, then check statements. For a
/// variadic def, `variadic_args` carries the whole-program `(T, …, T)`
/// tuple to bind the trailing `args` slot to.
pub fn walkDefBody(
    self: *Checker,
    d: ast.DefDecl,
    variadic_args: ?*const types.Type,
) WalkError!void {
    const saved_scope = self.current_scope;
    var fn_scope: Scope = .init(self.arena, saved_scope);
    self.current_scope = &fn_scope;
    defer self.current_scope = saved_scope;

    // Fresh `fn_locals` per fn — params and inner `let`s land
    // here; nested `def`s push their own frame too so an inner
    // fn doesn't inherit outer-fn locals.
    const saved_locals = self.fn_locals;
    self.fn_locals = .{};
    defer self.fn_locals = saved_locals;

    // Bake context: `bake def` body satisfies bake rules.
    // Nested non-bake defs reset the flag for the inner body.
    const saved_bake = self.in_bake;
    self.in_bake = d.is_bake;
    defer self.in_bake = saved_bake;

    // `@no_capture` context: inherited by nested defs.
    const saved_nc = self.in_no_capture;
    self.in_no_capture = saved_nc or annotations.defHasNoCapture(self, d);
    defer self.in_no_capture = saved_nc;

    for (d.params) |p| {
        const pt: ?*const types.Type = if (p.variadic)
            variadic_args
        else if (p.type_ann) |t|
            try type_resolve.resolveType(self, t)
        else
            null;
        try self.registerName(self.lexeme(p.name), .{
            .kind = .param,
            .decl_span = p.name,
            .ty = pt,
        });
    }

    // Track ret type for `return expr` checking inside the body.
    const saved_ret = self.current_ret_ty;
    self.current_ret_ty = if (d.ret_type) |r| try type_resolve.resolveType(self, r) else null;
    defer self.current_ret_ty = saved_ret;

    // Name the variadic slot so an out-of-range `args.N` reports against
    // the call-site minimum, not a bare tuple width.
    const saved_var = self.current_variadic_param;
    self.current_variadic_param = if (variadic_args != null and d.params.len > 0)
        self.lexeme(d.params[d.params.len - 1].name)
    else
        null;
    defer self.current_variadic_param = saved_var;

    try self.walkStatementSequence(d.body);
}

/// Pass 3: type-check deferred variadic bodies (§4.6.2). Each body
/// binds its trailing `args` to the whole-program `(T, …, T)` tuple
/// pinned by call sites. A variadic body may itself call another
/// variadic def, so discover those calls with diagnostics muted until
/// the facts stabilize, then commit one checked walk per body.
pub fn resolveDeferredVariadics(self: *Checker) WalkError!void {
    const total = self.deferred_variadic.items.len + self.deferred_variadic_methods.items.len;
    if (total == 0) return;

    // Discovery converges in at most one round per deferred body: each
    // round can only extend the chain by one variadic callee. Free defs
    // and methods share the loop so a method calling a free variadic def
    // (or vice versa) contributes its arity before either commits.
    var rounds: usize = 0;
    while (rounds <= total) : (rounds += 1) {
        const before = variadicProgress(self);
        try walkDeferredVariadics(self, true);
        if (variadicProgress(self) == before) break;
    }
    try walkDeferredVariadics(self, false);
}

/// Walk every deferred variadic body (free defs + methods) once, binding
/// `args` to the current whole-program tuple. When `mute`, diagnostics
/// are routed to a scratch list and dropped — the walk exists only to
/// surface nested variadic calls into `variadic_info`.
fn walkDeferredVariadics(self: *Checker, mute: bool) WalkError!void {
    const saved = self.diagnostics;
    defer self.diagnostics = saved;
    var scratch: std.ArrayList(diag_mod.Diagnostic) = .empty;
    defer scratch.deinit(self.diag_alloc);
    if (mute) self.diagnostics = &scratch;

    for (self.deferred_variadic.items) |decl| {
        const info = self.variadic_info.get(self.lexeme(decl.name)) orelse continue;
        const args_ty = try deferredArgsTuple(self, info) orelse continue;
        try walkDefBody(self, decl.*, args_ty);
    }
    for (self.deferred_variadic_methods.items) |dm| {
        const key = try calls.methodKey(self, self.lexeme(dm.class.name), self.lexeme(dm.method.name));
        const info = self.variadic_info.get(key) orelse continue;
        const args_ty = try deferredArgsTuple(self, info) orelse continue;
        try walkMethodBody(self, dm.class, dm.method, args_ty);
    }
}

/// The `args: (T, …, T)` tuple a deferred variadic body checks against,
/// or `null` when it's uninstantiable (an arity ≥ 1 was seen but no `T`
/// pinned — an inference failure already reported elsewhere). An entry
/// called only with zero varargs has `elem == null` and `min_arity == 0`:
/// the tuple is empty, so the body still type-checks (and its codegen
/// `$0` specialization stays sound) — the placeholder element is never
/// read.
fn deferredArgsTuple(self: *Checker, info: typecheck.VariadicInfo) WalkError!?*const types.Type {
    const min = info.min_arity orelse 0;
    if (info.elem == null and min > 0) return null;
    const elem = info.elem orelse try self.primitive(.nil_);
    return try variadicArgsTuple(self, elem, min);
}

/// Walk a variadic method body in its class scope: restore the
/// `current_class_*` context + register fields (mirrors `checkClassDecl`'s
/// method setup, minus the per-method signature checks already done in the
/// main walk), then walk the body with `args` bound to the pinned tuple.
fn walkMethodBody(
    self: *Checker,
    class: *const ast.ClassDecl,
    method: *const ast.DefDecl,
    args_ty: *const types.Type,
) WalkError!void {
    const saved_name = self.current_class_name;
    self.current_class_name = self.lexeme(class.name);
    defer self.current_class_name = saved_name;

    const saved_extends = self.current_class_extends;
    self.current_class_extends = class.extends;
    defer self.current_class_extends = saved_extends;

    const saved_scope = self.current_scope;
    var class_scope: Scope = .init(self.arena, saved_scope);
    self.current_scope = &class_scope;
    defer self.current_scope = saved_scope;

    for (class.fields) |f| {
        const ty: ?*const types.Type = if (f.type_ann) |t|
            try type_resolve.resolveType(self, t)
        else
            null;
        try self.registerName(self.lexeme(f.name), .{
            .kind = .let_binding,
            .decl_span = f.name,
            .ty = ty,
        });
    }

    try walkDefBody(self, method.*, args_ty);
}

/// First method named `name` declared directly on `class` — a stable
/// AST pointer for deferral, or `null` when the class doesn't declare it.
fn stableMethod(self: *const Checker, class: *const ast.ClassDecl, name: []const u8) ?*const ast.DefDecl {
    for (class.methods) |*m| if (std.mem.eql(u8, self.lexeme(m.name), name)) return m;
    return null;
}

/// Change metric for the discovery fixpoint: a rolling combine over
/// each entry's min arity + element-pinned flag. Any change to the
/// whole-program facts changes the value, so equality across two
/// rounds means they have stabilized.
fn variadicProgress(self: *const Checker) usize {
    var acc: usize = 0;
    var it = self.variadic_info.iterator();
    while (it.next()) |e| {
        const lo = e.value_ptr.min_arity orelse 0;
        const pinned: usize = if (e.value_ptr.elem != null) 1 else 0;
        acc = acc *% 31 +% (lo *% 2 +% pinned + 1);
    }
    return acc;
}

/// Build the internal `(T, …, T)` tuple of `arity` slots a variadic
/// body sees as `args`. Length is the call-site maximum, so it may
/// exceed the §3.4 user-tuple cap — this aggregate is compiler-internal
/// and never surfaces as a written type.
fn variadicArgsTuple(self: *Checker, elem: *const types.Type, arity: u32) WalkError!*const types.Type {
    const slots = try self.arena.alloc(*const types.Type, arity);
    for (slots) |*s| s.* = elem;
    const out = try self.arena.create(types.Type);
    out.* = .{ .tuple = slots };
    return out;
}

/// Type-check a `class`: annotations, fields, methods, inheritance +
/// override rules, and that every abstract method is implemented.
pub fn checkClassDecl(self: *Checker, d: ast.ClassDecl) WalkError!void {
    try annotations.validateAnnotations(self, d.annotations, T.CLASS);
    const saved = self.current_scope;
    var class_scope: Scope = .init(self.arena, saved);
    self.current_scope = &class_scope;
    defer self.current_scope = saved;

    const saved_extends = self.current_class_extends;
    self.current_class_extends = d.extends;
    defer self.current_class_extends = saved_extends;

    const saved_name = self.current_class_name;
    self.current_class_name = self.lexeme(d.name);
    defer self.current_class_name = saved_name;

    if (d.extends) |ext| if (self.class_registry.get(self.lexeme(ext))) |parent| {
        if (annotations.hasAnnotation(self, parent.annotations, "final")) {
            const msg = try std.fmt.allocPrint(
                self.arena,
                "cannot extend `{s}` — parent class is marked `@final`",
                .{self.lexeme(ext)},
            );
            try self.emitSpan("E_CLASS_FINAL_EXTENDS", ext, msg);
        }
    };

    for (d.fields) |f| {
        try annotations.validateAnnotations(self, f.annotations, T.CLASS_FIELD);
        const ty: ?*const types.Type = if (f.type_ann) |t|
            try type_resolve.resolveType(self, t)
        else
            null;
        try self.registerName(self.lexeme(f.name), .{
            .kind = .let_binding,
            .decl_span = f.name,
            .ty = ty,
        });
        if (f.init) |init_| _ = try self.inferExpr(init_, ty);
    }
    for (d.methods) |m| {
        try checkMethodAnnotations(self, &d, m);
        const sig = try self.signatureFromDef(m);
        try self.registerName(self.lexeme(m.name), .{
            .kind = .function,
            .decl_span = m.name,
            .ty = sig,
        });
        try checkDefDecl(self, m);
    }

    if (!annotations.classIsAbstract(self, &d)) {
        try checkAbstractMethodsImplemented(self, &d);
    }
}

/// Validate OOP annotations on a method against its class
/// and parent chain.
///
/// - `@override` without a parent method → `E_OVERRIDE_NO_PARENT`.
/// - Overriding a `@final` method → `E_METHOD_FINAL_OVERRIDE`.
/// - `@static` with a `self` first param → `E_STATIC_HAS_SELF`.
/// - non-`@static` without a `self` first param → `E_METHOD_NO_SELF`.
fn checkMethodAnnotations(
    self: *Checker,
    cd: *const ast.ClassDecl,
    m: ast.DefDecl,
) WalkError!void {
    const m_name = self.lexeme(m.name);
    const is_override = annotations.hasAnnotation(self, m.annotations, "override");
    const is_static = annotations.hasAnnotation(self, m.annotations, "static");

    const has_self = m.params.len > 0 and std.mem.eql(u8, self.lexeme(m.params[0].name), "self");
    if (is_static) {
        if (has_self) {
            try self.emitSpan(
                "E_STATIC_HAS_SELF",
                m.params[0].name,
                "`@static` method must not take a `self` parameter — it's called as `ClassName.method(...)`",
            );
        }
    } else if (!has_self) {
        // An instance method's receiver is always pushed at fp+4; without
        // a `self` param to claim that slot, the first declared param
        // would alias the receiver pointer. Require `self` (or `@static`).
        const msg = try std.fmt.allocPrint(
            self.arena,
            "method `{s}` must take `self` as its first parameter (or be `@static`)",
            .{m_name},
        );
        try self.emitSpan("E_METHOD_NO_SELF", m.name, msg);
    }

    // A variadic method is non-virtual — it monomorphizes per call-site
    // arity (§4.6.2) and a single vtable slot can't hold its N
    // specializations. So it can't be `@override`/`@abstract`, and it
    // can't share a name with an ancestor method (which would override).
    const is_variadic = isVariadicDef(m);
    if (is_variadic) {
        if (is_override or annotations.hasAnnotation(self, m.annotations, "abstract")) {
            const msg = try std.fmt.allocPrint(
                self.arena,
                "variadic method `{s}` can't be `@override` or `@abstract` — it is non-virtual (statically dispatched per arity)",
                .{m_name},
            );
            try self.emitSpan("E_VAR_VIRTUAL", m.name, msg);
        }
    }

    const parent_method = lookupParentMethod(self, cd, m_name);
    if (is_override) {
        if (parent_method == null) {
            const msg = try std.fmt.allocPrint(
                self.arena,
                "`@override` on `{s}` but no parent class declares a method by that name",
                .{m_name},
            );
            try self.emitSpan("E_OVERRIDE_NO_PARENT", m.name, msg);
        }
    }
    if (parent_method) |pm| {
        if (is_variadic or isVariadicDef(pm.*)) {
            const msg = try std.fmt.allocPrint(
                self.arena,
                "method `{s}` collides with an ancestor method, but a variadic method is non-virtual and can't participate in overriding (§4.6.2)",
                .{m_name},
            );
            try self.emitSpan("E_VAR_OVERRIDE", m.name, msg);
        }
        if (annotations.hasAnnotation(self, pm.annotations, "final")) {
            const msg = try std.fmt.allocPrint(
                self.arena,
                "cannot override `{s}` — parent method is marked `@final`",
                .{m_name},
            );
            try self.emitSpan("E_METHOD_FINAL_OVERRIDE", m.name, msg);
        }
    }
}

/// Walk `cd`'s ancestor chain looking for a method named
/// `name`. Returns the closest ancestor's declaration so the
/// caller can inspect its annotations (final / abstract /
/// private). Returns `null` when no ancestor declares it.
fn lookupParentMethod(
    self: *const Checker,
    cd: *const ast.ClassDecl,
    name: []const u8,
) ?*const ast.DefDecl {
    var cursor = cd;
    while (cursor.extends) |ext| {
        const parent = self.class_registry.get(self.lexeme(ext)) orelse return null;
        for (parent.methods) |*m| {
            if (std.mem.eql(u8, self.lexeme(m.name), name)) return m;
        }
        cursor = parent;
    }
    return null;
}

/// Every abstract method inherited by the concrete class `cd`
/// must be overridden. Missing impls emit
/// `E_ABSTRACT_NOT_IMPLEMENTED`.
fn checkAbstractMethodsImplemented(
    self: *Checker,
    cd: *const ast.ClassDecl,
) WalkError!void {
    var cursor: ?*const ast.ClassDecl = cd;
    while (cursor) |c| : ({
        cursor = if (c.extends) |ext| self.class_registry.get(self.lexeme(ext)) else null;
    }) {
        for (c.methods) |m| {
            if (!annotations.hasAnnotation(self, m.annotations, "abstract")) continue;
            if (hasConcreteImpl(self, cd, self.lexeme(m.name), c)) continue;
            const msg = try std.fmt.allocPrint(
                self.arena,
                "concrete class `{s}` must override abstract method `{s}` inherited from `{s}`",
                .{ self.lexeme(cd.name), self.lexeme(m.name), self.lexeme(c.name) },
            );
            try self.emitSpan("E_ABSTRACT_NOT_IMPLEMENTED", cd.name, msg);
        }
    }
}

/// Walk from `cd` up through ancestors stopping at (not
/// including) `stop_at` — true when some intermediate class
/// declares a non-abstract method named `name`.
fn hasConcreteImpl(
    self: *const Checker,
    cd: *const ast.ClassDecl,
    name: []const u8,
    stop_at: *const ast.ClassDecl,
) bool {
    var cursor: ?*const ast.ClassDecl = cd;
    while (cursor) |c| {
        if (c == stop_at) return false;
        for (c.methods) |m| {
            if (!std.mem.eql(u8, self.lexeme(m.name), name)) continue;
            if (annotations.hasAnnotation(self, m.annotations, "abstract")) continue;
            return true;
        }
        cursor = if (c.extends) |ext| self.class_registry.get(self.lexeme(ext)) else null;
    }
    return false;
}
