/// Gero-lang typechecker — resolution + basic inference slice.
///
/// Two passes over the AST:
///   1. Top-level decl registration — every module-scope `let` /
///      `const` / `def` / `class` / `struct` / `enum` / `use` lands
///      in the module scope before walking, so forward references
///      across the file resolve cleanly.
///   2. Resolution + inference — walk every statement, resolve
///      `NamedType` and `Expr.ident` against the scope chain, infer
///      `let` / `const` initializer types, register `def` parameters
///      in their function scope, check explicit type-vs-init
///      assignability.
///
/// Subsequent slices add operator / call / assignment type checking,
/// nullable / reference / match / annotation / bake / cast / varargs
/// rules, and the rendered-diagnostic shape from
/// `docs/lang-diagnostics.md`.
const std = @import("std");
const knit = @import("knit");
const core = knit.core;

const ast = @import("ast.zig");
const types = @import("types.zig");
const scope_mod = @import("scope.zig");
const Scope = scope_mod.Scope;

/// Typechecker output. Owns the diagnostics slice and the arena that
/// allocated every `*Type` plus the scope tree.
pub const CheckedProgram = struct {
    program: *const ast.Program,
    diagnostics: []core.ParseError,
    type_arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    /// Release the diagnostics slice and the `*Type` arena.
    pub fn deinit(self: *CheckedProgram) void {
        self.allocator.free(self.diagnostics);
        self.type_arena.deinit();
    }

    /// `true` when at least one fatal-severity diagnostic fired.
    pub fn hasErrors(self: CheckedProgram) bool {
        for (self.diagnostics) |d| if (d.severity == .fatal) return true;
        return false;
    }
};

/// Walk `program` through resolution + basic inference.
pub fn typecheck(
    allocator: std.mem.Allocator,
    source: []const u8,
    program: *const ast.Program,
) !CheckedProgram {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var diagnostics: std.ArrayList(core.ParseError) = .empty;
    errdefer diagnostics.deinit(allocator);

    var module_scope: Scope = .init(a, null);
    // No `defer deinit` — the arena releases the scope's map storage
    // when `CheckedProgram.deinit` runs.

    var c: Checker = .{
        .source = source,
        .arena = a,
        .diag_alloc = allocator,
        .diagnostics = &diagnostics,
        .module_scope = &module_scope,
        .current_scope = &module_scope,
    };

    // Pass 1: register top-level decls so forward references resolve.
    for (program.statements) |stmt| try c.registerTopLevel(stmt);

    // Pass 2: walk + resolve + infer.
    for (program.statements) |stmt| try c.walkStatement(stmt);

    return .{
        .program = program,
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
        .type_arena = arena,
        .allocator = allocator,
    };
}

