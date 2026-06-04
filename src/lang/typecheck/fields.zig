const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const diag_mod = @import("../diagnostic.zig");
const typecheck = @import("../typecheck.zig");
const type_resolve = @import("type_resolve.zig");
const annotations = @import("annotations.zig");
const flow = @import("flow.zig");
const predicates = @import("predicates.zig");
const mem_builtin = @import("mem_builtin.zig");
const calls = @import("calls.zig");
const class_check = @import("class_check.zig");

const Checker = typecheck.Checker;
const WalkError = error{OutOfMemory};

/// Resolve an enum-variant constructor expression
/// (`EnumName.Variant`). Nullary variants resolve directly to
/// the enum's `Named` type — `let s = Color.Red` infers as
/// `Color`. Payload-bearing variants resolve to the constructor
/// function type `fn(payload_types) -> Enum` so a wrapping
/// `CallExpr` (`Item.Potion(20)`) type-checks through the
/// regular `checkCall` path.
pub fn resolveEnumVariant(
    self: *Checker,
    ed: *const ast.EnumDecl,
    enum_name: []const u8,
    f: ast.FieldExpr,
) WalkError!?*const types.Type {
    const variant_name = self.lexeme(f.field);
    const variant: ?*const ast.EnumVariant = blk: {
        for (ed.variants) |*v| {
            if (std.mem.eql(u8, self.lexeme(v.name), variant_name)) break :blk v;
        }
        break :blk null;
    };
    if (variant == null) {
        const msg = try std.fmt.allocPrint(
            self.arena,
            "enum `{s}` has no variant `{s}`",
            .{ enum_name, variant_name },
        );
        try self.emitSpan("E_TYPE_UNDEFINED_VARIANT", f.field, msg);
        return null;
    }
    const enum_ty = try types.mkNamed(self.arena, enum_name, f.receiver.ident.span);
    if (variant.?.payload.len == 0) return enum_ty;

    // Payload-bearing variant — synthesize a constructor
    // function signature so call-site type-checking flows.
    var param_tys: std.ArrayList(*const types.Type) = .empty;
    errdefer param_tys.deinit(self.arena);
    for (variant.?.payload) |pf| {
        const pt = try type_resolve.resolveType(self, pf.type_ann);
        try param_tys.append(self.arena, pt);
    }
    const fn_ty = try self.arena.create(types.Type);
    fn_ty.* = .{ .function = .{
        .params = try param_tys.toOwnedSlice(self.arena),
        .ret = enum_ty,
    } };
    return fn_ty;
}

/// Type-check a payload-variant constructor written as a method
/// call — `Item.Potion(20)` parses as `Item`.`Potion`(20), since the
/// surface syntax is indistinguishable from a method call. Resolves
/// the variant, checks the payload args against its field types, and
/// infers the enum's `Named` type (so `let x = Item.Potion(20)` binds
/// `x: Item` rather than leaving it untyped).
pub fn checkEnumVariantConstruct(
    self: *Checker,
    m: ast.MethodCallExpr,
    ed: *const ast.EnumDecl,
    enum_name: []const u8,
) WalkError!?*const types.Type {
    const variant_name = self.lexeme(m.method);
    const variant: *const ast.EnumVariant = blk: {
        for (ed.variants) |*v| {
            if (std.mem.eql(u8, self.lexeme(v.name), variant_name)) break :blk v;
        }
        const msg = try std.fmt.allocPrint(
            self.arena,
            "enum `{s}` has no variant `{s}`",
            .{ enum_name, variant_name },
        );
        try self.emitSpan("E_TYPE_UNDEFINED_VARIANT", m.method, msg);
        for (m.args) |a| _ = try self.inferExpr(a, null);
        return null;
    };
    const enum_ty = try types.mkNamed(self.arena, enum_name, m.receiver.span());
    if (m.args.len != variant.payload.len) {
        const suffix: []const u8 = if (variant.payload.len == 1) "" else "s";
        const msg = try std.fmt.allocPrint(
            self.arena,
            "variant `{s}.{s}` takes {d} argument{s}, called with {d}",
            .{ enum_name, variant_name, variant.payload.len, suffix, m.args.len },
        );
        try self.emitSpan("E_TYPE_ARG_COUNT", m.span, msg);
        for (m.args) |a| _ = try self.inferExpr(a, null);
        return enum_ty;
    }
    for (m.args, variant.payload) |arg, pf| {
        const field_ty = try type_resolve.resolveType(self, pf.type_ann);
        const arg_ty = try self.inferExpr(arg, field_ty);
        if (arg_ty) |at| try self.checkStoreCompat(arg.span(), field_ty, at);
    }
    return enum_ty;
}

