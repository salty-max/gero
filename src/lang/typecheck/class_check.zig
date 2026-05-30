const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const typecheck = @import("../typecheck.zig");
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
pub fn checkDefDecl(self: *Checker, d: ast.DefDecl) WalkError!void {
    try annotations.validateAnnotations(self, d.annotations, T.DEF);
    if (d.is_bake) try calls.checkBakeAnnotationConflicts(self, d.annotations);
    try calls.checkVariadicPosition(self, d);
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

    for (d.params) |p| {
        const pt: ?*const types.Type = if (p.type_ann) |t|
            try type_resolve.resolveType(self, t)
        else
            null;
        try self.registerName(self.lexeme(p.name), .{
            .kind = .param,
            .decl_span = p.name,
            .ty = pt,
        });
    }

    if (d.ret_type == null and self.bodyMentions(d.body, self.lexeme(d.name))) {
        const msg = try std.fmt.allocPrint(
            self.arena,
            "recursive function `{s}` needs an explicit return type",
            .{self.lexeme(d.name)},
        );
        try self.emitSpan("E_TYPE_RECURSIVE_NO_RET", d.name, msg);
    }

    // Track ret type for `return expr` checking inside the body.
    const saved_ret = self.current_ret_ty;
    self.current_ret_ty = if (d.ret_type) |r| try type_resolve.resolveType(self, r) else null;
    defer self.current_ret_ty = saved_ret;

    try self.walkStatementSequence(d.body);
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
fn checkMethodAnnotations(
    self: *Checker,
    cd: *const ast.ClassDecl,
    m: ast.DefDecl,
) WalkError!void {
    const m_name = self.lexeme(m.name);
    const is_override = annotations.hasAnnotation(self, m.annotations, "override");
    const is_static = annotations.hasAnnotation(self, m.annotations, "static");

    if (is_static and m.params.len > 0) {
        const first = self.lexeme(m.params[0].name);
        if (std.mem.eql(u8, first, "self")) {
            try self.emitSpan(
                "E_STATIC_HAS_SELF",
                m.params[0].name,
                "`@static` method must not take a `self` parameter — it's called as `ClassName.method(...)`",
            );
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
