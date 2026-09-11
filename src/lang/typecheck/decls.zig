const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const scope_mod = @import("../scope.zig");
const typecheck = @import("../typecheck.zig");
const type_resolve = @import("type_resolve.zig");
const stdlib = @import("stdlib.zig");

const Checker = typecheck.Checker;
const WalkError = error{OutOfMemory};

// Pass 1: register every top-level name (let / const / def / class /
// struct / enum / use) into the module scope before Pass 2 resolves
// bodies, so forward references type-check.

/// Register one top-level statement's name(s) into the module
/// scope (Pass 1), so Pass 2 can resolve forward references.
pub fn registerTopLevel(self: *Checker, s: ast.Statement) WalkError!void {
    switch (s) {
        .let_decl => |d| try registerLetPattern(self, d.pattern, .let_binding, d.type_ann),
        .const_decl => |d| try registerName(
            self,
            self.lexeme(d.name),
            .{ .kind = .const_binding, .decl_span = d.name, .ty = null },
        ),
        .def_decl => |d| {
            const sig = try signatureFromDef(self, d);
            try registerName(self, self.lexeme(d.name), .{
                .kind = .function,
                .decl_span = d.name,
                .ty = sig,
            });
        },
        .class_decl => |d| try registerName(self, self.lexeme(d.name), .{
            .kind = .class,
            .decl_span = d.name,
            .ty = null,
        }),
        .struct_decl => |d| try registerName(self, self.lexeme(d.name), .{
            .kind = .struct_,
            .decl_span = d.name,
            .ty = null,
        }),
        .enum_decl => |d| try registerName(self, self.lexeme(d.name), .{
            .kind = .enum_,
            .decl_span = d.name,
            .ty = null,
        }),
        .use_decl => |d| try registerUseDecl(self, d),
        else => {},
    }
}

fn registerLetPattern(
    self: *Checker,
    pat: *const ast.Pattern,
    kind: scope_mod.SymbolKind,
    type_ann: ?*const ast.TypeAnn,
) WalkError!void {
    // Only the simple `let name = …` form registers a single
    // symbol here. Tuple / struct destructuring registers each
    // bound name in pass 2 (where the rhs type is known).
    switch (pat.*) {
        .ident => |i| {
            const ty: ?*const types.Type = if (type_ann) |t|
                try type_resolve.resolveType(self, t)
            else
                null;
            try registerName(self, self.lexeme(i.name), .{
                .kind = kind,
                .decl_span = i.name,
                .ty = ty,
            });
        },
        else => {
            // Destructuring patterns will register their inner
            // names during pass 2 when the type is known.
        },
    }
}

fn registerUseDecl(self: *Checker, d: ast.UseDecl) WalkError!void {
    if (d.items.len > 0) {
        // `use a [as al], b [as bl] from module` — each item
        // becomes its own imported symbol.
        const module = self.lexeme(d.module);
        const from_stdlib = stdlib.isModule(module);
        for (d.items) |it| {
            const orig = self.lexeme(it.name);
            const name = if (it.alias) |a| self.lexeme(a) else orig;
            try registerName(self, name, .{
                .kind = .imported,
                .decl_span = it.name,
                .ty = null,
            });
            // A stdlib selective import records its origin so a bare
            // call (`rng()` after `use rng from math`) lowers like the
            // qualified `math.rng()` form — and the member must exist,
            // surfaced here rather than only at a call site.
            if (from_stdlib) {
                if (stdlib.isMember(module, orig)) {
                    try self.selective_stdlib.put(self.arena, name, .{ .module = module, .name = orig });
                } else {
                    const msg = try std.fmt.allocPrint(self.arena, "stdlib module `{s}` has no member `{s}`", .{ module, orig });
                    try self.emitSpan("E_TYPE_UNDEFINED_METHOD", it.name, msg);
                }
            }
        }
    } else {
        // Whole-module import — register the alias (or the
        // module lexeme itself if no alias).
        const name = if (d.alias) |a| self.lexeme(a) else self.lexeme(d.module);
        try registerName(self, name, .{
            .kind = .module_alias,
            .decl_span = d.module,
            .ty = null,
        });
    }
}

