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
    /// Whole-program variadic facts keyed by `def` name (§4.6.2):
    /// element type + distinct call-site arities. Codegen emits one
    /// specialization per arity. Backed by `type_arena`.
    variadics: std.StringHashMapUnmanaged(VariadicInfo),
    /// Type of every named binding, keyed by the start offset of its
    /// declaring identifier. Codegen has the initializer's type from
    /// `expr_types`, but a destructured binder has no expression of
    /// its own — this is where its type comes from. Backed by
    /// `type_arena`.
    binder_types: std.AutoHashMapUnmanaged(u32, *const types.Type),
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

    /// Element type `T` of variadic `def` `name`, or `null` if `name`
    /// isn't a (called) variadic def.
    pub fn variadicElem(self: *const CheckedProgram, name: []const u8) ?*const types.Type {
        return (self.variadics.get(name) orelse return null).elem;
    }

    /// Distinct call-site arities of variadic `def` `name` (empty when
    /// it isn't a called variadic def). One codegen specialization each.
    pub fn variadicArities(self: *const CheckedProgram, name: []const u8) []const u32 {
        const info = self.variadics.get(name) orelse return &.{};
        return info.arities.items;
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
    return typecheckModule(allocator, source, program, null);
}

/// Type-check a fused multi-file `program`, resolving `use X as Y`
/// quoted-path aliases through `import_aliases` (`Y` → `X`). The
/// single-file `typecheck` is this with no aliases.
pub fn typecheckModule(
    allocator: std.mem.Allocator,
    source: []const u8,
    program: *const ast.Program,
    import_aliases: ?*const std.StringHashMapUnmanaged([]const u8),
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
        .lambda_ret_sink = null,
        .current_variadic_param = null,
        .in_static_method = false,
        .current_class_extends = null,
        .current_class_name = null,
        .non_nil = .{},
        .binder_types = .{},
        .enum_registry = .{},
        .struct_registry = .{},
        .class_registry = .{},
        .def_registry = .{},
        .variadic_info = .{},
        .deferred_variadic = .empty,
        .deferred_variadic_methods = .empty,
        .mmio_names = .{},
        .fn_locals = null,
        .tuple_correlations = .{},
        .in_bake = false,
        .in_no_capture = false,
        .lambda_locals = null,
        .expr_types = &expr_types,
        .import_aliases = import_aliases,
        .selective_stdlib = .{},
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

    // A module body is declarations only (§7.1) — code that should run
    // at startup lives in `main` or what it calls. Reject anything else
    // here rather than in codegen, which silently dropped it.
    for (program.statements) |stmt| try c.rejectNonDeclaration(stmt);

    // Pass 1: register top-level decls so forward references resolve.
    for (program.statements) |stmt| try c.registerTopLevel(stmt);

    // Pass 2: walk + resolve + infer + check.
    try c.walkStatementSequence(program.statements);

    // Pass 3: type-check variadic bodies against the whole-program
    // `args: (T, …, T)` tuple their call sites pinned (§4.6.2).
    try class_check.resolveDeferredVariadics(&c);

    return .{
        .program = program,
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
        .expr_types = expr_types,
        .variadics = c.variadic_info,
        .binder_types = c.binder_types,
        .type_arena = arena,
        .allocator = allocator,
    };
}

const mem_builtin = @import("typecheck/mem_builtin.zig");
const stdlib = @import("typecheck/stdlib.zig");
const match = @import("typecheck/match.zig");
const vec_builtin = @import("typecheck/vec_builtin.zig");
const str_builtin = @import("typecheck/str_builtin.zig");
const fmtspec = @import("fmtspec.zig");
const predicates = @import("typecheck/predicates.zig");
const annotations = @import("typecheck/annotations.zig");
const relations = @import("typecheck/relations.zig");
const flow = @import("typecheck/flow.zig");
const suggestions = @import("typecheck/suggestions.zig");
const type_resolve = @import("typecheck/type_resolve.zig");
const fields = @import("typecheck/fields.zig");
const operators = @import("typecheck/operators.zig");
const diag_check = @import("typecheck/diagnostics.zig");
const decls = @import("typecheck/decls.zig");
const class_check = @import("typecheck/class_check.zig");
const calls = @import("typecheck/calls.zig");

const T = annotations.T;

/// Whole-program variadic facts for one variadic `def` (§4.6.2): the
/// unified element type `T` across its call sites, the *smallest* arity
/// seen, and the set of distinct arities. The body type-checks once
/// against `args: (T, …, T)` of `min_arity` — an index valid only for a
/// larger call is rejected, since the smallest call cannot supply it.
/// Codegen emits one specialization per entry of `arities`. `min_arity`
/// is null until the first call site is recorded.
pub const VariadicInfo = struct {
    elem: ?*const types.Type = null,
    min_arity: ?u32 = null,
    arities: std.ArrayListUnmanaged(u32) = .empty,
};

/// A variadic method whose body is deferred until call sites pin its
/// `T` + arity (§4.6.2). Carries the declaring class so the deferred
/// walk can re-establish the method's scope (`self`, fields, `super`).
pub const DeferredMethod = struct {
    class: *const ast.ClassDecl,
    method: *const ast.DefDecl,
};