/// Type-check `mem.X(args)` as a method-call expression
/// (delegates to `typecheck/mem_builtin.zig`).
pub fn checkMemMethodCall(self: *Checker, m: ast.MethodCallExpr) WalkError!?*const types.Type {
    return mem_builtin.checkMemMethodCall(self, m);
}

/// Resolve `mem.X` builtin field expressions (delegates to
/// `typecheck/mem_builtin.zig`).
pub fn resolveMemBuiltin(self: *Checker, f: ast.FieldExpr) WalkError!?*const types.Type {
    return mem_builtin.resolveMemBuiltin(self, f);
}

/// Look up `f.field` against the receiver's named-type decl.
/// Returns the field's declared type, or emits
/// `E_TYPE_UNDEFINED_FIELD` when the field is unknown. Returns
/// `null` when the receiver type isn't a resolvable named
/// struct / class — downstream callers treat that as "unknown
/// for now" rather than another error.
pub fn resolveFieldAccess(
    self: *Checker,
    f: ast.FieldExpr,
    recv_ty: ?*const types.Type,
) WalkError!?*const types.Type {
    const rt = recv_ty orelse return null;
    const named_name = flow.namedNameOf(rt.*) orelse return null;
    const field_name = self.lexeme(f.field);
    if (self.struct_registry.get(named_name)) |sd| {
        for (sd.fields) |fld| {
            if (std.mem.eql(u8, self.lexeme(fld.name), field_name)) {
                return try type_resolve.resolveType(self, fld.type_ann);
            }
        }
        try emitUndefinedField(self, named_name, field_name, f.field);
        return null;
    }
    if (self.class_registry.get(named_name)) |cd| {
        if (lookupClassFieldOwner(self, cd, field_name)) |hit| {
            if (annotations.hasAnnotation(self, hit.field.annotations, "private")) {
                const owner_name = self.lexeme(hit.owner.name);
                const visible = if (self.current_class_name) |cn| std.mem.eql(u8, cn, owner_name) else false;
                if (!visible) {
                    const msg = try std.fmt.allocPrint(
                        self.arena,
                        "field `{s}.{s}` is `@private` — only accessible from inside `{s}`",
                        .{ named_name, field_name, owner_name },
                    );
                    try self.emitSpan("E_PRIVATE_ACCESS", f.field, msg);
                }
            }
            if (hit.field.type_ann) |t| return try type_resolve.resolveType(self, t);
            return null;
        }
        try emitUndefinedField(self, named_name, field_name, f.field);
        return null;
    }
    return null;
}

/// Walk a class's inherited chain looking for a field named
/// `field_name`. Returns the resolved type when found.
pub fn lookupClassFieldType(
    self: *Checker,
    cd: *const ast.ClassDecl,
    field_name: []const u8,
) WalkError!?*const types.Type {
    for (cd.fields) |fld| {
        if (std.mem.eql(u8, self.lexeme(fld.name), field_name)) {
            if (fld.type_ann) |t| return try type_resolve.resolveType(self, t);
            return null;
        }
    }
    if (cd.extends) |ext| if (self.class_registry.get(self.lexeme(ext))) |parent| {
        return try lookupClassFieldType(self, parent, field_name);
    };
    return null;
}