/// Insert `name` into the current scope with its kind + type,
/// reporting `E_TYPE_REDEFINED` on a clash and rejecting names that
/// shadow a reserved builtin.
pub fn registerName(
    self: *Checker,
    name: []const u8,
    info: scope_mod.SymbolInfo,
) WalkError!void {
    if (isReservedBuiltinName(name)) {
        const msg = try std.fmt.allocPrint(
            self.arena,
            "cannot shadow always-in-scope builtin `{s}`",
            .{name},
        );
        try self.emitSpan("E_BUILTIN_SHADOW", info.decl_span, msg);
        return;
    }
    // Record the binder's type by declaration site. A destructured
    // binder has no expression of its own, so `expr_types` can't
    // answer for it; codegen reads this map instead.
    if (info.ty) |t| try self.binder_types.put(self.arena, info.decl_span.start, t);
    self.current_scope.define(name, info) catch |err| switch (err) {
        error.AlreadyDefined => {
            const existing = self.current_scope.lookupLocal(name).?;
            const msg = try std.fmt.allocPrint(
                self.arena,
                "`{s}` is already defined in this scope",
                .{name},
            );
            const sec = try self.singleSecondary(existing.decl_span, "previous definition here", .underline);
            try self.diagnostics.append(self.diag_alloc, .{
                .severity = .fatal,
                .code = "E_TYPE_REDEFINED",
                .message = msg,
                .span = info.decl_span,
                .secondary = sec,
            });
            return;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    // Track function-body locals for the `return &local`
    // stack-lifetime check. `null` at module / class scope.
    if (self.fn_locals) |*set| {
        _ = try set.put(self.arena, name, {});
    }
    // Track lambda-body locals for the `@no_capture`
    // capture-mutation check. `null` outside a tracked lambda.
    if (self.lambda_locals) |*set| {
        _ = try set.put(self.arena, name, {});
    }
}

/// Build the function-pointer type for a `def`. Unannotated
/// params produce a `nil` placeholder slot (treated as "skip
/// arg-type check" by `checkCall`).
pub fn signatureFromDef(self: *Checker, d: ast.DefDecl) WalkError!*const types.Type {
    var param_types: std.ArrayList(*const types.Type) = .empty;
    errdefer param_types.deinit(self.arena);
    for (d.params) |p| {
        // `self` carries no annotation and needs none: its type is
        // the class the method is declared in, which is known from
        // context rather than from a call site. A variadic parameter
        // is the other legitimately unannotated form — the `variadic`
        // flag is what carries its intent.
        const is_self = std.mem.eql(u8, self.lexeme(p.name), "self");
        if (p.type_ann == null and !p.variadic and !is_self) {
            // Without an annotation there is nothing to compare an
            // argument against, so every call would type-check by
            // default — the one place the language would promise less
            // than it appears to.
            const msg = try std.fmt.allocPrint(
                self.arena,
                "parameter `{s}` needs a type — write `{s}: i16` or whichever type it takes",
                .{ self.lexeme(p.name), self.lexeme(p.name) },
            );
            try self.emitSpan("E_TYPE_PARAM_UNANNOTATED", p.name, msg);
        }
        const pt: *const types.Type = if (p.type_ann) |t|
            try type_resolve.resolveType(self, t)
        else
            try self.primitive(.nil_);
        try param_types.append(self.arena, pt);
    }
    const ret_ty: *const types.Type = if (d.ret_type) |r|
        try type_resolve.resolveType(self, r)
    else
        try self.primitive(.nil_);
    const sig = try self.arena.create(types.Type);
    sig.* = .{ .function = .{
        .params = try param_types.toOwnedSlice(self.arena),
        .ret = ret_ty,
    } };
    return sig;
}

/// `true` when `name` is an always-in-scope builtin per spec §5.3.
/// User declarations matching these names get `E_BUILTIN_SHADOW`.
/// `sizeof` is a keyword and rejected by the parser before reaching
/// here.
fn isReservedBuiltinName(name: []const u8) bool {
    const reserved = [_][]const u8{
        "assert",
        "debug_assert",
        "panic",
        // allow-strict: lang builtin name; the Zig keyword sense doesn't apply on this line.
        "unreachable",
        "todo",
    };
    for (reserved) |kw| if (std.mem.eql(u8, name, kw)) return true;
    return false;
}