/// One `return <expr>` seen while inferring a lambda's return type:
/// the value's type plus the span to blame if a later `return`
/// disagrees with the first one.
const ReturnSample = struct {
    ty: *const types.Type,
    span: ast.Span,
};

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
    /// Sink for `return` types while inferring an unannotated lambda's
    /// return type (§4.7.1). Non-null only inside such a body; saved
    /// and restored around the walk like `current_ret_ty`.
    lambda_ret_sink: ?*std.ArrayList(ReturnSample),
    /// Name of the trailing `args` slot while type-checking a variadic
    /// body, else `null`. Lets an out-of-range `args.N` report against
    /// the call-site minimum arity rather than a bare tuple width.
    current_variadic_param: ?[]const u8,
    /// `true` while checking a `@static` method body — `self` / `super`
    /// are unavailable there (no receiver), so referencing either errors.
    in_static_method: bool,
    /// `extends Parent` span when inside a class method. `null`
    /// elsewhere. Drives `super` resolution.
    current_class_extends: ?ast.Span,
    /// Enclosing class name when inside a class method. Drives
    /// `self` type resolution.
    current_class_name: ?[]const u8,
    /// Identifiers statically known non-nil in the current flow.
    /// Populated by simple nil-check pattern matching.
    non_nil: std.StringHashMapUnmanaged(void),
    /// Binder-name type map built during registration — see
    /// `CheckedProgram.binder_types`.
    binder_types: std.AutoHashMapUnmanaged(u32, *const types.Type),
    /// Enum-name → decl pointer (pass 1).
    enum_registry: std.StringHashMapUnmanaged(*const ast.EnumDecl),
    /// Struct-name → decl pointer.
    struct_registry: std.StringHashMapUnmanaged(*const ast.StructDecl),
    /// Class-name → decl pointer.
    class_registry: std.StringHashMapUnmanaged(*const ast.ClassDecl),
    /// Top-level `def` name → decl pointer.
    def_registry: std.StringHashMapUnmanaged(*const ast.DefDecl),
    /// Variadic `def` name → its whole-program element type `T` + the max
    /// arity seen across call sites (§4.6.2). Accumulated by
    /// `checkVariadicCall` during the main walk; consumed by the deferred
    /// pass that type-checks each variadic body with `args: (T, …, T)`.
    variadic_info: std.StringHashMapUnmanaged(VariadicInfo),
    /// Variadic defs whose bodies are deferred until `variadic_info` is
    /// fully populated (the element type comes from call sites).
    deferred_variadic: std.ArrayListUnmanaged(*const ast.DefDecl),
    /// Variadic methods whose bodies are deferred — same rule as
    /// `deferred_variadic`, but each carries its declaring class so the
    /// deferred walk restores the method scope.
    deferred_variadic_methods: std.ArrayListUnmanaged(DeferredMethod),
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
    /// `use X as Y from "./mod"` aliases (`Y` → `X`) from the fuser,
    /// or `null` for a single-file check. A top-level name lookup
    /// resolves through this first so an alias binds like its target.
    import_aliases: ?*const std.StringHashMapUnmanaged([]const u8),
    /// Selectively-imported stdlib function (`use rng from math`):
    /// the local name (alias or original) → its `(module, real_name)`.
    /// Lets a bare call lower to the stdlib signature.
    selective_stdlib: std.StringHashMapUnmanaged(StdlibImport),

    /// A stdlib function pulled into scope by a selective `use`.
    pub const StdlibImport = struct { module: []const u8, name: []const u8 };

    /// Resolve a quoted-path import alias to the real exported name;
    /// identity when `name` isn't an alias.
    pub fn resolveImportAlias(self: *const Checker, name: []const u8) []const u8 {
        const aliases = self.import_aliases orelse return name;
        return aliases.get(name) orelse name;
    }

    /// Like `resolveImportAlias`, but in value position: a real binding
    /// (local / param / global) of the same name shadows the alias, so
    /// the alias applies only when `raw` isn't already in scope.
    pub fn resolveValueAlias(self: *const Checker, raw: []const u8) []const u8 {
        if (self.current_scope.lookup(raw) != null) return raw;
        return self.resolveImportAlias(raw);
    }

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

    // ---------- diagnostic helpers (delegated to typecheck/diagnostics.zig) ----------

    /// Delegated to `typecheck/diagnostics.zig`.
    pub fn emitSpan(
        self: *Checker,
        code: []const u8,
        span: ast.Span,
        message: []const u8,
    ) WalkError!void {
        return diag_check.emitSpan(self, code, span, message);
    }

    /// Delegated to `typecheck/diagnostics.zig`.
    pub fn emitSpanHelp(
        self: *Checker,
        code: []const u8,
        span: ast.Span,
        message: []const u8,
        help: []const u8,
    ) WalkError!void {
        return diag_check.emitSpanHelp(self, code, span, message, help);
    }

    /// Delegated to `typecheck/diagnostics.zig`.
    pub fn emitMismatch(
        self: *Checker,
        span: ast.Span,
        expected_ty: *const types.Type,
        actual_ty: *const types.Type,
    ) WalkError!void {
        return diag_check.emitMismatch(self, span, expected_ty, actual_ty);
    }

    /// Delegated to `typecheck/diagnostics.zig`.
    pub fn emitMismatchAnnotated(
        self: *Checker,
        span: ast.Span,
        expected_ty: *const types.Type,
        actual_ty: *const types.Type,
        annotation_span: ast.Span,
    ) WalkError!void {
        return diag_check.emitMismatchAnnotated(self, span, expected_ty, actual_ty, annotation_span);
    }

    /// Delegated to `typecheck/diagnostics.zig`.
    pub fn singleSecondary(
        self: *Checker,
        span: ast.Span,
        message: []const u8,
        decoration: diag_mod.SpanLabel.Decoration,
    ) WalkError![]const diag_mod.SpanLabel {
        return diag_check.singleSecondary(self, span, message, decoration);
    }

    /// Delegated to `typecheck/diagnostics.zig`.
    pub fn checkStoreCompat(
        self: *Checker,
        span: ast.Span,
        expected: *const types.Type,
        actual: *const types.Type,
    ) WalkError!void {
        return diag_check.checkStoreCompat(self, span, expected, actual);
    }

    /// Delegated to `typecheck/diagnostics.zig`.
    pub fn isClassSubtype(self: *const Checker, actual: types.Type, expected: types.Type) bool {
        return diag_check.isClassSubtype(self, actual, expected);
    }

    /// Delegated to `typecheck/diagnostics.zig`.
    pub fn lexeme(self: *const Checker, span: ast.Span) []const u8 {
        return diag_check.lexeme(self, span);
    }

    /// The variadic `args` slot name when `e` is a bare reference to it
    /// inside the variadic body currently being checked, else `null`.
    fn variadicReceiverName(self: *const Checker, e: *const ast.Expr) ?[]const u8 {
        const vp = self.current_variadic_param orelse return null;
        const name = flow.identName(self, e) orelse return null;
        return if (std.mem.eql(u8, name, vp)) vp else null;
    }

    /// Delegated to `typecheck/diagnostics.zig`.
    pub fn suggestSymbol(self: *Checker, name: []const u8) WalkError!?[]const u8 {
        return diag_check.suggestSymbol(self, name);
    }

    /// Delegated to `typecheck/diagnostics.zig`.
    pub fn suggestTypeName(self: *Checker, name: []const u8) WalkError!?[]const u8 {
        return diag_check.suggestTypeName(self, name);
    }

    /// Delegated to `typecheck/diagnostics.zig`.
    pub fn suggestStructField(self: *Checker, sd: *const ast.StructDecl, name: []const u8) WalkError!?[]const u8 {
        return diag_check.suggestStructField(self, sd, name);
    }

    /// Delegated to `typecheck/diagnostics.zig`.
    pub fn suggestClassField(self: *Checker, cd: *const ast.ClassDecl, name: []const u8) WalkError!?[]const u8 {
        return diag_check.suggestClassField(self, cd, name);
    }

    /// Delegated to `typecheck/diagnostics.zig`.
    pub fn suggestClassMethod(self: *Checker, cd: *const ast.ClassDecl, name: []const u8) WalkError!?[]const u8 {
        return diag_check.suggestClassMethod(self, cd, name);
    }

    /// Delegated to `typecheck/diagnostics.zig`.
    pub fn emitSpanWithSuggestion(
        self: *Checker,
        code: []const u8,
        span: ast.Span,
        message: []const u8,
        candidate: ?[]const u8,
    ) WalkError!void {
        return diag_check.emitSpanWithSuggestion(self, code, span, message, candidate);
    }
    // ---------- Pass 1: top-level decl registration ----------

    // ---------- Pass 1: top-level decl registration (delegated to typecheck/decls.zig) ----------

    /// Delegated to `typecheck/decls.zig`.
    pub fn registerTopLevel(self: *Checker, s: ast.Statement) WalkError!void {
        return decls.registerTopLevel(self, s);
    }

    /// Delegated to `typecheck/decls.zig`.
    pub fn registerName(
        self: *Checker,
        name: []const u8,
        info: scope_mod.SymbolInfo,
    ) WalkError!void {
        return decls.registerName(self, name, info);
    }

    /// Delegated to `typecheck/decls.zig`.
    pub fn signatureFromDef(self: *Checker, d: ast.DefDecl) WalkError!*const types.Type {
        return decls.signatureFromDef(self, d);
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
            .struct_decl => |sd| {
                try annotations.validateAnnotations(self, sd.annotations, T.STRUCT);
                try self.checkStructFinite(sd);
            },
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

    /// Type of a `do … end` value block (§4.3): the body runs in a fresh
    /// scope and the block evaluates to its last expression's type (or
    /// `nil` if the last item is a statement). A trailing bare `do … end`
    /// is itself a value block, so descend into it.
    fn doBlockType(self: *Checker, body: []const ast.Statement, hint: ?*const types.Type) WalkError!?*const types.Type {
        const saved = self.current_scope;
        var child: Scope = .init(self.arena, saved);
        self.current_scope = &child;
        defer self.current_scope = saved;
        if (body.len == 0) return try self.primitive(.nil_);
        try self.walkStatementSequence(body[0 .. body.len - 1]);
        return switch (body[body.len - 1]) {
            .expr_stmt => |es| try self.inferExpr(es.expr, hint),
            .block => |b| try self.doBlockType(b.body, hint),
            else => blk: {
                try self.walkStatement(body[body.len - 1]);
                break :blk try self.primitive(.nil_);
            },
        };
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

    /// Source-level name for a statement, for diagnostics that would
    /// otherwise print an AST tag at the user.
    fn statementNoun(stmt: ast.Statement) []const u8 {
        return switch (stmt) {
            .print_stmt => "a `print`",
            .expr_stmt => "an expression statement",
            .assign => "an assignment",
            .inc_dec => "an increment / decrement",
            .discard => "a discard",
            .if_stmt => "an `if`",
            .while_stmt => "a `while`",
            .for_stmt => "a `for`",
            .repeat_stmt => "a `repeat`",
            .match_stmt => "a `match`",
            .return_stmt => "a `return`",
            .break_stmt => "a `break`",
            .continue_stmt => "a `continue`",
            .block => "a block",
            .asm_stmt => "an `asm` block",
            .defer_stmt => "a `defer`",
            else => "this statement",
        };
    }

    /// §7.1: a module body holds `def` / `class` / `struct` / `enum` /
    /// `const` / `let` / `use` and nothing else. An executable statement
    /// at module scope never runs — execution begins at `main` — so it
    /// is rejected here instead of being dropped during lowering.
    fn rejectNonDeclaration(self: *Checker, stmt: ast.Statement) WalkError!void {
        switch (stmt) {
            .def_decl,
            .class_decl,
            .struct_decl,
            .enum_decl,
            .const_decl,
            .let_decl,
            .use_decl,
            => {},
            else => {
                const msg = try std.fmt.allocPrint(
                    self.arena,
                    "{s} at module scope never runs — a module body is declarations only (§7.1); move it into `main` or a function it calls",
                    .{statementNoun(stmt)},
                );
                try self.emitSpan("E_TYPE_TOP_LEVEL_STATEMENT", stmt.span(), msg);
            },
        }
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
            // `checkStoreCompat` path.
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
        // A `let` pattern must be irrefutable (§4.2) — a literal / range /
        // multi-variant enum can't be guaranteed to match. Surface a
        // diagnostic and still bind so the body type-checks.
        if (d.pattern.* != .ident and self.isRefutable(d.pattern)) {
            try self.emitSpan("E_TYPE_REFUTABLE_LET", d.pattern.span(), "refutable pattern in `let` — use `if let` or `match` for a pattern that can fail to match");
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
            else => try self.registerBindingsFromType(d.pattern, ann_ty orelse init_ty),
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
            if (arm.cond) |c| try self.requireBool(c);
            const let_ty: ?*const types.Type = if (arm.let_expr) |e| try self.inferExpr(e, null) else null;

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

            // `if let PAT = expr [when guard]` binds PAT for the guard
            // and the arm body. Open a child scope and register the
            // bindings first — mirrors match-arm scoping — so the guard
            // and body resolve the names (§4.4.1).
            const saved = self.current_scope;
            var child: Scope = .init(self.arena, saved);
            self.current_scope = &child;
            defer self.current_scope = saved;
            if (arm.let_pattern) |pat| try self.registerBindingsFromType(pat, let_ty);
            if (arm.let_guard) |g| try self.requireBool(g);
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
        if (ws.cond) |c| try self.requireBool(c);
        const let_ty: ?*const types.Type = if (ws.let_expr) |e| try self.inferExpr(e, null) else null;
        // `while let PAT = expr [when guard]` binds PAT for the guard
        // and loop body — same scoping as `if let` / match arms.
        const saved = self.current_scope;
        var child: Scope = .init(self.arena, saved);
        self.current_scope = &child;
        defer self.current_scope = saved;
        if (ws.let_pattern) |pat| try self.registerBindingsFromType(pat, let_ty);
        if (ws.let_guard) |g| try self.requireBool(g);
        try self.walkStatementSequence(ws.body);
    }

    /// Validate a `$(expr:fmt)` format spec (§3.2.2) against the value's
    /// type — well-formed, scalar-only, and its type letter + precision
    /// compatible with the value. Emits `E_TYPE_BAD_FORMAT_SPEC`.
    fn validateFormatSpec(self: *Checker, ty: ?*const types.Type, span: ast.Span) WalkError!void {
        const spec = fmtspec.parse(self.lexeme(span)) catch {
            try self.emitSpan("E_TYPE_BAD_FORMAT_SPEC", span, "malformed format spec — expected `[align][fill][width][.precision][type]`");
            return;
        };
        const t = ty orelse return;
        const peeled = if (t.* == .reference) t.reference else t;
        if (peeled.* != .primitive) {
            try self.emitSpan("E_TYPE_BAD_FORMAT_SPEC", span, "a format spec applies to scalar (primitive) values only");
            return;
        }
        const prim = peeled.primitive;
        const int_like = switch (prim) {
            .i8, .u8, .i16, .u16, .char, .bool_ => true,
            else => false,
        };
        const compatible = switch (spec.ty) {
            .default => true,
            .str => prim == .str,
            .dec, .hex_lower, .hex_upper, .bin, .oct, .char => int_like,
        };
        if (!compatible) {
            const ts = try types.render(self.arena, peeled.*);
            const msg = try std.fmt.allocPrint(self.arena, "the format type in this spec is not valid for a `{s}` value", .{ts});
            try self.emitSpan("E_TYPE_BAD_FORMAT_SPEC", span, msg);
            return;
        }
        if (spec.precision != null and prim != .str and prim != .fixed) {
            try self.emitSpan("E_TYPE_BAD_FORMAT_SPEC", span, "precision (`.N`) applies to `str` / `fixed` values only");
        }
    }

    fn checkFor(self: *Checker, fs: ast.ForStmt) WalkError!void {
        const elem_ty = try self.forElementType(fs);
        if (fs.step) |st| _ = try self.inferExpr(st, null);
        const saved = self.current_scope;
        var child: Scope = .init(self.arena, saved);
        self.current_scope = &child;
        defer self.current_scope = saved;
        try self.registerName(self.lexeme(fs.binding), .{
            .kind = .let_binding,
            .decl_span = fs.binding,
            .ty = elem_ty,
        });
        try self.walkStatementSequence(fs.body);
    }

    /// Resolve the loop variable's type from the iterable's element type
    /// (§4.5.3): a range yields its bound type; `[T; N]` / `Vec(T)` yield
    /// `T`; `str` yields `char`; a class with `next(self) -> T?` yields `T`.
    /// A non-iterable operand is `E_TYPE_NOT_ITERABLE` and binds no type.
    fn forElementType(self: *Checker, fs: ast.ForStmt) WalkError!?*const types.Type {
        if (fs.iter.* == .range) {
            // The loop variable takes the range bound's type (`0u8..` → u8).
            const start_ty = try self.inferExpr(fs.iter.range.start, null);
            _ = try self.inferExpr(fs.iter.range.end, null);
            return start_ty orelse try self.primitive(.i16);
        }
        const it_ty = (try self.inferExpr(fs.iter, null)) orelse return null;
        // A `&T` reference iterates the pointed-to aggregate (§3.4.4).
        const peeled = if (it_ty.* == .reference) it_ty.reference else it_ty;
        switch (peeled.*) {
            .array => return peeled.array.elem,
            .vec => return peeled.vec,
            .primitive => |p| if (p == .str) return try self.primitive(.char),
            .named => |n| {
                if (self.class_registry.get(n.name)) |cd| {
                    if (fields.lookupClassMethod(self, cd, "next")) |m| {
                        if (m.ret_type) |rt| {
                            const ret = try type_resolve.resolveType(self, rt);
                            if (ret.* == .optional) return ret.optional;
                        }
                    }
                }
            },
            else => {},
        }
        const rendered = try types.render(self.arena, it_ty.*);
        const msg = try std.fmt.allocPrint(
            self.arena,
            "type `{s}` is not iterable — `for x in …` needs a range, `[T; N]`, `Vec(T)`, `str`, or a class with `next(self) -> T?`",
            .{rendered},
        );
        try self.emitSpan("E_TYPE_NOT_ITERABLE", fs.iter.span(), msg);
        return null;
    }

    fn checkRepeat(self: *Checker, rs: ast.RepeatStmt) WalkError!void {
        try self.walkInScope(rs.body);
        try self.requireBool(rs.cond);
    }

    /// Reject a struct that contains itself by value (directly or
    /// transitively, through a struct / array / tuple field) — such a
    /// type has infinite size and no layout. `Vec` / `&T` / nullable /
    /// fn fields are pointer-width, so they break the cycle legally
    /// (the linked-list / tree idiom).
    fn checkStructFinite(self: *Checker, sd: ast.StructDecl) WalkError!void {
        var visited: std.ArrayList([]const u8) = .empty;
        defer visited.deinit(self.arena);
        const name = self.lexeme(sd.name);
        if (try self.structSizeFinite(name, &visited)) return;
        const msg = try std.fmt.allocPrint(
            self.arena,
            "struct `{s}` is infinitely recursive — it contains itself by value (use `Vec({s})` or `&{s}` for a recursive shape)",
            .{ name, name, name },
        );
        try self.emitSpan("E_TYPE_RECURSIVE_STRUCT", sd.name, msg);
    }

    // `visited` is the current containment path (push on descent, pop on
    // return), so a name reappearing is a by-value cycle — a diamond
    // (the same struct in two sibling fields) is finite and allowed.
    fn structSizeFinite(self: *Checker, sname: []const u8, visited: *std.ArrayList([]const u8)) WalkError!bool {
        for (visited.items) |seen| if (std.mem.eql(u8, seen, sname)) return false;
        const sd = self.struct_registry.get(sname) orelse return true;
        try visited.append(self.arena, sname);
        defer _ = visited.pop();
        for (sd.fields) |f| {
            if (!try self.typeAnnSizeFinite(f.type_ann.*, visited)) return false;
        }
        return true;
    }

    fn typeAnnSizeFinite(self: *Checker, t: ast.TypeAnn, visited: *std.ArrayList([]const u8)) WalkError!bool {
        return switch (t) {
            .named => |n| if (self.struct_registry.contains(self.lexeme(n.name)))
                try self.structSizeFinite(self.lexeme(n.name), visited)
            else
                true, // primitive / enum / class — value or pointer, finite
            .array => |a| try self.typeAnnSizeFinite(a.elem.*, visited),
            .tuple => |xs| blk: {
                for (xs.elems) |e| if (!try self.typeAnnSizeFinite(e.*, visited)) break :blk false;
                break :blk true;
            },
            else => true, // vec / reference / nullable / fn — pointer-width
        };
    }

    /// Type-check an expression in boolean-condition position (an `if` /
    /// `elif` / `while` / `repeat`-`until` condition, or a `when` guard).
    /// The spec has no implicit truthiness (§3) — a non-`bool` condition
    /// is `E_TYPE_MISMATCH`, mirroring how `assert` checks its arg.
    pub fn requireBool(self: *Checker, cond: *const ast.Expr) WalkError!void {
        const bool_ty = try self.primitive(.bool_);
        const ty = try self.inferExpr(cond, bool_ty);
        if (ty != null and !relations.assignable(ty.?.*, bool_ty.*)) {
            try self.emitMismatch(cond.span(), bool_ty, ty.?);
        }
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
            if (self.lambda_ret_sink) |sink| if (v_ty) |vt| {
                try sink.append(self.arena, .{ .ty = vt, .span = v.span() });
            };
            if (self.current_ret_ty) |rt| if (v_ty) |vt| {
                if (!predicates.isNilType(rt.*)) {
                    try self.checkStoreCompat(v.span(), rt, vt);
                }
            };
        }
    }

    /// Return type for a lambda with no annotation and no hint: the
    /// first `return`'s type, with every later `return` checked
    /// against it so a body that returns two different types is
    /// rejected rather than silently taking the first. A body with
    /// no value-returning `return` is `nil`.
    fn inferredLambdaRet(self: *Checker, samples: []const ReturnSample) WalkError!*const types.Type {
        if (samples.len == 0) return try self.primitive(.nil_);
        const first = samples[0].ty;
        for (samples[1..]) |s| try self.checkStoreCompat(s.span, first, s.ty);
        return first;
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

    // ---------- class + def declaration checking (delegated to typecheck/class_check.zig) ----------

    /// Delegated to `typecheck/class_check.zig`.
    pub fn checkDefDecl(self: *Checker, d: ast.DefDecl) WalkError!void {
        return class_check.checkDefDecl(self, d);
    }

    /// Delegated to `typecheck/class_check.zig`.
    pub fn checkClassDecl(self: *Checker, d: ast.ClassDecl) WalkError!void {
        return class_check.checkClassDecl(self, d);
    }

    /// Register every binder a pattern introduces into the current
    /// scope (untyped — the binding's type resolves later). Recurses
    /// through tuple / variant / struct / or-pattern alternatives.
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

    /// Register every binder a pattern introduces, typing each from the
    /// matched value's type `ty`: tuple elements from the tuple's slot
    /// types, struct fields from the declared field types, enum-variant
    /// payload binders from the variant's payload types. Idents bind at
    /// the resolved type; wildcards / literals bind nothing. The
    /// type-propagating, recursive counterpart to `registerPatternBindings`
    /// — used by `if let` / `while let` and `match` arms so no binder is
    /// left `null`-typed (the strong-typing rule).
    pub fn registerBindingsFromType(self: *Checker, pat: *const ast.Pattern, ty: ?*const types.Type) WalkError!void {
        // `if let` / `while let` unwrap an optional (§3.4.1) — bind the
        // pattern against the inner (non-nil) type.
        if (ty) |t| if (t.* == .optional) return self.registerBindingsFromType(pat, t.optional);
        switch (pat.*) {
            .ident => |i| try self.registerName(self.lexeme(i.name), .{
                .kind = .let_binding,
                .decl_span = i.name,
                .ty = ty,
            }),
            .wildcard, .int_lit, .str_lit, .char_lit, .bool_lit, .nil_lit, .range_pattern => {},
            .or_pattern => |o| for (o.alts) |alt| try self.registerBindingsFromType(alt, ty),
            .tuple_pattern => |t| {
                const slots: ?[]const *const types.Type = if (ty) |it|
                    (if (it.* == .tuple and it.tuple.len == t.elems.len) it.tuple else null)
                else
                    null;
                if (slots) |s| {
                    for (t.elems, s) |elem, slot_ty| try self.registerBindingsFromType(elem, slot_ty);
                } else for (t.elems) |elem| try self.registerPatternBindings(elem);
            },
            .struct_pattern => |st| try self.registerStructBindings(st, ty),
            .variant_pattern => |vp| try self.registerVariantBindings(vp, ty),
        }
    }

    /// Type a struct pattern's field binders from the struct's declared
    /// field types — the matched type names the struct (else the pattern's
    /// own type name). An unresolved struct falls back to the untyped walk.
    fn registerStructBindings(self: *Checker, st: ast.StructPattern, ty: ?*const types.Type) WalkError!void {
        const sname: []const u8 = if (ty != null and ty.?.* == .named)
            ty.?.named.name
        else
            self.lexeme(st.type_name);
        const sd = self.struct_registry.get(sname) orelse {
            for (st.fields) |f| try self.registerPatternBindings(f.sub);
            return;
        };
        for (st.fields) |f| {
            const fname = self.lexeme(f.name);
            const fty: ?*const types.Type = blk: {
                for (sd.fields) |df| {
                    if (std.mem.eql(u8, self.lexeme(df.name), fname))
                        break :blk try type_resolve.resolveType(self, df.type_ann);
                }
                break :blk null;
            };
            try self.registerBindingsFromType(f.sub, fty);
        }
    }

    /// Type an enum-variant pattern's payload binders from the variant's
    /// declared payload types — resolving the enum from the matched type,
    /// else the variant path's head. An unresolved enum / variant falls
    /// back to the untyped walk.
    fn registerVariantBindings(self: *Checker, vp: ast.VariantPattern, ty: ?*const types.Type) WalkError!void {
        const ed: ?*const ast.EnumDecl = blk: {
            if (ty) |it| if (self.enumDeclForType(it.*)) |e| break :blk e;
            const head = self.resolveImportAlias(match.splitPath(self.lexeme(vp.path)).head);
            break :blk if (head.len > 0) self.enum_registry.get(head) else null;
        };
        if (ed) |e| {
            const tail = match.splitPath(self.lexeme(vp.path)).tail;
            for (e.variants) |*v| {
                if (!std.mem.eql(u8, self.lexeme(v.name), tail)) continue;
                for (vp.args, 0..) |arg, i| {
                    const aty: ?*const types.Type = if (i < v.payload.len)
                        try type_resolve.resolveType(self, v.payload[i].type_ann)
                    else
                        null;
                    try self.registerBindingsFromType(arg, aty);
                }
                return;
            }
        }
        for (vp.args) |arg| try self.registerPatternBindings(arg);
    }

    /// `true` when `pat` can fail to match its type — a literal / range /
    /// or-pattern, or a multi-variant enum variant, directly or within a
    /// tuple / struct / variant sub-pattern. Drives the `let`-must-be-
    /// irrefutable rule (§4.2).
    fn isRefutable(self: *const Checker, pat: *const ast.Pattern) bool {
        return switch (pat.*) {
            .wildcard, .ident => false,
            .int_lit, .str_lit, .char_lit, .bool_lit, .nil_lit, .range_pattern, .or_pattern => true,
            .tuple_pattern => |t| {
                for (t.elems) |e| if (self.isRefutable(e)) return true;
                return false;
            },
            .struct_pattern => |st| {
                for (st.fields) |f| if (self.isRefutable(f.sub)) return true;
                return false;
            },
            .variant_pattern => |vp| {
                const head = self.resolveImportAlias(match.splitPath(self.lexeme(vp.path)).head);
                const ed = if (head.len > 0) self.enum_registry.get(head) else null;
                // A variant of a multi-variant (or unknown) enum is refutable.
                if (ed == null or ed.?.variants.len != 1) return true;
                for (vp.args) |a| if (self.isRefutable(a)) return true;
                return false;
            },
        };
    }

    /// `true` when `name` appears anywhere in `body` — drives the
    /// no-capture-mutation check + abstract-method implementation scan.
    pub fn bodyMentions(self: *const Checker, body: []const ast.Statement, name: []const u8) bool {
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
            .tuple_index => |ti| self.exprMentions(ti.receiver, name),
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
                    .interp => |ip| {
                        const part_ty = try self.inferExpr(ip.expr, null);
                        if (ip.format_spec) |fs| try self.validateFormatSpec(part_ty, fs);
                    },
                };
                return try self.primitive(.str);
            },
            .ident => |i| {
                const raw = self.lexeme(i.span);
                // A binding for `raw` in the current scope wins — locals
                // shadow imports. Otherwise `raw` may be a quoted-path
                // import alias: its target is a module-level export,
                // looked up at module scope so a local named like the
                // target can't capture it.
                var name = raw;
                var info_opt = self.current_scope.lookup(raw);
                if (info_opt == null) {
                    const target = self.resolveImportAlias(raw);
                    if (!std.mem.eql(u8, target, raw)) {
                        name = target;
                        info_opt = self.module_scope.lookup(target);
                    }
                }
                if (info_opt) |info| {
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
                if (self.in_static_method) {
                    try self.emitSpan("E_STATIC_SELF", se.span, "`self` is not available in a `@static` method — it has no receiver");
                    return null;
                }
                if (self.current_class_name) |cn| {
                    // `self` is a value of the enclosing class type.
                    return try types.mkNamed(self.arena, cn, se.span);
                }
                return null;
            },
            .super_expr => |se| {
                if (self.in_static_method) {
                    try self.emitSpan("E_STATIC_SELF", se.span, "`super` is not available in a `@static` method — it has no receiver");
                    return null;
                }
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
                    const raw_recv = self.lexeme(m.receiver.ident.span);
                    const recv_name = self.resolveValueAlias(raw_recv);
                    if (std.mem.eql(u8, recv_name, "mem")) {
                        return try fields.checkMemMethodCall(self, m);
                    }
                    if (stdlib.isModule(recv_name)) {
                        return try stdlib.checkCall(self, recv_name, m.method, m.args, m.span);
                    }
                    // `str.format(fmt, args)` — str module function.
                    if (std.mem.eql(u8, recv_name, "str")) {
                        return try str_builtin.checkModuleCall(self, m);
                    }
                    // `Vec.new` / `with_capacity` / `from` — Vec constructors.
                    if (std.mem.eql(u8, recv_name, "Vec") and vec_builtin.isConstructor(self.lexeme(m.method))) {
                        return try vec_builtin.checkConstructor(self, m, hint);
                    }
                    // `Enum.Variant(args)` is indistinguishable from a
                    // method call at parse time — resolve it as a
                    // payload-variant constructor.
                    if (self.enum_registry.get(recv_name)) |ed| {
                        return try fields.checkEnumVariantConstruct(self, m, ed, recv_name);
                    }
                    // `ClassName.method(args)` — a `@static` call (the
                    // receiver is a class name, not an instance). A value
                    // binding of the same name shadows the class, so only
                    // route here when the name still resolves to the class.
                    if (self.class_registry.get(recv_name)) |cd| {
                        // Shadowing is judged on the RAW receiver — a local
                        // named like the alias *target* must not mask the
                        // class the alias points at.
                        const is_class_ref = if (self.current_scope.lookup(raw_recv)) |info| info.kind == .class else true;
                        if (is_class_ref) return try fields.checkStaticMethodCall(self, m, cd, recv_name);
                    }
                }
                const recv_ty = try self.inferExpr(m.receiver, null);
                try self.checkNotNullableDeref(m.receiver, recv_ty, m.span);
                // Vec instance method (`v.push` / `v.len` / `v.at` / …).
                if (peelReference(recv_ty)) |peeled| if (peeled.* == .vec) {
                    return try vec_builtin.checkMethod(self, m, peeled.vec);
                };
                // `str` instance method (`s.at` / `s.cmp`).
                if (peelReference(recv_ty)) |peeled| if (peeled.* == .primitive and peeled.primitive == .str) {
                    return try str_builtin.checkMethod(self, m);
                };
                return try fields.checkMethodCall(self, m, peelReference(recv_ty));
            },
            .field => |f| {
                // Special receivers (recognized before generic
                // field resolution since their "receiver" is a
                // module / type name rather than a value):
                //   - `EnumName.Variant` — variant constructor.
                //   - `mem.func`         — stdlib builtin.
                if (f.receiver.* == .ident) {
                    const recv_name = self.resolveValueAlias(self.lexeme(f.receiver.ident.span));
                    if (self.enum_registry.get(recv_name)) |ed| {
                        return try fields.resolveEnumVariant(self, ed, recv_name, f);
                    }
                    if (std.mem.eql(u8, recv_name, "mem")) {
                        return try fields.resolveMemBuiltin(self, f);
                    }
                }
                const recv_ty = try self.inferExpr(f.receiver, null);
                try self.checkNotNullableDeref(f.receiver, recv_ty, f.span);
                // `str` property (`s.len`).
                if (peelReference(recv_ty)) |peeled| if (peeled.* == .primitive and peeled.primitive == .str) {
                    return try str_builtin.checkProperty(self, f);
                };
                return try fields.resolveFieldAccess(self, f, peelReference(recv_ty));
            },
            .tuple_index => |ti| {
                const recv_ty = try self.inferExpr(ti.receiver, null);
                try self.checkNotNullableDeref(ti.receiver, recv_ty, ti.span);
                const peeled = peelReference(recv_ty) orelse return null;
                if (peeled.* != .tuple) {
                    const ty_s = try types.render(self.arena, peeled.*);
                    const msg = try std.fmt.allocPrint(self.arena, "`.{d}` element access requires a tuple, found `{s}`", .{ ti.index, ty_s });
                    try self.emitSpan("E_TYPE_NOT_A_TUPLE", ti.span, msg);
                    return null;
                }
                const elems = peeled.tuple;
                if (ti.index >= elems.len) {
                    const msg = if (self.variadicReceiverName(ti.receiver)) |vname|
                        try std.fmt.allocPrint(self.arena, "`{s}.{d}` is out of range — the smallest call to this variadic function supplies only {d} argument{s}, so index {d} isn't always present", .{ vname, ti.index, elems.len, plural(elems.len), ti.index })
                    else
                        try std.fmt.allocPrint(self.arena, "tuple index {d} out of range — tuple has {d} element{s}", .{ ti.index, elems.len, plural(elems.len) });
                    try self.emitSpan("E_TYPE_TUPLE_INDEX_OOR", ti.span, msg);
                    return null;
                }
                return elems[ti.index];
            },
            .index => |ix| {
                const recv_ty = try self.inferExpr(ix.receiver, null);
                const idx_ty = try self.inferExpr(ix.index, null);
                if (idx_ty) |it| {
                    const is_int = it.* == .primitive and switch (it.primitive) {
                        .i8, .u8, .i16, .u16 => true,
                        else => false,
                    };
                    if (!is_int) {
                        const ty_s = try types.render(self.arena, it.*);
                        const msg = try std.fmt.allocPrint(self.arena, "array index must be an integer, found `{s}`", .{ty_s});
                        try self.emitSpan("E_TYPE_MISMATCH", ix.index.span(), msg);
                    }
                }
                if (peelReference(recv_ty)) |peeled| {
                    if (peeled.* == .array) {
                        // A literal index outside the fixed length is a
                        // compile-time error (runtime indices trap in debug).
                        if (ix.index.* == .int_lit) {
                            const v: i64 = ix.index.int_lit.value;
                            const len: i64 = peeled.array.len;
                            if (v < 0 or v >= len) {
                                const suffix: []const u8 = if (peeled.array.len == 1) "" else "s";
                                const msg = try std.fmt.allocPrint(self.arena, "array index {d} out of range — array has {d} element{s}", .{ v, peeled.array.len, suffix });
                                try self.emitSpan("E_TYPE_INDEX_OOR", ix.index.span(), msg);
                            }
                        }
                        return peeled.array.elem;
                    }
                    // `v[i]` on a `Vec(T)` — element type (length is dynamic,
                    // so no compile-time bounds check; debug-traps at runtime).
                    if (peeled.* == .vec) return peeled.vec;
                }
                return null;
            },
            .do_expr => |d| return try self.doBlockType(d.body, hint),
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
                // An annotation wins; else a function-typed hint
                // supplies it; else it comes from the body's own
                // `return`s (§4.7.1 — "usually inferred").
                const declared: ?*const types.Type = if (l.ret_type) |r|
                    try type_resolve.resolveType(self, r)
                else if (hint_fn) |hf|
                    hf.ret
                else
                    null;

                // Swap current_ret_ty so `return expr` inside the
                // lambda body checks against the lambda's own
                // return type rather than the enclosing fn's. While
                // inferring it's `null`, so `checkReturn` records
                // each return instead of comparing against a type
                // that isn't known yet.
                const saved_ret = self.current_ret_ty;
                self.current_ret_ty = declared;
                defer self.current_ret_ty = saved_ret;

                var samples: std.ArrayList(ReturnSample) = .empty;
                const saved_sink = self.lambda_ret_sink;
                self.lambda_ret_sink = if (declared == null) &samples else null;
                defer self.lambda_ret_sink = saved_sink;

                for (l.body) |s| try self.walkStatement(s);

                const ret_ty = declared orelse try self.inferredLambdaRet(samples.items);
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
                if (tl.elems.len > 4) {
                    const msg = try std.fmt.allocPrint(self.arena, "a tuple has at most 4 elements (§3.4) — found {d}; use a struct for more", .{tl.elems.len});
                    try self.emitSpan("E_TYPE_TUPLE_TOO_MANY", tl.span, msg);
                }
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
                const class_name = self.resolveImportAlias(self.lexeme(probe.class_name));
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
        // An empty literal has no element to infer from — recover the type
        // from a `[T; N]` annotation (the literal's own count is 0). A bare
        // `[]` with no array hint stays untyped: ambiguous, a type error at
        // the use site.
        if (ll.elems.len == 0) {
            if (hint) |h| if (h.* == .array) return try types.mkArray(self.arena, h.array.elem, 0);
            return null;
        }
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

// ---------- place expression check ----------

/// `true` when `e` is a valid assignment target — `ident`, `field`,
/// `tuple_index`, `index`, or any of those wrapped in `paren`. Function-
/// call results, arithmetic, literals, etc. are not place expressions.
fn isPlaceExpr(e: *const ast.Expr) bool {
    return switch (e.*) {
        .ident, .field, .tuple_index, .index => true,
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

/// English plural suffix for a count: `""` for one, `"s"` otherwise.
fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}