/// Emit `E_TYPE_UNDEFINED_FIELD` for a missing struct / class
/// field access. Suggests a near-spelling field name when one
/// exists (Levenshtein, distance ≤ 2) and attaches the owning
/// type's declaration span as the secondary anchor.
pub fn emitUndefinedField(self: *Checker, type_name: []const u8, field_name: []const u8, span: ast.Span) WalkError!void {
    const msg = try std.fmt.allocPrint(
        self.arena,
        "type `{s}` has no field `{s}`",
        .{ type_name, field_name },
    );
    // Suggestion across struct + class registries — whichever
    // resolves the type name supplies the field pool. Misses
    // (no candidate within distance 2, or unknown type) fall
    // through to the bare diagnostic. The same lookup yields
    // the type's declaration span, which doubles as the
    // secondary "type defined here" anchor.
    var candidate: ?[]const u8 = null;
    var type_decl_span: ?ast.Span = null;
    if (self.struct_registry.get(type_name)) |sd| {
        candidate = try self.suggestStructField(sd, field_name);
        type_decl_span = sd.name;
    } else if (self.class_registry.get(type_name)) |cd| {
        candidate = try self.suggestClassField(cd, field_name);
        type_decl_span = cd.name;
    }
    const help: ?[]const u8 = if (candidate) |c|
        try std.fmt.allocPrint(self.arena, "did you mean `{s}`?", .{c})
    else
        null;
    const secondary: []const diag_mod.SpanLabel = if (type_decl_span) |ts|
        try self.singleSecondary(ts, try std.fmt.allocPrint(self.arena, "type `{s}` defined here", .{type_name}), .underline)
    else
        &.{};
    try self.diagnostics.append(self.diag_alloc, .{
        .severity = .fatal,
        .code = "E_TYPE_UNDEFINED_FIELD",
        .message = msg,
        .span = span,
        .help = help,
        .secondary = secondary,
    });
}

/// Type-check a method call against the class registry.
/// Walks args regardless so unrelated diagnostics still fire.
/// Emits `E_TYPE_UNDEFINED_METHOD` when the named method is
/// missing on the receiver class. Otherwise behaves like a
/// regular call: arity + per-arg type check against the method's
/// signature.
pub fn checkMethodCall(
    self: *Checker,
    m: ast.MethodCallExpr,
    recv_ty: ?*const types.Type,
) WalkError!?*const types.Type {
    const rt = recv_ty orelse {
        for (m.args) |a| _ = try self.inferExpr(a, null);
        return null;
    };
    const named_name = flow.namedNameOf(rt.*) orelse {
        for (m.args) |a| _ = try self.inferExpr(a, null);
        return null;
    };
    const cd = self.class_registry.get(named_name) orelse {
        for (m.args) |a| _ = try self.inferExpr(a, null);
        return null;
    };
    const method_name = self.lexeme(m.method);
    const hit = lookupClassMethodOwner(self, cd, method_name) orelse {
        const msg = try std.fmt.allocPrint(
            self.arena,
            "class `{s}` has no method `{s}`",
            .{ named_name, method_name },
        );
        try self.emitSpanWithSuggestion("E_TYPE_UNDEFINED_METHOD", m.method, msg, try self.suggestClassMethod(cd, method_name));
        for (m.args) |a| _ = try self.inferExpr(a, null);
        return null;
    };
    const method = hit.method;
    if (annotations.hasAnnotation(self, method.annotations, "static")) {
        const msg = try std.fmt.allocPrint(
            self.arena,
            "`{s}.{s}` is `@static` — call it as `{s}.{s}(...)`, not on an instance",
            .{ named_name, method_name, named_name, method_name },
        );
        try self.emitSpan("E_STATIC_ON_INSTANCE", m.method, msg);
        for (m.args) |a| _ = try self.inferExpr(a, null);
        if (method.ret_type) |r| return try type_resolve.resolveType(self, r);
        return try self.primitive(.nil_);
    }
    if (annotations.hasAnnotation(self, method.annotations, "private")) {
        const owner_name = self.lexeme(hit.owner.name);
        const visible = if (self.current_class_name) |cn| std.mem.eql(u8, cn, owner_name) else false;
        if (!visible) {
            const msg = try std.fmt.allocPrint(
                self.arena,
                "method `{s}.{s}` is `@private` — only callable from inside `{s}`",
                .{ named_name, method_name, owner_name },
            );
            try self.emitSpan("E_PRIVATE_ACCESS", m.method, msg);
        }
    }
    // A variadic method pivots to the homogeneous-args / arity rules
    // (§4.6.2) — it's statically dispatched to its owner, so route here
    // before the fixed-arity check below.
    if (class_check.isVariadicDef(method.*)) {
        return try calls.checkVariadicMethodCall(self, m, method, self.lexeme(hit.owner.name));
    }

    // Build the method signature on the fly. Skip the `self`
    // param when matching args.
    var has_self = false;
    if (method.params.len > 0 and std.mem.eql(u8, self.lexeme(method.params[0].name), "self")) has_self = true;
    const skip_count: usize = if (has_self) 1 else 0;
    const sig_params = method.params[skip_count..];
    if (m.args.len != sig_params.len) {
        const suffix: []const u8 = if (sig_params.len == 1) "" else "s";
        const msg = try std.fmt.allocPrint(
            self.arena,
            "method `{s}.{s}` takes {d} argument{s}, called with {d}",
            .{ named_name, method_name, sig_params.len, suffix, m.args.len },
        );
        try self.emitSpan("E_TYPE_ARG_COUNT", m.span, msg);
        for (m.args) |a| _ = try self.inferExpr(a, null);
    } else {
        for (m.args, sig_params) |arg, p| {
            const param_ty: ?*const types.Type = if (p.type_ann) |t|
                try type_resolve.resolveType(self, t)
            else
                null;
            const skip = if (param_ty) |pt| predicates.isNilType(pt.*) else true;
            const arg_ty = try self.inferExpr(arg, if (skip) null else param_ty);
            if (!skip and param_ty != null and arg_ty != null) {
                try self.checkStoreCompat(arg.span(), param_ty.?, arg_ty.?);
            }
        }
    }
    if (method.ret_type) |r| return try type_resolve.resolveType(self, r);
    return try self.primitive(.nil_);
}