const Checker = struct {
    source: []const u8,
    arena: std.mem.Allocator,
    /// Allocator used for the diagnostics ArrayList — must match the
    /// allocator the caller releases the slice with later.
    /// Diagnostic message strings still live in `arena`.
    diag_alloc: std.mem.Allocator,
    diagnostics: *std.ArrayList(core.ParseError),
    /// The outermost (module) scope.
    module_scope: *Scope,
    /// The currently-active scope. Walker entry into a function /
    /// class / block sets this to a fresh child and restores on exit.
    current_scope: *Scope,

    /// Mutually recursive walker fns need an explicit error set —
    /// Zig's inferred sets would deadlock the dependency graph.
    const WalkError = error{OutOfMemory};

    // ---------- diagnostic helpers ----------

    fn emit(
        self: *Checker,
        code: []const u8,
        index: u32,
        message: []const u8,
        actual: ?[]const u8,
    ) WalkError!void {
        try self.diagnostics.append(self.diag_alloc, core.parseError(
            "lang_typecheck",
            index,
            message,
            .{ .expected = code, .actual = actual, .kind = .semantic },
        ));
    }

    fn emitMismatch(
        self: *Checker,
        span: ast.Span,
        expected_ty: *const types.Type,
        actual_ty: *const types.Type,
    ) WalkError!void {
        const expected_s = try types.render(self.arena, expected_ty.*);
        const actual_s = try types.render(self.arena, actual_ty.*);
        const msg = try std.fmt.allocPrint(
            self.arena,
            "type mismatch: expected `{s}`, found `{s}`",
            .{ expected_s, actual_s },
        );
        try self.emit("E_TYPE_MISMATCH", span.start, msg, null);
    }

    fn lexeme(self: *const Checker, span: ast.Span) []const u8 {
        return self.source[span.start..span.end];
    }

    // ---------- Pass 1: top-level decl registration ----------

    fn registerTopLevel(self: *Checker, s: ast.Statement) WalkError!void {
        switch (s) {
            .let_decl => |d| try self.registerLetPattern(d.pattern, .let_binding, d.type_ann),
            .const_decl => |d| try self.registerName(
                self.lexeme(d.name),
                .{ .kind = .const_binding, .decl_span = d.name, .ty = null },
            ),
            .def_decl => |d| {
                const sig = try self.signatureFromDef(d);
                try self.registerName(self.lexeme(d.name), .{
                    .kind = .function,
                    .decl_span = d.name,
                    .ty = sig,
                });
            },
            .class_decl => |d| try self.registerName(self.lexeme(d.name), .{
                .kind = .class,
                .decl_span = d.name,
                .ty = null,
            }),
            .struct_decl => |d| try self.registerName(self.lexeme(d.name), .{
                .kind = .struct_,
                .decl_span = d.name,
                .ty = null,
            }),
            .enum_decl => |d| try self.registerName(self.lexeme(d.name), .{
                .kind = .enum_,
                .decl_span = d.name,
                .ty = null,
            }),
            .use_decl => |d| try self.registerUseDecl(d),
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
                    try self.resolveType(t)
                else
                    null;
                try self.registerName(self.lexeme(i.name), .{
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
            for (d.items) |it| {
                const name = if (it.alias) |a| self.lexeme(a) else self.lexeme(it.name);
                try self.registerName(name, .{
                    .kind = .imported,
                    .decl_span = it.name,
                    .ty = null,
                });
            }
        } else {
            // Whole-module import — register the alias (or the
            // module lexeme itself if no alias).
            const name = if (d.alias) |a| self.lexeme(a) else self.lexeme(d.module);
            try self.registerName(name, .{
                .kind = .module_alias,
                .decl_span = d.module,
                .ty = null,
            });
        }
    }

    fn registerName(
        self: *Checker,
        name: []const u8,
        info: scope_mod.SymbolInfo,
    ) WalkError!void {
        self.current_scope.define(name, info) catch |err| switch (err) {
            error.AlreadyDefined => {
                const existing = self.current_scope.lookupLocal(name).?;
                const msg = try std.fmt.allocPrint(
                    self.arena,
                    "`{s}` is already defined in this scope",
                    .{name},
                );
                try self.emit("E_TYPE_REDEFINED", info.decl_span.start, msg, name);
                _ = existing;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    /// Build the function-pointer type for a `def` from its
    /// annotations. Params and return without explicit type produce
    /// a `nil` placeholder slot — slice 3 (call-site inference) may
    /// refine those.
    fn signatureFromDef(self: *Checker, d: ast.DefDecl) WalkError!*const types.Type {
        var param_types: std.ArrayList(*const types.Type) = .empty;
        errdefer param_types.deinit(self.arena);
        for (d.params) |p| {
            const pt: *const types.Type = if (p.type_ann) |t|
                try self.resolveType(t)
            else
                try self.primitive(.nil_); // unknown until call-site inference
            try param_types.append(self.arena, pt);
        }
        const ret_ty: *const types.Type = if (d.ret_type) |r|
            try self.resolveType(r)
        else
            try self.primitive(.nil_);
        const sig = try self.arena.create(types.Type);
        sig.* = .{ .function = .{
            .params = try param_types.toOwnedSlice(self.arena),
            .ret = ret_ty,
        } };
        return sig;
    }

    // ---------- Pass 2: resolution + inference ----------

    fn walkStatement(self: *Checker, s: ast.Statement) WalkError!void {
        switch (s) {
            .let_decl => |d| try self.checkLetDecl(d),
            .const_decl => |d| try self.checkConstDecl(d),
            .assign => |a| {
                try self.walkExpr(a.target);
                try self.walkExpr(a.value);
            },
            .inc_dec => |id| try self.walkExpr(id.target),
            .discard => |d| try self.walkExpr(d.expr),
            .expr_stmt => |es| try self.walkExpr(es.expr),
            .block => |b| try self.walkInScope(b.body),
            .if_stmt => |is_| try self.checkIfChain(is_.arms, is_.else_body),
            .while_stmt => |ws| try self.checkWhile(ws),
            .for_stmt => |fs| try self.checkFor(fs),
            .repeat_stmt => |rs| try self.checkRepeat(rs),
            .match_stmt => |ms| try self.checkMatch(ms),
            .return_stmt => |rs| if (rs.value) |v| try self.walkExpr(v),
            .break_stmt, .continue_stmt => {},
            .print_stmt => |ps| for (ps.args) |a| try self.walkExpr(a),
            .def_decl => |d| try self.checkDefDecl(d),
            .class_decl => |c| try self.checkClassDecl(c),
            .struct_decl, .enum_decl, .use_decl, .local_decl, .asm_stmt => {},
            .defer_stmt => |ds| try self.walkStatement(ds.body.*),
            .unknown => {},
        }
    }

    fn walkInScope(self: *Checker, body: []const ast.Statement) WalkError!void {
        const saved = self.current_scope;
        var child: Scope = .init(self.arena, saved);
        self.current_scope = &child;
        defer self.current_scope = saved;
        for (body) |s| try self.walkStatement(s);
    }

    fn checkLetDecl(self: *Checker, d: ast.LetDecl) WalkError!void {
        // Resolve annotated type (if any) and infer init type.
        const ann_ty: ?*const types.Type = if (d.type_ann) |t|
            try self.resolveType(t)
        else
            null;
        const init_ty: ?*const types.Type = if (d.init) |e|
            try self.inferExpr(e)
        else
            null;
        if (ann_ty != null and init_ty != null) {
            if (!ann_ty.?.eql(init_ty.?.*)) {
                try self.emitMismatch(d.init.?.span(), ann_ty.?, init_ty.?);
            }
        }
        // For ident patterns, update the scope entry's type.
        switch (d.pattern.*) {
            .ident => |i| {
                const ty = ann_ty orelse init_ty;
                if (ty) |t| {
                    self.current_scope.setType(self.lexeme(i.name), t) catch {
                        // Pattern wasn't registered during pass 1
                        // because we're inside a nested scope.
                        // Register now.
                        try self.registerName(self.lexeme(i.name), .{
                            .kind = .let_binding,
                            .decl_span = i.name,
                            .ty = t,
                        });
                    };
                } else {
                    // Pass 1 may not have registered this if we're
                    // in a nested scope; ensure presence.
                    if (self.current_scope.lookupLocal(self.lexeme(i.name)) == null) {
                        try self.registerName(self.lexeme(i.name), .{
                            .kind = .let_binding,
                            .decl_span = i.name,
                            .ty = null,
                        });
                    }
                }
            },
            else => {
                // Destructuring patterns: register each bound name
                // with `null` ty for now; slice 5 handles tuple /
                // struct destructure typing properly.
                try self.registerPatternBindings(d.pattern);
            },
        }
    }

    fn checkConstDecl(self: *Checker, d: ast.ConstDecl) WalkError!void {
        const ann_ty: ?*const types.Type = if (d.type_ann) |t|
            try self.resolveType(t)
        else
            null;
        const init_ty = try self.inferExpr(d.init);
        const final = ann_ty orelse init_ty;
        if (ann_ty != null and init_ty != null and !ann_ty.?.eql(init_ty.?.*)) {
            try self.emitMismatch(d.init.span(), ann_ty.?, init_ty.?);
        }
        if (final) |t| {
            self.current_scope.setType(self.lexeme(d.name), t) catch {
                try self.registerName(self.lexeme(d.name), .{
                    .kind = .const_binding,
                    .decl_span = d.name,
                    .ty = t,
                });
            };
        }
    }

    fn checkIfChain(
        self: *Checker,
        arms: []const ast.IfArm,
        else_body: ?[]const ast.Statement,
    ) WalkError!void {
        for (arms) |arm| {
            if (arm.cond) |c| try self.walkExpr(c);
            if (arm.let_expr) |e| try self.walkExpr(e);
            if (arm.let_guard) |g| try self.walkExpr(g);
            try self.walkInScope(arm.body);
        }
        if (else_body) |eb| try self.walkInScope(eb);
    }

    fn checkWhile(self: *Checker, ws: ast.WhileStmt) WalkError!void {
        if (ws.cond) |c| try self.walkExpr(c);
        if (ws.let_expr) |e| try self.walkExpr(e);
        if (ws.let_guard) |g| try self.walkExpr(g);
        try self.walkInScope(ws.body);
    }

    fn checkFor(self: *Checker, fs: ast.ForStmt) WalkError!void {
        try self.walkExpr(fs.iter);
        if (fs.step) |st| try self.walkExpr(st);
        const saved = self.current_scope;
        var child: Scope = .init(self.arena, saved);
        self.current_scope = &child;
        defer self.current_scope = saved;
        // Register the loop binding in the body's scope. Type left
        // null for slice 2 — slice 3 will infer from `iter`.
        try self.registerName(self.lexeme(fs.binding), .{
            .kind = .let_binding,
            .decl_span = fs.binding,
            .ty = null,
        });
        for (fs.body) |s| try self.walkStatement(s);
    }

    fn checkRepeat(self: *Checker, rs: ast.RepeatStmt) WalkError!void {
        try self.walkInScope(rs.body);
        try self.walkExpr(rs.cond);
    }

    fn checkMatch(self: *Checker, ms: ast.MatchStmt) WalkError!void {
        try self.walkExpr(ms.scrutinee);
        for (ms.arms) |arm| {
            const saved = self.current_scope;
            var child: Scope = .init(self.arena, saved);
            self.current_scope = &child;
            defer self.current_scope = saved;
            try self.registerPatternBindings(arm.pattern);
            if (arm.guard) |g| try self.walkExpr(g);
            for (arm.body) |s| try self.walkStatement(s);
        }
    }

    fn checkDefDecl(self: *Checker, d: ast.DefDecl) WalkError!void {
        const saved = self.current_scope;
        var fn_scope: Scope = .init(self.arena, saved);
        self.current_scope = &fn_scope;
        defer self.current_scope = saved;

        // Register params in the fn scope.
        for (d.params) |p| {
            const pt: ?*const types.Type = if (p.type_ann) |t|
                try self.resolveType(t)
            else
                null;
            try self.registerName(self.lexeme(p.name), .{
                .kind = .param,
                .decl_span = p.name,
                .ty = pt,
            });
        }

        // Recursive-return-annotation check: if the body references
        // the function name itself, the spec requires an explicit
        // `-> R`. Slice 2 implements the simple check; full
        // closure-self-reference detection awaits later passes.
        if (d.ret_type == null and self.bodyMentions(d.body, self.lexeme(d.name))) {
            const msg = try std.fmt.allocPrint(
                self.arena,
                "recursive function `{s}` needs an explicit return type",
                .{self.lexeme(d.name)},
            );
            try self.emit("E_TYPE_RECURSIVE_NO_RET", d.name.start, msg, self.lexeme(d.name));
        }

        for (d.body) |s| try self.walkStatement(s);
    }

    fn checkClassDecl(self: *Checker, d: ast.ClassDecl) WalkError!void {
        // Open a class scope so methods can see fields by name.
        const saved = self.current_scope;
        var class_scope: Scope = .init(self.arena, saved);
        self.current_scope = &class_scope;
        defer self.current_scope = saved;

        for (d.fields) |f| {
            const ty: ?*const types.Type = if (f.type_ann) |t|
                try self.resolveType(t)
            else
                null;
            try self.registerName(self.lexeme(f.name), .{
                .kind = .let_binding,
                .decl_span = f.name,
                .ty = ty,
            });
            if (f.init) |init_| try self.walkExpr(init_);
        }
        for (d.methods) |m| {
            const sig = try self.signatureFromDef(m);
            try self.registerName(self.lexeme(m.name), .{
                .kind = .function,
                .decl_span = m.name,
                .ty = sig,
            });
            try self.checkDefDecl(m);
        }
    }

    fn registerPatternBindings(self: *Checker, p: *const ast.Pattern) WalkError!void {
        switch (p.*) {
            .ident => |i| try self.registerName(self.lexeme(i.name), .{
                .kind = .let_binding,
                .decl_span = i.name,
                .ty = null,
            }),
            .tuple_pattern => |t| for (t.elems) |elem| try self.registerPatternBindings(elem),
            .variant_pattern => |v| for (v.args) |arg| try self.registerPatternBindings(arg),
            .struct_pattern => |st| for (st.fields) |f| try self.registerPatternBindings(f.sub),
            .or_pattern => |o| for (o.alts) |alt| try self.registerPatternBindings(alt),
            .wildcard, .int_lit, .str_lit, .char_lit, .bool_lit, .nil_lit, .range_pattern => {},
        }
    }

    fn bodyMentions(self: *const Checker, body: []const ast.Statement, name: []const u8) bool {
        for (body) |s| if (self.stmtMentions(s, name)) return true;
        return false;
    }

    fn stmtMentions(self: *const Checker, s: ast.Statement, name: []const u8) bool {
        return switch (s) {
            .let_decl => |d| if (d.init) |e| self.exprMentions(e, name) else false,
            .const_decl => |d| self.exprMentions(d.init, name),
            .assign => |a| self.exprMentions(a.target, name) or self.exprMentions(a.value, name),
            .inc_dec => |id| self.exprMentions(id.target, name),
            .discard => |d| self.exprMentions(d.expr, name),
            .expr_stmt => |es| self.exprMentions(es.expr, name),
            .block => |b| self.bodyMentions(b.body, name),
            .if_stmt => |is_| ifChainMentions(self, is_.arms, is_.else_body, name),
            .while_stmt => |ws| ((ws.cond != null and self.exprMentions(ws.cond.?, name)) or
                self.bodyMentions(ws.body, name)),
            .for_stmt => |fs| self.exprMentions(fs.iter, name) or self.bodyMentions(fs.body, name),
            .repeat_stmt => |rs| self.bodyMentions(rs.body, name) or self.exprMentions(rs.cond, name),
            .match_stmt => |ms| matchMentions(self, ms, name),
            .return_stmt => |rs| if (rs.value) |v| self.exprMentions(v, name) else false,
            .print_stmt => |ps| anyExprMentions(self, ps.args, name),
            .defer_stmt => |ds| self.stmtMentions(ds.body.*, name),
            else => false,
        };
    }

    fn exprMentions(self: *const Checker, e: *const ast.Expr, name: []const u8) bool {
        return switch (e.*) {
            .ident => |i| std.mem.eql(u8, self.lexeme(i.span), name),
            .paren => |p| self.exprMentions(p.inner, name),
            .unary => |u| self.exprMentions(u.operand, name),
            .binary => |b| self.exprMentions(b.lhs, name) or self.exprMentions(b.rhs, name),
            .range => |r| self.exprMentions(r.start, name) or self.exprMentions(r.end, name),
            .call => |c| self.exprMentions(c.callee, name) or anyExprMentions(self, c.args, name),
            .method_call => |m| self.exprMentions(m.receiver, name) or anyExprMentions(self, m.args, name),
            .field => |f| self.exprMentions(f.receiver, name),
            .index => |ix| self.exprMentions(ix.receiver, name) or self.exprMentions(ix.index, name),
            .do_expr => |d| self.bodyMentions(d.body, name),
            .if_expr => |ie| ifChainMentions(self, ie.arms, ie.else_body, name),
            .lambda => |l| self.bodyMentions(l.body, name),
            .list_lit => |ll| anyExprMentions(self, ll.elems, name),
            .list_repeat => |lr| self.exprMentions(lr.value, name) or self.exprMentions(lr.count, name),
            .struct_lit => |sl| structLitMentions(self, sl.fields, name),
            .tuple_lit => |tl| anyExprMentions(self, tl.elems, name),
            .is_test => |it| self.exprMentions(it.lhs, name),
            .cast => |c| self.exprMentions(c.inner, name),
            .ref_of => |r| self.exprMentions(r.inner, name),
            else => false,
        };
    }

    // ---------- type resolution ----------

    fn resolveType(self: *Checker, t: *const ast.TypeAnn) WalkError!*const types.Type {
        switch (t.*) {
            .named => |n| {
                const name = self.lexeme(n.name);
                if (types.primitiveFromName(name)) |p| {
                    return try self.primitive(p);
                }
                if (self.current_scope.lookup(name)) |_| {
                    return try types.mkNamed(self.arena, name, n.span);
                }
                const msg = try std.fmt.allocPrint(
                    self.arena,
                    "undefined type `{s}`",
                    .{name},
                );
                try self.emit("E_TYPE_UNDEFINED", n.name.start, msg, name);
                // Recover with an opaque named type so downstream
                // passes can keep going.
                return try types.mkNamed(self.arena, name, n.span);
            },
            .nullable => |n| {
                const inner = try self.resolveType(n.inner);
                return try types.mkOptional(self.arena, inner);
            },
            .array => |a| {
                const elem = try self.resolveType(a.elem);
                const len_val: u32 = if (a.len_expr.* == .int_lit)
                    // safety: parser stores array lengths as i32; §3.4 requires non-negative comptime int. Slice 3 will range-check; bit-cast preserves bytes.
                    @bitCast(a.len_expr.int_lit.value)
                else
                    0;
                return try types.mkArray(self.arena, elem, len_val);
            },
            .vec => |v| {
                const elem = try self.resolveType(v.elem);
                return try types.mkVec(self.arena, elem);
            },
            .tuple => |tu| {
                var elems: std.ArrayList(*const types.Type) = .empty;
                errdefer elems.deinit(self.arena);
                for (tu.elems) |e| try elems.append(self.arena, try self.resolveType(e));
                const out = try self.arena.create(types.Type);
                out.* = .{ .tuple = try elems.toOwnedSlice(self.arena) };
                return out;
            },
            .fn_type => |f| {
                var params: std.ArrayList(*const types.Type) = .empty;
                errdefer params.deinit(self.arena);
                for (f.params) |p| try params.append(self.arena, try self.resolveType(p));
                const ret: *const types.Type = if (f.ret) |r|
                    try self.resolveType(r)
                else
                    try self.primitive(.nil_);
                const out = try self.arena.create(types.Type);
                out.* = .{ .function = .{
                    .params = try params.toOwnedSlice(self.arena),
                    .ret = ret,
                } };
                return out;
            },
            .reference => |r| {
                const inner = try self.resolveType(r.inner);
                return try types.mkReference(self.arena, inner);
            },
        }
    }

    fn primitive(self: *Checker, p: types.Primitive) WalkError!*const types.Type {
        return try types.mkPrimitive(self.arena, p);
    }

    // ---------- expression walking + inference ----------

    fn walkExpr(self: *Checker, e: *const ast.Expr) WalkError!void {
        _ = try self.inferExpr(e);
    }

    /// Infer the type of an expression. Returns `null` for shapes
    /// slice 2 doesn't yet handle (binary op result types,
    /// function-call result types beyond direct ident, etc.).
    /// Subsequent slices replace those `null`s with concrete types.
    fn inferExpr(self: *Checker, e: *const ast.Expr) WalkError!?*const types.Type {
        switch (e.*) {
            .int_lit => return try self.primitive(.i16),
            .fixed_lit => return try self.primitive(.fixed),
            .bool_lit => return try self.primitive(.bool_),
            .nil_lit => return try self.primitive(.nil_),
            .char_lit => return try self.primitive(.u8),
            .str_lit => |s| {
                for (s.parts) |part| switch (part) {
                    .lit => {},
                    .interp => |ip| _ = try self.inferExpr(ip.expr),
                };
                return try self.primitive(.str);
            },
            .ident => |i| {
                const name = self.lexeme(i.span);
                if (self.current_scope.lookup(name)) |info| return info.ty;
                const msg = try std.fmt.allocPrint(
                    self.arena,
                    "undefined symbol `{s}`",
                    .{name},
                );
                try self.emit("E_UNDEFINED_SYMBOL", i.span.start, msg, name);
                return null;
            },
            .self_expr, .super_expr => return null,
            .paren => |p| return try self.inferExpr(p.inner),
            .unary => |u| {
                _ = try self.inferExpr(u.operand);
                return null; // operator type rules land in slice 3
            },
            .binary => |b| {
                _ = try self.inferExpr(b.lhs);
                _ = try self.inferExpr(b.rhs);
                return null;
            },
            .range => |r| {
                _ = try self.inferExpr(r.start);
                _ = try self.inferExpr(r.end);
                return null;
            },
            .call => |c| {
                _ = try self.inferExpr(c.callee);
                for (c.args) |a| _ = try self.inferExpr(a);
                return null;
            },
            .method_call => |m| {
                _ = try self.inferExpr(m.receiver);
                for (m.args) |a| _ = try self.inferExpr(a);
                return null;
            },
            .field => |f| {
                _ = try self.inferExpr(f.receiver);
                return null;
            },
            .index => |ix| {
                _ = try self.inferExpr(ix.receiver);
                _ = try self.inferExpr(ix.index);
                return null;
            },
            .do_expr => |d| {
                try self.walkInScope(d.body);
                return null;
            },
            .if_expr => |ie| {
                try self.checkIfChain(ie.arms, ie.else_body);
                return null;
            },
            .lambda => |l| {
                const saved = self.current_scope;
                var lambda_scope: Scope = .init(self.arena, saved);
                self.current_scope = &lambda_scope;
                defer self.current_scope = saved;
                for (l.params) |p| {
                    const pt: ?*const types.Type = if (p.type_ann) |t|
                        try self.resolveType(t)
                    else
                        null;
                    try self.registerName(self.lexeme(p.name), .{
                        .kind = .param,
                        .decl_span = p.name,
                        .ty = pt,
                    });
                }
                for (l.body) |s| try self.walkStatement(s);
                return null;
            },
            .list_lit => |ll| {
                var first_ty: ?*const types.Type = null;
                for (ll.elems) |x| {
                    const t = try self.inferExpr(x);
                    if (first_ty == null) first_ty = t;
                }
                if (first_ty) |t| {
                    return try types.mkArray(self.arena, t, @intCast(ll.elems.len));
                }
                return null;
            },
            .list_repeat => |lr| {
                const v_ty = try self.inferExpr(lr.value);
                _ = try self.inferExpr(lr.count);
                if (v_ty) |t| {
                    const len_val: u32 = if (lr.count.* == .int_lit)
                        // safety: array-repeat count parsed as i32; §3.4 requires non-negative comptime int. Slice 3 will range-check; bit-cast preserves bytes.
                        @bitCast(lr.count.int_lit.value)
                    else
                        0;
                    return try types.mkArray(self.arena, t, len_val);
                }
                return null;
            },
            .struct_lit => |sl| {
                for (sl.fields) |f| _ = try self.inferExpr(f.value);
                return try types.mkNamed(self.arena, self.lexeme(sl.type_name), sl.type_name);
            },
            .tuple_lit => |tl| {
                var elems: std.ArrayList(*const types.Type) = .empty;
                errdefer elems.deinit(self.arena);
                for (tl.elems) |x| {
                    const t = try self.inferExpr(x) orelse return null;
                    try elems.append(self.arena, t);
                }
                const out = try self.arena.create(types.Type);
                out.* = .{ .tuple = try elems.toOwnedSlice(self.arena) };
                return out;
            },
            .is_test => |it| {
                _ = try self.inferExpr(it.lhs);
                return try self.primitive(.bool_);
            },
            .cast => |c| {
                _ = try self.inferExpr(c.inner);
                return try self.resolveType(c.target_type);
            },
            .ref_of => |r| {
                const inner = try self.inferExpr(r.inner) orelse return null;
                return try types.mkReference(self.arena, inner);
            },
        }
    }
};

// ---------- module-level helpers (recursive cycle-breakers) ----------

fn ifChainMentions(
    c: *const Checker,
    arms: []const ast.IfArm,
    else_body: ?[]const ast.Statement,
    name: []const u8,
) bool {
    for (arms) |arm| {
        if (arm.cond) |co| if (c.exprMentions(co, name)) return true;
        if (arm.let_expr) |e| if (c.exprMentions(e, name)) return true;
        if (arm.let_guard) |g| if (c.exprMentions(g, name)) return true;
        if (c.bodyMentions(arm.body, name)) return true;
    }
    if (else_body) |eb| if (c.bodyMentions(eb, name)) return true;
    return false;
}

fn matchMentions(c: *const Checker, ms: ast.MatchStmt, name: []const u8) bool {
    if (c.exprMentions(ms.scrutinee, name)) return true;
    for (ms.arms) |arm| {
        if (arm.guard) |g| if (c.exprMentions(g, name)) return true;
        if (c.bodyMentions(arm.body, name)) return true;
    }
    return false;
}

fn anyExprMentions(c: *const Checker, exprs: []const *ast.Expr, name: []const u8) bool {
    for (exprs) |e| if (c.exprMentions(e, name)) return true;
    return false;
}

fn structLitMentions(c: *const Checker, fields: []const ast.StructLitField, name: []const u8) bool {
    for (fields) |f| if (c.exprMentions(f.value, name)) return true;
    return false;
}
