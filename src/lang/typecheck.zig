const std = @import("std");

const ast = @import("ast.zig");
const types = @import("types.zig");
const scope_mod = @import("scope.zig");
const diag_mod = @import("diagnostic.zig");
const Scope = scope_mod.Scope;
const Diagnostic = diag_mod.Diagnostic;
const Severity = diag_mod.Severity;

/// Typechecker output. Owns the diagnostics slice and the arena
/// holding every `*Type` plus the scope tree.
pub const CheckedProgram = struct {
    program: *const ast.Program,
    diagnostics: []Diagnostic,
    /// Inferred type for every walked expression. `null` lookups
    /// mean the type couldn't be inferred.
    expr_types: std.AutoHashMapUnmanaged(*const ast.Expr, *const types.Type),
    type_arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    /// Release the diagnostics slice and the `*Type` arena.
    pub fn deinit(self: *CheckedProgram) void {
        self.allocator.free(self.diagnostics);
        self.type_arena.deinit();
    }

    /// `true` when at least one fatal diagnostic fired.
    pub fn hasErrors(self: CheckedProgram) bool {
        for (self.diagnostics) |d| if (d.severity == .fatal) return true;
        return false;
    }

    /// Inferred type for `e`, or `null` if missing.
    pub fn typeOf(self: *const CheckedProgram, e: *const ast.Expr) ?*const types.Type {
        return self.expr_types.get(e);
    }
};

/// Type-check `program` and return a `CheckedProgram`.
///
/// ```
/// var checked = try typecheck(allocator, source, &parse_tree.program);
/// defer checked.deinit();
/// if (checked.hasErrors()) { ... }
/// ```
pub fn typecheck(
    allocator: std.mem.Allocator,
    source: []const u8,
    program: *const ast.Program,
) !CheckedProgram {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(allocator);

    var module_scope: Scope = .init(a, null);
    // Arena owns the scope's map storage; freed by `CheckedProgram.deinit`.

    var expr_types: std.AutoHashMapUnmanaged(*const ast.Expr, *const types.Type) = .{};
    errdefer expr_types.deinit(a);

    var c: Checker = .{
        .source = source,
        .arena = a,
        .diag_alloc = allocator,
        .diagnostics = &diagnostics,
        .module_scope = &module_scope,
        .current_scope = &module_scope,
        .current_ret_ty = null,
        .current_class_extends = null,
        .current_class_name = null,
        .non_nil = .{},
        .enum_registry = .{},
        .struct_registry = .{},
        .class_registry = .{},
        .def_registry = .{},
        .mmio_names = .{},
        .fn_locals = null,
        .tuple_correlations = .{},
        .in_bake = false,
        .in_no_capture = false,
        .lambda_locals = null,
        .expr_types = &expr_types,
    };

    // Pre-pass: index enum / struct / class / def decls and the
    // MMIO name set (any `let` annotated `@addr`).
    for (program.statements) |*stmt| switch (stmt.*) {
        .enum_decl => |ed| {
            const name = source[ed.name.start..ed.name.end];
            try c.enum_registry.put(a, name, &stmt.enum_decl);
        },
        .struct_decl => |sd| {
            const name = source[sd.name.start..sd.name.end];
            try c.struct_registry.put(a, name, &stmt.struct_decl);
        },
        .class_decl => |cd| {
            const name = source[cd.name.start..cd.name.end];
            try c.class_registry.put(a, name, &stmt.class_decl);
        },
        .def_decl => |dd| {
            const name = source[dd.name.start..dd.name.end];
            try c.def_registry.put(a, name, &stmt.def_decl);
        },
        .let_decl => |ld| {
            for (ld.annotations) |ann| {
                if (std.mem.eql(u8, source[ann.name.start..ann.name.end], "addr")) {
                    if (ld.pattern.* == .ident) {
                        const lname = source[ld.pattern.ident.name.start..ld.pattern.ident.name.end];
                        try c.mmio_names.put(a, lname, {});
                    }
                    break;
                }
            }
        },
        else => {},
    };

    // Pass 1: register top-level decls so forward references resolve.
    for (program.statements) |stmt| try c.registerTopLevel(stmt);

    // Pass 2: walk + resolve + infer + check.
    try c.walkStatementSequence(program.statements);

    return .{
        .program = program,
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
        .expr_types = expr_types,
        .type_arena = arena,
        .allocator = allocator,
    };
}

const mem_builtin = @import("typecheck/mem_builtin.zig");
const match = @import("typecheck/match.zig");
const predicates = @import("typecheck/predicates.zig");
const annotations = @import("typecheck/annotations.zig");
const relations = @import("typecheck/relations.zig");
const flow = @import("typecheck/flow.zig");
const suggestions = @import("typecheck/suggestions.zig");
const type_resolve = @import("typecheck/type_resolve.zig");
const fields = @import("typecheck/fields.zig");
const operators = @import("typecheck/operators.zig");
const calls = @import("typecheck/calls.zig");

const T = annotations.T;