/// Type-check a `@static` method call `ClassName.method(args)` (§3.7) —
/// the receiver is a class *name*, not an instance, so there's no `self`.
/// Resolves the method, requires it be `@static`, checks the args, and
/// (for a variadic `@static` method) records its per-arity facts. Returns
/// the method's return type.
pub fn checkStaticMethodCall(
    self: *Checker,
    m: ast.MethodCallExpr,
    cd: *const ast.ClassDecl,
    class_name: []const u8,
) WalkError!?*const types.Type {
    const method_name = self.lexeme(m.method);
    const hit = lookupClassMethodOwner(self, cd, method_name) orelse {
        const msg = try std.fmt.allocPrint(self.arena, "class `{s}` has no method `{s}`", .{ class_name, method_name });
        try self.emitSpanWithSuggestion("E_TYPE_UNDEFINED_METHOD", m.method, msg, try self.suggestClassMethod(cd, method_name));
        for (m.args) |a| _ = try self.inferExpr(a, null);
        return null;
    };
    const method = hit.method;
    if (!annotations.hasAnnotation(self, method.annotations, "static")) {
        const msg = try std.fmt.allocPrint(
            self.arena,
            "`{s}.{s}` is an instance method — call it on an instance, not on the class name",
            .{ class_name, method_name },
        );
        try self.emitSpan("E_INSTANCE_AS_STATIC", m.method, msg);
        for (m.args) |a| _ = try self.inferExpr(a, null);
        return null;
    }
    // A variadic `@static` method records + monomorphizes like any other
    // (it has no `self`, which `checkVariadicMethodCall` already handles).
    if (class_check.isVariadicDef(method.*)) {
        return try calls.checkVariadicMethodCall(self, m, method, self.lexeme(hit.owner.name));
    }
    // Fixed-arity: every param is a user arg. A `@static` method takes no
    // `self` (E_STATIC_HAS_SELF flags it at the decl); skip an illegal one
    // here so the count reflects user args rather than cascading.
    const has_self = method.params.len > 0 and std.mem.eql(u8, self.lexeme(method.params[0].name), "self");
    const skip_count: usize = if (has_self) 1 else 0;
    const sig_params = method.params[skip_count..];
    if (m.args.len != sig_params.len) {
        const suffix: []const u8 = if (sig_params.len == 1) "" else "s";
        const msg = try std.fmt.allocPrint(
            self.arena,
            "`{s}.{s}` takes {d} argument{s}, called with {d}",
            .{ class_name, method_name, sig_params.len, suffix, m.args.len },
        );
        try self.emitSpan("E_TYPE_ARG_COUNT", m.span, msg);
        for (m.args) |a| _ = try self.inferExpr(a, null);
    } else {
        for (m.args, sig_params) |arg, p| {
            const param_ty: ?*const types.Type = if (p.type_ann) |t| try type_resolve.resolveType(self, t) else null;
            const skip = if (param_ty) |pt| predicates.isNilType(pt.*) else true;
            const arg_ty = try self.inferExpr(arg, if (skip) null else param_ty);
            if (!skip and param_ty != null and arg_ty != null) {
                try self.checkStoreCompat(arg.span(), param_ty.?, arg_ty.?);
            }
        }
    }
    if (method.ret_type) |r| return try type_resolve.resolveType(self, r);
    return try self.primitive(.nil_);
}

/// Validate a struct literal against its decl. Reports
/// unknown / missing / mistyped fields and returns the named
/// type so the surrounding expression continues to type-check.
pub fn checkStructLit(self: *Checker, sl: ast.StructLit) WalkError!?*const types.Type {
    const type_name = self.lexeme(sl.type_name);
    const named_ty = try types.mkNamed(self.arena, type_name, sl.type_name);

    // Struct literals can be used to construct classes too
    // (`Player { name: "Cecil" }` shorthand) — try both
    // registries.
    if (self.struct_registry.get(type_name)) |sd| {
        try checkStructLitFields(self, sl, type_name, sd.fields);
        return named_ty;
    }
    if (self.class_registry.get(type_name)) |cd| {
        try checkClassLitFields(self, sl, type_name, cd);
        return named_ty;
    }
    // Unknown type — emit the standard undefined-type code so
    // the user gets one consistent diagnostic, then walk the
    // values defensively to surface inner errors.
    const msg = try std.fmt.allocPrint(
        self.arena,
        "undefined type `{s}`",
        .{type_name},
    );
    try self.emitSpanWithSuggestion("E_TYPE_UNDEFINED", sl.type_name, msg, try self.suggestTypeName(type_name));
    for (sl.fields) |f| _ = try self.inferExpr(f.value, null);
    return named_ty;
}

fn checkStructLitFields(
    self: *Checker,
    sl: ast.StructLit,
    type_name: []const u8,
    decl_fields: []const ast.StructField,
) WalkError!void {
    var seen: std.StringHashMapUnmanaged(void) = .{};
    defer seen.deinit(self.arena);
    for (sl.fields) |lit_field| {
        const field_name = self.lexeme(lit_field.name);
        const decl_field = flow.findStructField(self, decl_fields, field_name) orelse {
            try emitUndefinedField(self, type_name, field_name, lit_field.name);
            _ = try self.inferExpr(lit_field.value, null);
            continue;
        };
        const expected_ty = try type_resolve.resolveType(self, decl_field.type_ann);
        const actual_ty = try self.inferExpr(lit_field.value, expected_ty);
        if (actual_ty) |at| try self.checkStoreCompat(lit_field.value.span(), expected_ty, at);
        _ = try seen.put(self.arena, field_name, {});
    }
    // Missing fields.
    for (decl_fields) |df| {
        const dn = self.lexeme(df.name);
        if (!seen.contains(dn)) {
            const msg = try std.fmt.allocPrint(
                self.arena,
                "missing field `{s}` in `{s}` literal",
                .{ dn, type_name },
            );
            try self.emitSpan("E_TYPE_MISSING_FIELD", sl.span, msg);
        }
    }
}