/// Stateful walker that runs resolution + inference + checking.
/// Sub-modules under `typecheck/` take a `*Checker` and call back
/// into its public methods.
pub const Checker = struct {
    source: []const u8,
    arena: std.mem.Allocator,
    /// Allocator for the diagnostics ArrayList. Diagnostic strings
    /// live in `arena`.
    diag_alloc: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
    /// Outermost (module) scope.
    module_scope: *Scope,
    /// Currently-active scope. Restored on walker exit.
    current_scope: *Scope,
    /// Return type of the enclosing function (or `null` at module
    /// scope / inside a `def` with no explicit return annotation).
    /// Used as a hint for `return expr` so int literals pin to the
    /// declared return type.
    current_ret_ty: ?*const types.Type,
    /// `extends Parent` span when inside a class method. `null`
    /// elsewhere. Drives `super` resolution.
    current_class_extends: ?ast.Span,
    /// Enclosing class name when inside a class method. Drives
    /// `self` type resolution.
    current_class_name: ?[]const u8,
    /// Identifiers statically known non-nil in the current flow.
    /// Populated by simple nil-check pattern matching.
    non_nil: std.StringHashMapUnmanaged(void),
    /// Enum-name → decl pointer (pass 1).
    enum_registry: std.StringHashMapUnmanaged(*const ast.EnumDecl),
    /// Struct-name → decl pointer.
    struct_registry: std.StringHashMapUnmanaged(*const ast.StructDecl),
    /// Class-name → decl pointer.
    class_registry: std.StringHashMapUnmanaged(*const ast.ClassDecl),
    /// Top-level `def` name → decl pointer.
    def_registry: std.StringHashMapUnmanaged(*const ast.DefDecl),
    /// Module-level `let`s annotated `@addr`. Accessing from a
    /// bake context emits `E_BAKE_MMIO_ACCESS`.
    mmio_names: std.StringHashMapUnmanaged(void),
    /// Walker is inside a `bake def` / `bake do` body.
    in_bake: bool,
    /// Walker is inside a `@no_capture` def body.
    in_no_capture: bool,
    /// Names declared inside the current lambda body. `null` when
    /// not under a `@no_capture`-tracked lambda. Drives capture-
    /// mutation checks.
    lambda_locals: ?std.StringHashMapUnmanaged(void),
    /// Names declared inside the current function body. `null` at
    /// module scope. Drives `return &local` stack-lifetime checks.
    fn_locals: ?std.StringHashMapUnmanaged(void),
    /// Tuple-destructure sibling map. For `let (a, b) = call()`
    /// with nullable `b`, `b → a`. Bail on `b` promotes `a` to
    /// non-nil too.
    tuple_correlations: std.StringHashMapUnmanaged([]const u8),
    /// Inferred type per AST expression pointer. Owned by the
    /// caller; survives `Checker` for the codegen to read.
    expr_types: *std.AutoHashMapUnmanaged(*const ast.Expr, *const types.Type),

    /// Explicit error set for the mutually-recursive walker fns.
    const WalkError = error{OutOfMemory};

    // ---------- nil-flow helpers ----------

    /// Mark `name` as statically non-nil. Returns `true` when the
    /// addition is fresh.
    fn pushNonNil(self: *Checker, name: []const u8) WalkError!bool {
        const gop = try self.non_nil.getOrPut(self.arena, name);
        return !gop.found_existing;
    }

    fn popNonNil(self: *Checker, name: []const u8) void {
        _ = self.non_nil.remove(name);
    }

    /// Match `ident == nil` / `ident != nil` (either order). Returns
    /// the ident lexeme + whether the relation is `!=`.
    fn matchNilCheck(self: *const Checker, cond: *const ast.Expr) ?NilCheck {
        if (cond.* != .binary) return null;
        const b = cond.binary;
        if (b.op != .eq and b.op != .neq) return null;
        const lhs_ident = flow.identName(self, b.lhs);
        const rhs_ident = flow.identName(self, b.rhs);
        const lhs_nil = b.lhs.* == .nil_lit;
        const rhs_nil = b.rhs.* == .nil_lit;
        if (lhs_ident) |n| if (rhs_nil) return .{ .name = n, .is_neq = b.op == .neq };
        if (rhs_ident) |n| if (lhs_nil) return .{ .name = n, .is_neq = b.op == .neq };
        return null;
    }

    const NilCheck = struct {
        name: []const u8,
        /// `true` for `!=` (then-arm is non-nil), `false` for `==`.
        is_neq: bool,
    };

    // ---------- diagnostic helpers ----------

    /// Emit a fatal diagnostic at `span`.
    pub fn emitSpan(
        self: *Checker,
        code: []const u8,
        span: ast.Span,
        message: []const u8,
    ) WalkError!void {
        try self.diagnostics.append(self.diag_alloc, .{
            .severity = .fatal,
            .code = code,
            .message = message,
            .span = span,
        });
    }

    /// Like `emitSpan` plus a `help:` block.
    pub fn emitSpanHelp(
        self: *Checker,
        code: []const u8,
        span: ast.Span,
        message: []const u8,
        help: []const u8,
    ) WalkError!void {
        try self.diagnostics.append(self.diag_alloc, .{
            .severity = .fatal,
            .code = code,
            .message = message,
            .span = span,
            .help = help,
        });
    }

    /// Emit `E_TYPE_MISMATCH` for an expected-vs-actual mismatch
    /// at a single span.
    pub fn emitMismatch(
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
        try self.emitSpan("E_TYPE_MISMATCH", span, msg);
    }

    /// Like `emitMismatch` but anchors the expected type to a
    /// `: T` annotation span via a secondary label.
    pub fn emitMismatchAnnotated(
        self: *Checker,
        span: ast.Span,
        expected_ty: *const types.Type,
        actual_ty: *const types.Type,
        annotation_span: ast.Span,
    ) WalkError!void {
        const expected_s = try types.render(self.arena, expected_ty.*);
        const actual_s = try types.render(self.arena, actual_ty.*);
        const msg = try std.fmt.allocPrint(
            self.arena,
            "type mismatch: expected `{s}`, found `{s}`",
            .{ expected_s, actual_s },
        );
        const label_msg = try std.fmt.allocPrint(
            self.arena,
            "expected `{s}` because of this annotation",
            .{expected_s},
        );
        const sec = try self.singleSecondary(annotation_span, label_msg, .underline);
        try self.diagnostics.append(self.diag_alloc, .{
            .severity = .fatal,
            .code = "E_TYPE_MISMATCH",
            .message = msg,
            .span = span,
            .secondary = sec,
        });
    }

    /// Allocate a one-element `SpanLabel` slice on `self.arena`,
    /// suitable for `Diagnostic.secondary`.
    pub fn singleSecondary(
        self: *Checker,
        span: ast.Span,
        message: []const u8,
        decoration: diag_mod.SpanLabel.Decoration,
    ) WalkError![]const diag_mod.SpanLabel {
        const sec = try self.arena.alloc(diag_mod.SpanLabel, 1);
        sec[0] = .{ .span = span, .message = message, .decoration = decoration };
        return sec;
    }

    /// Assignability + narrowing check for "store into a typed
    /// slot" sites (let-init, assignment, call arg, return).
    /// Routes per spec §3.5.1:
    /// - Assignable → no diagnostic.
    /// - Integer narrowing without `as` → `E_CAST_PRECISION_LOSS`
    ///   (warning).
    /// - Otherwise → `E_TYPE_MISMATCH` (fatal).
    pub fn checkStoreCompat(
        self: *Checker,
        span: ast.Span,
        expected: *const types.Type,
        actual: *const types.Type,
    ) WalkError!void {
        if (relations.assignable(actual.*, expected.*)) return;
        if (self.isClassSubtype(actual.*, expected.*)) return;
        if (relations.isNarrowingInt(actual.*, expected.*)) {
            try self.emitNarrowingWarning(span, expected, actual);
            return;
        }
        try self.emitMismatch(span, expected, actual);
    }

    /// `true` when `actual` is a class derived from `expected`
    /// (transitively, via `extends`). Also covers `&Sub` → `&Sup`
    /// reference subtyping by peeling one layer per side.
    pub fn isClassSubtype(self: *const Checker, actual: types.Type, expected: types.Type) bool {
        const a = if (actual == .reference) actual.reference.* else actual;
        const e = if (expected == .reference) expected.reference.* else expected;
        if (a != .named or e != .named) return false;
        const expected_name = e.named.name;
        var cur = self.class_registry.get(a.named.name) orelse return false;
        while (cur.extends) |ext| {
            const parent_name = self.lexeme(ext);
            if (std.mem.eql(u8, parent_name, expected_name)) return true;
            cur = self.class_registry.get(parent_name) orelse return false;
        }
        return false;
    }

    fn emitNarrowingWarning(
        self: *Checker,
        span: ast.Span,
        expected_ty: *const types.Type,
        actual_ty: *const types.Type,
    ) WalkError!void {
        const expected_s = try types.render(self.arena, expected_ty.*);
        const actual_s = try types.render(self.arena, actual_ty.*);
        const msg = try std.fmt.allocPrint(
            self.arena,
            "implicit narrowing from `{s}` to `{s}` may lose precision — use an explicit `as {s}` cast to silence this warning",
            .{ actual_s, expected_s, expected_s },
        );
        try self.diagnostics.append(self.diag_alloc, .{
            .severity = .warning,
            .code = "E_CAST_PRECISION_LOSS",
            .message = msg,
            .span = span,
        });
    }

    /// Return the source-text slice for `span`.
    pub fn lexeme(self: *const Checker, span: ast.Span) []const u8 {
        return self.source[span.start..span.end];
    }

    // ---------- "did you mean…?" suggestions ----------

    /// Closest near-spelling match for an undefined symbol across
    /// the scope chain + type registries. `null` when nothing is
    /// within `suggestions.max_distance`.
    pub fn suggestSymbol(self: *Checker, name: []const u8) WalkError!?[]const u8 {
        var pool: std.ArrayList([]const u8) = .empty;
        defer pool.deinit(self.arena);
        var scope: ?*const Scope = self.current_scope;
        while (scope) |s| : (scope = s.parent) {
            var it = s.entries.keyIterator();
            while (it.next()) |k| try pool.append(self.arena, k.*);
        }
        return suggestions.bestMatch(name, pool.items);
    }

    /// Same pool as `suggestSymbol` plus the primitive type names —
    /// used by `E_TYPE_UNDEFINED` when an unknown type name shows
    /// up in an annotation / struct-lit position.
    pub fn suggestTypeName(self: *Checker, name: []const u8) WalkError!?[]const u8 {
        var pool: std.ArrayList([]const u8) = .empty;
        defer pool.deinit(self.arena);
        // Primitives matched first so `let x: i8` wins over a stray
        // `i9` local. Mirrors `types.primitiveFromName`.
        const primitives = [_][]const u8{ "i8", "u8", "i16", "u16", "int", "uint", "bool", "nil", "str", "fixed", "char" };
        for (primitives) |p| try pool.append(self.arena, p);
        var struct_it = self.struct_registry.keyIterator();
        while (struct_it.next()) |k| try pool.append(self.arena, k.*);
        var class_it = self.class_registry.keyIterator();
        while (class_it.next()) |k| try pool.append(self.arena, k.*);
        var enum_it = self.enum_registry.keyIterator();
        while (enum_it.next()) |k| try pool.append(self.arena, k.*);
        return suggestions.bestMatch(name, pool.items);
    }

    /// Best-match field name on a struct.
    pub fn suggestStructField(self: *Checker, sd: *const ast.StructDecl, name: []const u8) WalkError!?[]const u8 {
        var pool: std.ArrayList([]const u8) = .empty;
        defer pool.deinit(self.arena);
        for (sd.fields) |f| try pool.append(self.arena, self.lexeme(f.name));
        return suggestions.bestMatch(name, pool.items);
    }

    /// Best-match field name across a class and its parents.
    pub fn suggestClassField(self: *Checker, cd: *const ast.ClassDecl, name: []const u8) WalkError!?[]const u8 {
        var pool: std.ArrayList([]const u8) = .empty;
        defer pool.deinit(self.arena);
        var cur: ?*const ast.ClassDecl = cd;
        while (cur) |c| {
            for (c.fields) |f| try pool.append(self.arena, self.lexeme(f.name));
            cur = if (c.extends) |ext| self.class_registry.get(self.lexeme(ext)) else null;
        }
        return suggestions.bestMatch(name, pool.items);
    }

    /// Best-match method name across a class and its parents.
    pub fn suggestClassMethod(self: *Checker, cd: *const ast.ClassDecl, name: []const u8) WalkError!?[]const u8 {
        var pool: std.ArrayList([]const u8) = .empty;
        defer pool.deinit(self.arena);
        var cur: ?*const ast.ClassDecl = cd;
        while (cur) |c| {
            for (c.methods) |m| try pool.append(self.arena, self.lexeme(m.name));
            cur = if (c.extends) |ext| self.class_registry.get(self.lexeme(ext)) else null;
        }
        return suggestions.bestMatch(name, pool.items);
    }

    /// Emit a fatal diagnostic; appends `help: did you mean \`X\`?`
    /// when `candidate` is non-null.
    pub fn emitSpanWithSuggestion(
        self: *Checker,
        code: []const u8,
        span: ast.Span,
        message: []const u8,
        candidate: ?[]const u8,
    ) WalkError!void {
        const name = candidate orelse return self.emitSpan(code, span, message);
        const help = try std.fmt.allocPrint(self.arena, "did you mean `{s}`?", .{name});
        try self.emitSpanHelp(code, span, message, help);
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
                    try type_resolve.resolveType(self, t)
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
        if (isReservedBuiltinName(name)) {
            const msg = try std.fmt.allocPrint(
                self.arena,
                "cannot shadow always-in-scope builtin `{s}`",
                .{name},
            );
            try self.emitSpan("E_BUILTIN_SHADOW", info.decl_span, msg);
            return;
        }
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
    fn signatureFromDef(self: *Checker, d: ast.DefDecl) WalkError!*const types.Type {
        var param_types: std.ArrayList(*const types.Type) = .empty;
        errdefer param_types.deinit(self.arena);
        for (d.params) |p| {
            const pt: *const types.Type = if (p.type_ann) |t|
                try type_resolve.resolveType(self, t)
            else
                try self.primitive(.nil_); // unknown until call-site inference
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

    // ---------- Pass 2: resolution + inference + checking ----------

    fn walkStatement(self: *Checker, s: ast.Statement) WalkError!void {
        switch (s) {
            .let_decl => |d| try self.checkLetDecl(d),
            .const_decl => |d| try self.checkConstDecl(d),
            .assign => |a| try self.checkAssign(a),
            .inc_dec => |id| try self.checkIncDec(id),
            .discard => |d| _ = try self.inferExpr(d.expr, null),
            .expr_stmt => |es| _ = try self.inferExpr(es.expr, null),
            .block => |b| try self.walkInScope(b.body),
            .if_stmt => |is_| try self.checkIfChain(is_.arms, is_.else_body),
            .while_stmt => |ws| try self.checkWhile(ws),
            .for_stmt => |fs| try self.checkFor(fs),
            .repeat_stmt => |rs| try self.checkRepeat(rs),
            .match_stmt => |ms| try self.checkMatch(ms),
            .return_stmt => |rs| try self.checkReturn(rs),
            .break_stmt, .continue_stmt => {},
            .print_stmt => |ps| {
                for (ps.args) |a| _ = try self.inferExpr(a, null);
            },
            .def_decl => |d| try self.checkDefDecl(d),
            .class_decl => |c| try self.checkClassDecl(c),
            .struct_decl => |sd| try annotations.validateAnnotations(self, sd.annotations, T.STRUCT),
            .enum_decl => |ed| try annotations.validateAnnotations(self, ed.annotations, T.ENUM),
            .use_decl, .local_decl => {},
            .asm_stmt => |as_| if (self.in_bake) {
                try self.emitSpan("E_BAKE_ASM_INSIDE", as_.span, "`asm` is not allowed inside a `bake` context — compile-time interpretation cannot run host bytecode");
            },
            .defer_stmt => |ds| try self.checkDeferStmt(ds),
            .unknown => {},
        }
    }

    fn walkInScope(self: *Checker, body: []const ast.Statement) WalkError!void {
        const saved = self.current_scope;
        var child: Scope = .init(self.arena, saved);
        self.current_scope = &child;
        defer self.current_scope = saved;
        try self.walkStatementSequence(body);
    }

    /// Walk a flat statement list and absorb the "fall-through gain"
    /// from `if x == nil then return end` patterns — code following
    /// such an `if` may treat `x` as statically non-nil for the rest
    /// of the surrounding block.
    pub fn walkStatementSequence(self: *Checker, body: []const ast.Statement) WalkError!void {
        var fall_through: std.ArrayList([]const u8) = .empty;
        defer {
            for (fall_through.items) |name| self.popNonNil(name);
            fall_through.deinit(self.arena);
        }
        for (body) |s| {
            const gain = self.detectNilBailGain(s);
            try self.walkStatement(s);
            if (gain) |name| {
                if (try self.pushNonNil(name)) try fall_through.append(self.arena, name);
            }
        }
    }

    /// Detect a single-arm `if` whose body always exits — the
    /// nullable / multi-return bail pattern. Returns the name to
    /// push as non-nil, or `null`.
    ///
    /// ```
    /// if x == nil return end      // x is non-nil after.
    /// if err != nil return end    // sibling of err (correlated) is non-nil after.
    /// ```
    fn detectNilBailGain(self: *const Checker, s: ast.Statement) ?[]const u8 {
        if (s != .if_stmt) return null;
        const is_ = s.if_stmt;
        if (is_.arms.len != 1 or is_.else_body != null) return null;
        const arm = is_.arms[0];
        const cond = arm.cond orelse return null;
        const nc = self.matchNilCheck(cond) orelse return null;
        if (!flow.bodyAlwaysExits(arm.body)) return null;
        if (nc.is_neq) {
            // Multi-return: bail when err != nil. After the bail
            // err is statically nil, so its correlated sibling
            // (value slot of `let (n, err) = …`) is valid.
            return self.tuple_correlations.get(nc.name);
        }
        return nc.name;
    }

    fn checkLetDecl(self: *Checker, d: ast.LetDecl) WalkError!void {
        try annotations.validateAnnotations(self, d.annotations, T.LET);
        const ann_ty: ?*const types.Type = if (d.type_ann) |t|
            try type_resolve.resolveType(self, t)
        else
            null;
        // Pass annotation type as a hint so int literals pin to the
        // declared primitive (`let x: u8 = 0` now infers u8).
        const init_ty: ?*const types.Type = if (d.init) |e|
            try self.inferExpr(e, ann_ty)
        else
            null;
        if (ann_ty != null and init_ty != null) {
            // Hard mismatches on an annotated `let` attach the
            // annotation as a secondary span so the renderer
            // surfaces "expected `T` because of this annotation"
            // — sole call site that overrides the plain
            // `checkStoreCompat` path (#254 AC).
            if (!relations.assignable(init_ty.?.*, ann_ty.?.*) and
                !self.isClassSubtype(init_ty.?.*, ann_ty.?.*) and
                !relations.isNarrowingInt(init_ty.?.*, ann_ty.?.*) and
                d.type_ann != null)
            {
                try self.emitMismatchAnnotated(d.init.?.span(), ann_ty.?, init_ty.?, d.type_ann.?.span());
            } else {
                try self.checkStoreCompat(d.init.?.span(), ann_ty.?, init_ty.?);
            }
        }
        switch (d.pattern.*) {
            .ident => |i| {
                const ty = ann_ty orelse init_ty;
                if (ty) |t| {
                    self.current_scope.setType(self.lexeme(i.name), t) catch {
                        try self.registerName(self.lexeme(i.name), .{
                            .kind = .let_binding,
                            .decl_span = i.name,
                            .ty = t,
                        });
                    };
                } else {
                    if (self.current_scope.lookupLocal(self.lexeme(i.name)) == null) {
                        try self.registerName(self.lexeme(i.name), .{
                            .kind = .let_binding,
                            .decl_span = i.name,
                            .ty = null,
                        });
                    }
                }
            },
            .tuple_pattern => try self.checkLetTupleDestructure(d.pattern, init_ty),
            else => try self.registerPatternBindings(d.pattern),
        }
    }

    /// Type each binding of a `let (a, b, …) = call()` against the
    /// init's tuple slots. Mismatched arity emits
    /// `E_TYPE_TUPLE_ARITY`. Two-ident patterns with a nullable
    /// second slot get a sibling correlation for bail-pattern flow.
    fn checkLetTupleDestructure(
        self: *Checker,
        pat: *const ast.Pattern,
        init_ty: ?*const types.Type,
    ) WalkError!void {
        const tp = pat.tuple_pattern;
        const it = init_ty orelse {
            // Without a typed init, bind every element untyped.
            try self.registerPatternBindings(pat);
            return;
        };
        if (it.* != .tuple) {
            try self.registerPatternBindings(pat);
            return;
        }
        const slots = it.tuple;
        if (slots.len != tp.elems.len) {
            const suffix: []const u8 = if (tp.elems.len == 1) "" else "s";
            const msg = try std.fmt.allocPrint(
                self.arena,
                "tuple-destructuring pattern has {d} element{s}, init has {d}",
                .{ tp.elems.len, suffix, slots.len },
            );
            try self.emitSpan("E_TYPE_TUPLE_ARITY", tp.span, msg);
            try self.registerPatternBindings(pat);
            return;
        }
        for (tp.elems, slots) |elem_pat, slot_ty| {
            switch (elem_pat.*) {
                .ident => |i| try self.registerName(self.lexeme(i.name), .{
                    .kind = .let_binding,
                    .decl_span = i.name,
                    .ty = slot_ty,
                }),
                else => try self.registerPatternBindings(elem_pat),
            }
        }
        // Multi-return correlation: the canonical `(value, err)`
        // shape. When the err slot is `T?` and both elements are
        // plain idents, remember which name promotes which.
        if (tp.elems.len == 2 and
            tp.elems[0].* == .ident and
            tp.elems[1].* == .ident and
            slots[1].* == .optional)
        {
            const a_name = self.lexeme(tp.elems[0].ident.name);
            const b_name = self.lexeme(tp.elems[1].ident.name);
            _ = try self.tuple_correlations.put(self.arena, b_name, a_name);
        }
    }

    fn checkConstDecl(self: *Checker, d: ast.ConstDecl) WalkError!void {
        try annotations.validateAnnotations(self, d.annotations, T.CONST);
        const ann_ty: ?*const types.Type = if (d.type_ann) |t|
            try type_resolve.resolveType(self, t)
        else
            null;
        const init_ty = try self.inferExpr(d.init, ann_ty);
        const final = ann_ty orelse init_ty;
        if (ann_ty != null and init_ty != null) {
            try self.checkStoreCompat(d.init.span(), ann_ty.?, init_ty.?);
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

    fn checkAssign(self: *Checker, a: ast.AssignStmt) WalkError!void {
        if (!isPlaceExpr(a.target)) {
            try self.emitSpan("E_TYPE_MISMATCH", a.target.span(), "assignment target must be a place expression (ident, field, or index)");
            _ = try self.inferExpr(a.value, null);
            return;
        }
        try self.checkNoCaptureMutation(a.target);
        const tgt_ty = try self.inferExpr(a.target, null);
        // Compound `op=` is sugar for `target = target op value`; the
        // target's type is the hint for the rhs in either form.
        const val_ty = try self.inferExpr(a.value, tgt_ty);
        if (tgt_ty != null and val_ty != null) {
            try self.checkStoreCompat(a.value.span(), tgt_ty.?, val_ty.?);
        }
    }

    fn checkIncDec(self: *Checker, id: ast.IncDecStmt) WalkError!void {
        if (!isPlaceExpr(id.target)) {
            try self.emitSpan("E_TYPE_MISMATCH", id.target.span(), "`++` / `--` target must be a place expression (ident, field, or index)");
            return;
        }
        try self.checkNoCaptureMutation(id.target);
        const tgt_ty = try self.inferExpr(id.target, null);
        if (tgt_ty) |t| {
            if (!predicates.isIntegerType(t.*)) {
                const ty_s = try types.render(self.arena, t.*);
                const msg = try std.fmt.allocPrint(
                    self.arena,
                    "`++` / `--` requires an integer type, found `{s}`",
                    .{ty_s},
                );
                try self.emitSpan("E_TYPE_MISMATCH", id.target.span(), msg);
            }
        }
    }

    /// `@no_capture` enforcement (§3.7.2): when the walker is
    /// inside a lambda body of a `@no_capture` def, mutating a
    /// binding that wasn't declared locally (param or `let` inside
    /// this lambda) is `E_ANN_CAPTURE_VIOLATION`.
    fn checkNoCaptureMutation(self: *Checker, target: *const ast.Expr) WalkError!void {
        if (!self.in_no_capture) return;
        const locals = self.lambda_locals orelse return;
        const name = flow.identName(self, target) orelse return;
        if (locals.contains(name)) return;
        const msg = try std.fmt.allocPrint(
            self.arena,
            "closure mutates captured binding `{s}` — forbidden by `@no_capture` on the enclosing function (§3.7.2)",
            .{name},
        );
        try self.emitSpan("E_ANN_CAPTURE_VIOLATION", target.span(), msg);
    }

    fn checkIfChain(
        self: *Checker,
        arms: []const ast.IfArm,
        else_body: ?[]const ast.Statement,
    ) WalkError!void {
        // Flow analysis is applied only when there is exactly one
        // arm — the simple `if cond then BODY [else …] end` shape.
        // Multi-arm `elif` chains skip the bookkeeping.
        const nil_flow: ?NilCheck = if (arms.len == 1 and arms[0].cond != null)
            self.matchNilCheck(arms[0].cond.?)
        else
            null;

        for (arms, 0..) |arm, i| {
            if (arm.cond) |c| _ = try self.inferExpr(c, null);
            if (arm.let_expr) |e| _ = try self.inferExpr(e, null);
            if (arm.let_guard) |g| _ = try self.inferExpr(g, null);

            const arm_gain: ?[]const u8 = if (i == 0 and nil_flow != null and nil_flow.?.is_neq)
                nil_flow.?.name
            else
                null;
            const added = if (arm_gain) |n| try self.pushNonNil(n) else false;
            // `if expr is Class as h` — the binding `h` is in scope
            // for THIS arm's body, typed as the target class.
            const is_binding: ?ast.IsTestExpr.ClassTypeProbe = if (arm.cond) |c|
                (if (c.* == .is_test) c.is_test.classBinding() else null)
            else
                null;
            try self.walkArmBodyWithIsBinding(arm.body, is_binding);
            if (added) self.popNonNil(arm_gain.?);
        }

        if (else_body) |eb| {
            // The else-arm fires when the `if` cond was false, so
            // `x == nil` confers non-nil in the else.
            const else_gain: ?[]const u8 = if (nil_flow != null and !nil_flow.?.is_neq)
                nil_flow.?.name
            else
                null;
            const added = if (else_gain) |n| try self.pushNonNil(n) else false;
            try self.walkInScope(eb);
            if (added) self.popNonNil(else_gain.?);
        }
    }

    /// Walk an `if` arm body, optionally pushing an `is X as h`
    /// binding into the arm's child scope. The binding's type is
    /// the named class — typically a subclass of the receiver,
    /// safe to use as that subclass for the duration of the body.
    fn walkArmBodyWithIsBinding(
        self: *Checker,
        body: []const ast.Statement,
        probe: ?ast.IsTestExpr.ClassTypeProbe,
    ) WalkError!void {
        if (probe == null or probe.?.binding == null) {
            try self.walkInScope(body);
            return;
        }
        const saved = self.current_scope;
        var child: Scope = .init(self.arena, saved);
        self.current_scope = &child;
        defer self.current_scope = saved;
        const class_name = self.lexeme(probe.?.class_name);
        const bind_name = self.lexeme(probe.?.binding.?);
        const ty = try types.mkNamed(self.arena, class_name, probe.?.class_name);
        try self.registerName(bind_name, .{
            .kind = .let_binding,
            .decl_span = probe.?.binding.?,
            .ty = ty,
        });
        try self.walkStatementSequence(body);
    }

    fn checkWhile(self: *Checker, ws: ast.WhileStmt) WalkError!void {
        if (ws.cond) |c| _ = try self.inferExpr(c, null);
        if (ws.let_expr) |e| _ = try self.inferExpr(e, null);
        if (ws.let_guard) |g| _ = try self.inferExpr(g, null);
        try self.walkInScope(ws.body);
    }

    fn checkFor(self: *Checker, fs: ast.ForStmt) WalkError!void {
        _ = try self.inferExpr(fs.iter, null);
        if (fs.step) |st| _ = try self.inferExpr(st, null);
        const saved = self.current_scope;
        var child: Scope = .init(self.arena, saved);
        self.current_scope = &child;
        defer self.current_scope = saved;
        try self.registerName(self.lexeme(fs.binding), .{
            .kind = .let_binding,
            .decl_span = fs.binding,
            .ty = null,
        });
        try self.walkStatementSequence(fs.body);
    }

    fn checkRepeat(self: *Checker, rs: ast.RepeatStmt) WalkError!void {
        try self.walkInScope(rs.body);
        _ = try self.inferExpr(rs.cond, null);
    }

    /// Delegated to `typecheck/match.zig`.
    fn checkMatch(self: *Checker, ms: ast.MatchStmt) WalkError!void {
        return match.checkMatch(self, ms);
    }

    /// Delegated to `typecheck/match.zig`.
    fn enumDeclForType(self: *const Checker, ty: types.Type) ?*const ast.EnumDecl {
        return match.enumDeclForType(self, ty);
    }

    /// Delegated to `typecheck/match.zig`.
    fn variantExists(self: *const Checker, ed: *const ast.EnumDecl, name: []const u8) bool {
        return match.variantExists(self, ed, name);
    }

    /// Check a `defer` body. Reject `return` / `break` / `continue`
    /// (`E_DEFER_CONTROL_FLOW`) and nested `defer` (`E_DEFER_NESTED`)
    /// per spec §4.10.
    fn checkDeferStmt(self: *Checker, ds: ast.DeferStmt) WalkError!void {
        switch (ds.body.*) {
            .return_stmt, .break_stmt, .continue_stmt => try self.emitSpan(
                "E_DEFER_CONTROL_FLOW",
                ds.span,
                "`defer` body cannot use control flow — defers may not `return`, `break`, or `continue` (wrap the body in `do … end` if you need a multi-statement cleanup)",
            ),
            .defer_stmt => try self.emitSpan(
                "E_DEFER_NESTED",
                ds.span,
                "`defer defer` doesn't compose — drop the inner `defer`",
            ),
            else => try self.walkStatement(ds.body.*),
        }
    }

    fn checkReturn(self: *Checker, rs: ast.ReturnStmt) WalkError!void {
        if (rs.value) |v| {
            try self.checkReturnStackLifetime(v);
            const v_ty = try self.inferExpr(v, self.current_ret_ty);
            if (self.current_ret_ty) |rt| if (v_ty) |vt| {
                if (!predicates.isNilType(rt.*)) {
                    try self.checkStoreCompat(v.span(), rt, vt);
                }
            };
        }
    }

    /// `return &x` where `x` is a function-local binding produces a
    /// dangling pointer once the frame unwinds — reject per §3.4.4.
    /// Only the lexical form `return &ident` is checked; values
    /// stashed in temporaries pass.
    fn checkReturnStackLifetime(self: *Checker, v: *const ast.Expr) WalkError!void {
        if (v.* != .ref_of) return;
        const inner = v.ref_of.inner;
        const name = flow.identName(self, inner) orelse return;
        const locals = self.fn_locals orelse return;
        if (!locals.contains(name)) return;
        const msg = try std.fmt.allocPrint(
            self.arena,
            "returning a reference to local binding `{s}` — its storage is freed when the function returns",
            .{name},
        );
        try self.emitSpan("E_REF_STACK_LIFETIME", v.span(), msg);
    }

    fn checkDefDecl(self: *Checker, d: ast.DefDecl) WalkError!void {
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

    fn checkClassDecl(self: *Checker, d: ast.ClassDecl) WalkError!void {
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
            try self.checkMethodAnnotations(&d, m);
            const sig = try self.signatureFromDef(m);
            try self.registerName(self.lexeme(m.name), .{
                .kind = .function,
                .decl_span = m.name,
                .ty = sig,
            });
            try self.checkDefDecl(m);
        }

        if (!annotations.classIsAbstract(self, &d)) {
            try self.checkAbstractMethodsImplemented(&d);
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

        const parent_method = self.lookupParentMethod(cd, m_name);
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
                if (self.hasConcreteImpl(cd, self.lexeme(m.name), c)) continue;
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

    /// Register every binder in a pattern (ident binders +
    /// payload binders inside variant / tuple / struct
    /// patterns) into the current scope.
    pub fn registerPatternBindings(self: *Checker, p: *const ast.Pattern) WalkError!void {
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

    /// Allocate (or reuse) a `Type` value for the given primitive
    /// tag. Sub-modules call this to construct argument / return
    /// types for the function signatures they synthesize.
    pub fn primitive(self: *Checker, p: types.Primitive) WalkError!*const types.Type {
        return try types.mkPrimitive(self.arena, p);
    }

    // ---------- expression walking + inference + checking ----------

    /// Infer the type of `e`, optionally pinned by `hint` (the
    /// expected type at the use site). Records the result on
    /// `expr_types` for the codegen.
    pub fn inferExpr(self: *Checker, e: *const ast.Expr, hint: ?*const types.Type) WalkError!?*const types.Type {
        const ty = try self.inferExprInner(e, hint);
        if (ty) |t| try self.expr_types.put(self.arena, e, t);
        return ty;
    }

    fn inferExprInner(self: *Checker, e: *const ast.Expr, hint: ?*const types.Type) WalkError!?*const types.Type {
        switch (e.*) {
            .int_lit => |lit| return try self.inferIntLit(lit, hint),
            .fixed_lit => return try self.primitive(.fixed),
            .bool_lit => return try self.primitive(.bool_),
            .nil_lit => |lit| return try self.inferNilLit(lit, hint),
            .char_lit => return try self.primitive(.char),
            .str_lit => |s| {
                for (s.parts) |part| switch (part) {
                    .lit => {},
                    .interp => |ip| _ = try self.inferExpr(ip.expr, null),
                };
                return try self.primitive(.str);
            },
            .ident => |i| {
                const name = self.lexeme(i.span);
                if (self.current_scope.lookup(name)) |info| {
                    // Bake context cannot touch MMIO-bound globals.
                    if (self.in_bake and self.mmio_names.contains(name)) {
                        const msg = try std.fmt.allocPrint(
                            self.arena,
                            "binding `{s}` is `@addr`-pinned MMIO — not accessible from a `bake` context",
                            .{name},
                        );
                        try self.emitSpan("E_BAKE_MMIO_ACCESS", i.span, msg);
                    }
                    // Class names in expression position act as
                    // constructors — synthesize `fn(init.params) ->
                    // Named(Class)` so call sites type-check via
                    // the regular `checkCall` path.
                    if (info.kind == .class) {
                        if (self.class_registry.get(name)) |cd| {
                            return try fields.constructorSignatureFor(self, cd, name, i.span);
                        }
                    }
                    return info.ty;
                }
                const msg = try std.fmt.allocPrint(
                    self.arena,
                    "undefined symbol `{s}`",
                    .{name},
                );
                try self.emitSpanWithSuggestion("E_UNDEFINED_SYMBOL", i.span, msg, try self.suggestSymbol(name));
                return null;
            },
            .self_expr => |se| {
                if (self.current_class_name) |cn| {
                    // `self` is a value of the enclosing class type.
                    return try types.mkNamed(self.arena, cn, se.span);
                }
                return null;
            },
            .super_expr => |se| {
                if (self.current_class_extends) |ext| {
                    return try types.mkNamed(self.arena, self.lexeme(ext), ext);
                }
                try self.emitSpan("E_UNDEFINED_SYMBOL", se.span, "`super` is only valid inside a method of a class that extends a parent");
                return null;
            },
            .paren => |p| return try self.inferExpr(p.inner, hint),
            .unary => |u| return try operators.checkUnary(self, u, hint),
            .binary => |b| return try operators.checkBinary(self, b, hint),
            .range => |r| {
                _ = try self.inferExpr(r.start, null);
                _ = try self.inferExpr(r.end, null);
                return null;
            },
            .call => |c| return try calls.checkCall(self, c, hint),
            .method_call => |m| {
                // `mem.X(args)` parses as a method call on the
                // synthetic `mem` module — dispatch through the
                // stdlib resolver rather than the class-method path.
                if (m.receiver.* == .ident) {
                    const recv_name = self.lexeme(m.receiver.ident.span);
                    if (std.mem.eql(u8, recv_name, "mem")) {
                        return try fields.checkMemMethodCall(self, m);
                    }
                }
                const recv_ty = try self.inferExpr(m.receiver, null);
                try self.checkNotNullableDeref(m.receiver, recv_ty, m.span);
                return try fields.checkMethodCall(self, m, peelReference(recv_ty));
            },
            .field => |f| {
                // Special receivers (recognized before generic
                // field resolution since their "receiver" is a
                // module / type name rather than a value):
                //   - `EnumName.Variant` — variant constructor.
                //   - `mem.func`         — stdlib builtin.
                if (f.receiver.* == .ident) {
                    const recv_name = self.lexeme(f.receiver.ident.span);
                    if (self.enum_registry.get(recv_name)) |ed| {
                        return try fields.resolveEnumVariant(self, ed, recv_name, f);
                    }
                    if (std.mem.eql(u8, recv_name, "mem")) {
                        return try fields.resolveMemBuiltin(self, f);
                    }
                }
                const recv_ty = try self.inferExpr(f.receiver, null);
                try self.checkNotNullableDeref(f.receiver, recv_ty, f.span);
                return try fields.resolveFieldAccess(self, f, peelReference(recv_ty));
            },
            .index => |ix| {
                _ = try self.inferExpr(ix.receiver, null);
                _ = try self.inferExpr(ix.index, null);
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

                // `@no_capture` tracking: when the enclosing fn is
                // marked, collect THIS lambda's local names so
                // `checkAssign` / `checkIncDec` can flag captured-
                // and-mutated bindings.
                const saved_locals = self.lambda_locals;
                if (self.in_no_capture) self.lambda_locals = .{};
                defer self.lambda_locals = saved_locals;

                // Bidirectional hint: when the lambda flows into
                // a function-typed slot (`let f: fn(...) -> R = ||
                // ...`), use the hint's param + return types to
                // refine any unannotated lambda slots. Lets a
                // bare `|| 99` infer as `fn() -> i16` when the
                // target binding declares that shape.
                const hint_fn: ?types.Function = if (hint) |h|
                    (if (h.* == .function) h.function else null)
                else
                    null;
                var param_types: std.ArrayList(*const types.Type) = .empty;
                errdefer param_types.deinit(self.arena);
                for (l.params, 0..) |p, i| {
                    const pt: *const types.Type = if (p.type_ann) |t|
                        try type_resolve.resolveType(self, t)
                    else if (hint_fn) |hf|
                        if (i < hf.params.len) hf.params[i] else try self.primitive(.nil_)
                    else
                        try self.primitive(.nil_);
                    try self.registerName(self.lexeme(p.name), .{
                        .kind = .param,
                        .decl_span = p.name,
                        .ty = pt,
                    });
                    try param_types.append(self.arena, pt);
                }
                const ret_ty: *const types.Type = if (l.ret_type) |r|
                    try type_resolve.resolveType(self, r)
                else if (hint_fn) |hf|
                    hf.ret
                else
                    try self.primitive(.nil_);
                // Swap current_ret_ty so `return expr` inside the
                // lambda body checks against the lambda's own
                // return type rather than the enclosing fn's.
                const saved_ret = self.current_ret_ty;
                self.current_ret_ty = ret_ty;
                defer self.current_ret_ty = saved_ret;
                for (l.body) |s| try self.walkStatement(s);
                const sig = try self.arena.create(types.Type);
                sig.* = .{ .function = .{
                    .params = try param_types.toOwnedSlice(self.arena),
                    .ret = ret_ty,
                } };
                return sig;
            },
            .list_lit => |ll| return try self.inferListLit(ll, hint),
            .list_repeat => |lr| return try self.inferListRepeat(lr, hint),
            .struct_lit => |sl| return try fields.checkStructLit(self, sl),
            .tuple_lit => |tl| {
                // Bidirectional: when the hint is a same-arity
                // tuple, each element pins to its slot's expected
                // type so `(0, nil)` against `(i16, str?)` works.
                const slot_hints: ?[]const *const types.Type = if (hint) |h|
                    if (h.* == .tuple and h.tuple.len == tl.elems.len) h.tuple else null
                else
                    null;
                var elems: std.ArrayList(*const types.Type) = .empty;
                errdefer elems.deinit(self.arena);
                for (tl.elems, 0..) |x, i| {
                    const slot_hint: ?*const types.Type = if (slot_hints) |sh| sh[i] else null;
                    const t = try self.inferExpr(x, slot_hint) orelse return null;
                    try elems.append(self.arena, t);
                }
                const out = try self.arena.create(types.Type);
                out.* = .{ .tuple = try elems.toOwnedSlice(self.arena) };
                return out;
            },
            .is_test => |it| return try self.checkIsTest(it),
            .cast => |c| return try operators.checkCast(self, c),
            .ref_of => |r| return try self.checkRefOf(r),
            .sizeof => |s| {
                // `sizeof(T)` resolves T to validate the annotation
                // is real (so unknown names emit `E_TYPE_UNDEFINED`).
                // The numeric width is computed at codegen.
                _ = try type_resolve.resolveType(self, s.type_ann);
                return try self.primitive(.u16);
            },
        }
    }

    // ---------- nullable / reference checks ----------

    /// Emit `E_NULL_DEREF` when the receiver of `.field` /
    /// `.method()` is statically nullable and not in the
    /// flow-known non-nil set.
    fn checkNotNullableDeref(
        self: *Checker,
        receiver: *const ast.Expr,
        recv_ty: ?*const types.Type,
        access_span: ast.Span,
    ) WalkError!void {
        const rt = recv_ty orelse return;
        if (rt.* != .optional) return;
        if (flow.identName(self, receiver)) |name| {
            if (self.non_nil.contains(name)) return;
        }
        const ty_s = try types.render(self.arena, rt.*);
        const msg = try std.fmt.allocPrint(
            self.arena,
            "dereferencing nullable `{s}` without a prior nil-check",
            .{ty_s},
        );
        try self.emitSpan("E_NULL_DEREF", access_span, msg);
    }

    /// `lhs is X` — type-check both shapes (variant tag test +
    /// class-type probe) and apply the receiver-type rules from
    /// `docs/lang-diagnostics.md` §3.6.
    ///
    /// Always returns `bool`. Walks the lhs even on rejection so
    /// nested diagnostics still surface.
    fn checkIsTest(self: *Checker, it: ast.IsTestExpr) WalkError!?*const types.Type {
        const lhs_ty = try self.inferExpr(it.lhs, null);
        const bool_ty = try self.primitive(.bool_);
        switch (it.kind) {
            .variant => return bool_ty,
            .class_type => |probe| {
                const class_name = self.lexeme(probe.class_name);
                if (!self.class_registry.contains(class_name)) {
                    const msg = try std.fmt.allocPrint(self.arena, "undefined class `{s}`", .{class_name});
                    try self.emitSpanWithSuggestion("E_TYPE_UNDEFINED", probe.class_name, msg, try self.suggestTypeName(class_name));
                    return bool_ty;
                }
                const recv = lhs_ty orelse return bool_ty;
                const peeled = if (recv.* == .reference) recv.reference else recv;
                if (peeled.* != .named) {
                    try self.emitSpan(
                        "E_TYPE_IS_NON_DYNAMIC",
                        it.span,
                        "`is` requires a class-typed receiver (struct and primitive types have no runtime type identity)",
                    );
                    return bool_ty;
                }
                const recv_name = peeled.named.name;
                // Struct receiver — `is` has no meaning (no vtable).
                if (self.struct_registry.contains(recv_name)) {
                    try self.emitSpan(
                        "E_TYPE_IS_NON_DYNAMIC",
                        it.span,
                        "`is` requires a class-typed receiver — structs have no runtime type identity (use an enum tag instead)",
                    );
                    return bool_ty;
                }
                const recv_class = self.class_registry.get(recv_name) orelse {
                    try self.emitSpan(
                        "E_TYPE_IS_NON_DYNAMIC",
                        it.span,
                        "`is` requires a class-typed receiver",
                    );
                    return bool_ty;
                };
                // Decide statically when the relationship is fixed.
                if (std.mem.eql(u8, recv_name, class_name) or isAncestorOf(self, class_name, recv_class)) {
                    const msg = try std.fmt.allocPrint(self.arena, "`{s} is {s}` is always true — the static type of the receiver already guarantees this", .{ recv_name, class_name });
                    try self.diagnostics.append(self.diag_alloc, .{
                        .severity = .warning,
                        .code = "W_DEAD_TEST",
                        .message = msg,
                        .span = it.span,
                    });
                } else {
                    const target = self.class_registry.get(class_name).?;
                    if (!isAncestorOf(self, recv_name, target)) {
                        const msg = try std.fmt.allocPrint(self.arena, "`{s} is {s}` is always false — `{s}` is not in `{s}`'s ancestor chain", .{ recv_name, class_name, class_name, recv_name });
                        try self.diagnostics.append(self.diag_alloc, .{
                            .severity = .warning,
                            .code = "W_DEAD_TEST",
                            .message = msg,
                            .span = it.span,
                        });
                    }
                }
                return bool_ty;
            },
        }
    }

    /// `true` when `target_name` is an ancestor of `cd` (i.e. `cd`
    /// extends `target_name` somewhere in its parent chain).
    fn isAncestorOf(self: *const Checker, target_name: []const u8, cd: *const ast.ClassDecl) bool {
        var cur: ?*const ast.ClassDecl = cd;
        while (cur) |c| {
            const ext = c.extends orelse return false;
            const parent_name = self.lexeme(ext);
            if (std.mem.eql(u8, parent_name, target_name)) return true;
            cur = self.class_registry.get(parent_name);
        }
        return false;
    }

    /// `&x` — verify the inner is a place expression and not
    /// already a reference type.
    fn checkRefOf(self: *Checker, r: ast.RefOfExpr) WalkError!?*const types.Type {
        if (!isPlaceExpr(r.inner)) {
            try self.emitSpan("E_REF_TEMPORARY", r.span, "cannot take a reference to a temporary value (only places — ident, field, or index — have addresses)");
            _ = try self.inferExpr(r.inner, null);
            return null;
        }
        const inner = try self.inferExpr(r.inner, null) orelse return null;
        if (inner.* == .reference) {
            try self.emitSpan("E_REF_DOUBLE", r.span, "`&&T` is not a valid type — references do not nest");
            return inner;
        }
        return try types.mkReference(self.arena, inner);
    }

    /// `nil` literal type — honors the `hint` to emit specific codes
    /// when used against an incompatible target.
    fn inferNilLit(self: *Checker, lit: ast.SpanOnly, hint: ?*const types.Type) WalkError!?*const types.Type {
        if (hint) |h| {
            switch (h.*) {
                .optional => return h,
                .primitive => |p| if (p == .nil_) return try self.primitive(.nil_),
                .reference => {
                    try self.emitSpan("E_REF_NULLABLE", lit.span, "`nil` is not a valid reference value — use `T?` for nullable bindings");
                    return h;
                },
                else => {},
            }
            const ty_s = try types.render(self.arena, h.*);
            const msg = try std.fmt.allocPrint(
                self.arena,
                "cannot use `nil` where `{s}` is expected",
                .{ty_s},
            );
            try self.emitSpan("E_NULL_NIL_TO_NONNULL", lit.span, msg);
            return h;
        }
        return try self.primitive(.nil_);
    }

    // ---------- literal inference with bidirectional hint ----------

    fn inferIntLit(self: *Checker, lit: ast.IntLitExpr, hint: ?*const types.Type) WalkError!?*const types.Type {
        // Bidirectional: pin to hint when the hint is an integer-like
        // primitive. Range-check the literal against the pinned width.
        if (hint) |h| if (h.* == .primitive) {
            const p = h.primitive;
            if (predicates.isIntegerPrimitive(p)) {
                if (!predicates.intLitFits(lit.value, p)) {
                    const msg = try std.fmt.allocPrint(
                        self.arena,
                        "literal `{d}` does not fit in `{s}`",
                        .{ lit.value, predicates.primitiveName(p) },
                    );
                    try self.emitSpan("E_TYPE_MISMATCH", lit.span, msg);
                }
                return try self.primitive(p);
            }
        };
        // Default for unpinned int literals: i16 (`int`).
        return try self.primitive(.i16);
    }

    fn inferListLit(self: *Checker, ll: ast.ListLit, hint: ?*const types.Type) WalkError!?*const types.Type {
        // Hint may be `[T; N]` or `Vec(T)` — propagate the elem type.
        const elem_hint: ?*const types.Type = if (hint) |h| switch (h.*) {
            .array => |a| a.elem,
            .vec => |v| v,
            else => null,
        } else null;
        var first_ty: ?*const types.Type = null;
        for (ll.elems) |x| {
            const t = try self.inferExpr(x, elem_hint);
            if (first_ty == null) first_ty = t;
        }
        if (first_ty) |t| {
            return try types.mkArray(self.arena, t, @intCast(ll.elems.len));
        }
        return null;
    }

    fn inferListRepeat(self: *Checker, lr: ast.ListRepeatLit, hint: ?*const types.Type) WalkError!?*const types.Type {
        const elem_hint: ?*const types.Type = if (hint) |h| switch (h.*) {
            .array => |a| a.elem,
            .vec => |v| v,
            else => null,
        } else null;
        const v_ty = try self.inferExpr(lr.value, elem_hint);
        _ = try self.inferExpr(lr.count, null);
        if (v_ty) |t| {
            const len_val: u32 = if (lr.count.* == .int_lit)
                // safety: array-repeat count parsed as i32; §3.4 requires non-negative comptime int. Slice 3+ will range-check; bit-cast preserves bytes.
                @bitCast(lr.count.int_lit.value)
            else
                0;
            return try types.mkArray(self.arena, t, len_val);
        }
        return null;
    }
};

// ---------- module-level helpers ----------

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

fn structLitMentions(c: *const Checker, lit_fields: []const ast.StructLitField, name: []const u8) bool {
    for (lit_fields) |f| if (c.exprMentions(f.value, name)) return true;
    return false;
}

// ---------- builtin name reservation ----------

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

// ---------- place expression check ----------

/// `true` when `e` is a valid assignment target — `ident`, `field`,
/// `index`, or any of those wrapped in `paren`. Function-call results,
/// arithmetic, literals, etc. are not place expressions.
fn isPlaceExpr(e: *const ast.Expr) bool {
    return switch (e.*) {
        .ident, .field, .index => true,
        .paren => |p| isPlaceExpr(p.inner),
        else => false,
    };
}

/// Peel one `&T` layer so field / method resolution sees the pointee
/// type. Per spec §3.4.4, references auto-deref for `.field` and
/// `.method()`. `&&T` is rejected at `checkRefOf`, so a single peel
/// suffices. Pass-through for non-reference and `null` inputs.
fn peelReference(t: ?*const types.Type) ?*const types.Type {
    const ty = t orelse return null;
    return if (ty.* == .reference) ty.reference else ty;
}