fn checkClassLitFields(
    self: *Checker,
    sl: ast.StructLit,
    type_name: []const u8,
    cd: *const ast.ClassDecl,
) WalkError!void {
    for (sl.fields) |lit_field| {
        const field_name = self.lexeme(lit_field.name);
        // Search the inheritance chain. Class fields are
        // optional-typed, so an untyped field accepts anything.
        const expected_ty: ?*const types.Type = try lookupClassFieldType(self, cd, field_name);
        if (expected_ty == null and flow.findClassField(self, cd, field_name) == null) {
            try emitUndefinedField(self, type_name, field_name, lit_field.name);
            _ = try self.inferExpr(lit_field.value, null);
            continue;
        }
        const actual_ty = try self.inferExpr(lit_field.value, expected_ty);
        if (expected_ty) |et| if (actual_ty) |at| try self.checkStoreCompat(lit_field.value.span(), et, at);
    }
    // Class literals don't require every field to be set
    // (constructors fill defaults). Slice 7 may tighten this
    // when annotation rules pin field requiredness.
}

/// Synthesize a constructor signature for a class. Uses the
/// `init` method's params (sans implicit `self`) when present;
/// otherwise the constructor is nullary. Return type is always
/// `Named(class_name)`.
pub fn constructorSignatureFor(
    self: *Checker,
    cd: *const ast.ClassDecl,
    class_name: []const u8,
    name_span: ast.Span,
) WalkError!*const types.Type {
    var param_types: std.ArrayList(*const types.Type) = .empty;
    errdefer param_types.deinit(self.arena);
    if (lookupClassMethod(self, cd, "init")) |init_method| {
        var has_self = false;
        if (init_method.params.len > 0 and std.mem.eql(u8, self.lexeme(init_method.params[0].name), "self")) has_self = true;
        const skip: usize = if (has_self) 1 else 0;
        for (init_method.params[skip..]) |p| {
            const pt: *const types.Type = if (p.type_ann) |t|
                try type_resolve.resolveType(self, t)
            else
                try self.primitive(.nil_);
            try param_types.append(self.arena, pt);
        }
    }
    const ret = try types.mkNamed(self.arena, class_name, name_span);
    const sig = try self.arena.create(types.Type);
    sig.* = .{ .function = .{
        .params = try param_types.toOwnedSlice(self.arena),
        .ret = ret,
    } };
    return sig;
}

/// Walk a class's inheritance chain looking for a method by
/// name. Returns the first match.
pub fn lookupClassMethod(
    self: *const Checker,
    cd: *const ast.ClassDecl,
    method_name: []const u8,
) ?*const ast.DefDecl {
    if (lookupClassMethodOwner(self, cd, method_name)) |hit| return hit.method;
    return null;
}

/// Result of `lookupClassMethodOwner` — the method decl plus the
/// class that owns it (needed for `@private` visibility checks).
pub const MethodHit = struct {
    method: *const ast.DefDecl,
    owner: *const ast.ClassDecl,
};

/// Walk a class's inheritance chain looking for a method by
/// name and return both the method decl and the class that
/// owns it.
pub fn lookupClassMethodOwner(
    self: *const Checker,
    cd: *const ast.ClassDecl,
    method_name: []const u8,
) ?MethodHit {
    for (cd.methods) |*method| {
        if (std.mem.eql(u8, self.lexeme(method.name), method_name)) {
            return .{ .method = method, .owner = cd };
        }
    }
    if (cd.extends) |ext| if (self.class_registry.get(self.lexeme(ext))) |parent| {
        return lookupClassMethodOwner(self, parent, method_name);
    };
    return null;
}

/// Result of `lookupClassFieldOwner` — the field decl plus the
/// class that owns it.
pub const FieldHit = struct {
    field: *const ast.ClassField,
    owner: *const ast.ClassDecl,
};

/// Walk a class's inheritance chain looking for a field by
/// name and return both the field decl and the owning class.
pub fn lookupClassFieldOwner(
    self: *const Checker,
    cd: *const ast.ClassDecl,
    field_name: []const u8,
) ?FieldHit {
    for (cd.fields) |*fld| {
        if (std.mem.eql(u8, self.lexeme(fld.name), field_name)) {
            return .{ .field = fld, .owner = cd };
        }
    }
    if (cd.extends) |ext| if (self.class_registry.get(self.lexeme(ext))) |parent| {
        return lookupClassFieldOwner(self, parent, field_name);
    };
    return null;
}
