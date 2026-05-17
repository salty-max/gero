/// Gero-lang typechecker — checking slice.
///
/// Two passes over the AST:
///   1. Top-level decl registration — every module-scope `let` /
///      `const` / `def` / `class` / `struct` / `enum` / `use` lands
///      in the module scope before walking, so forward references
///      across the file resolve cleanly.
///   2. Resolution + inference + checking — walk every statement,
///      resolve `NamedType` and `Expr.ident` against the scope chain,
///      infer literal / expression types with a bidirectional `hint`,
///      type-check operators / casts / calls / assignments per the
///      spec rules (§3.5.1, §4.2.1, §4.6, §4.2).
///
/// Subsequent slices cover nullable / reference / match / annotation /
/// bake / cast-range / varargs rules and the rendered-diagnostic shape
/// from `docs/lang-diagnostics.md`.
const std = @import("std");

const ast = @import("ast.zig");
const types = @import("types.zig");
const scope_mod = @import("scope.zig");
const diag_mod = @import("diagnostic.zig");
const Scope = scope_mod.Scope;
const Diagnostic = diag_mod.Diagnostic;
const Severity = diag_mod.Severity;

/// Typechecker output. Owns the diagnostics slice and the arena that
/// allocated every `*Type` plus the scope tree.
pub const CheckedProgram = struct {
    program: *const ast.Program,
    diagnostics: []Diagnostic,
    /// Inferred type for every `*const Expr` the typechecker walked.
    /// Keys are AST-stable pointers from the parser's arena; values
    /// live in `type_arena`. The codegen reads this map for
    /// type-driven instruction selection (fixed-point arithmetic,
    /// `print` dispatch between `print_int` / `print_str`, etc.).
    /// Missing entries mean the expression's type couldn't be
    /// inferred — callers should fall back rather than assume.
    expr_types: std.AutoHashMapUnmanaged(*const ast.Expr, *const types.Type),
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

    /// Look up the inferred type for an expression. Returns `null`
    /// when the typechecker didn't see / record it.
    pub fn typeOf(self: *const CheckedProgram, e: *const ast.Expr) ?*const types.Type {
        return self.expr_types.get(e);
    }
};

/// Walk `program` through resolution + inference + checking.
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
    // No `defer deinit` — the arena releases the scope's map storage
    // when `CheckedProgram.deinit` runs.

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

    // Pre-pass: capture stable enum / struct / class / def decl
    // pointers (slice elements have a stable address — the union
    // variant payload sits in place). Field / method resolution,
    // match-exhaustiveness, bake-call rules, and MMIO checks all
    // consult these maps. The MMIO name set is built here too
    // (any `let` annotated `@addr` lands in it).
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

const Checker = struct {
    source: []const u8,
    arena: std.mem.Allocator,
    /// Allocator used for the diagnostics ArrayList — must match the
    /// allocator the caller releases the slice with later.
    /// Diagnostic message strings still live in `arena`.
    diag_alloc: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
    /// The outermost (module) scope.
    module_scope: *Scope,
    /// The currently-active scope. Walker entry into a function /
    /// class / block sets this to a fresh child and restores on exit.
    current_scope: *Scope,
    /// Return type of the enclosing function (or `null` at module
    /// scope / inside a `def` with no explicit return annotation).
    /// Used as a hint for `return expr` so int literals pin to the
    /// declared return type.
    current_ret_ty: ?*const types.Type,
    /// Span of the enclosing class's `extends Parent` clause when
    /// the walker is inside a class method body. `null` everywhere
    /// else. Drives `super` resolution.
    current_class_extends: ?ast.Span,
    /// Name of the enclosing class when the walker is inside a
    /// class method body. `null` everywhere else. Drives `self`
    /// type resolution.
    current_class_name: ?[]const u8,
    /// Identifiers statically known non-nil in the current
    /// straight-line flow. Populated by simple nil-check pattern
    /// matching (`if x != nil` arm / `if x == nil then return end`
    /// fall-through). Keys are source-buffer slices owned by the
    /// caller's source.
    non_nil: std.StringHashMapUnmanaged(void),
    /// Enum-name → decl pointer map populated during pass 1. Used
    /// by `match` exhaustiveness to retrieve the variant list when
    /// the scrutinee resolves to a named-enum type.
    enum_registry: std.StringHashMapUnmanaged(*const ast.EnumDecl),
    /// Struct-name → decl pointer map. Drives `.field` typing and
    /// struct-literal validation.
    struct_registry: std.StringHashMapUnmanaged(*const ast.StructDecl),
    /// Class-name → decl pointer map. Drives `.field` / `.method()`
    /// typing and `self` / `super` resolution.
    class_registry: std.StringHashMapUnmanaged(*const ast.ClassDecl),
    /// Top-level `def` name → decl pointer map. Drives bake-call
    /// rules (only bake fns may be called from a bake context) and
    /// variadic-arity detection at call sites.
    def_registry: std.StringHashMapUnmanaged(*const ast.DefDecl),
    /// Module-level `let` names annotated `@addr` — touching one
    /// from inside a bake context is `E_BAKE_MMIO_ACCESS`.
    mmio_names: std.StringHashMapUnmanaged(void),
    /// `true` when walking the body of a `bake def` / `bake do`.
    /// Bake-context restrictions (no asm, no MMIO, no non-bake
    /// calls) gate on this flag.
    in_bake: bool,
    /// `true` when walking the body of a `@no_capture` def. Inner
    /// lambdas that mutate a captured binding emit
    /// `E_ANN_CAPTURE_VIOLATION` per spec §3.7.2.
    in_no_capture: bool,
    /// Names declared inside the currently-walked lambda body
    /// (params + nested `let` / `const`). `null` outside a
    /// `@no_capture`-tracked lambda. Drives the capture-mutation
    /// check on assignments and `++` / `--`.
    lambda_locals: ?std.StringHashMapUnmanaged(void),
    /// Names declared inside the currently-walked function body
    /// (parameters + nested `let` / `const` / `def`). `null` at
    /// module scope. Drives `return &local` stack-lifetime checks.
    fn_locals: ?std.StringHashMapUnmanaged(void),
    /// Tuple-destructuring sibling map: for a `let (a, b) = call()`
    /// where slot `b` is nullable, `b` maps to `a` here. When a
    /// bail-pattern fires on `b`, the sibling `a` is also promoted
    /// to the `non_nil` set (the canonical multi-return idiom per
    /// §3.4.1).
    tuple_correlations: std.StringHashMapUnmanaged([]const u8),
    /// Out-param: every successful `inferExpr` writes its result here
    /// keyed by the AST pointer. Owned by the caller; outlives the
    /// `Checker` so the codegen can read it via `CheckedProgram`.
    expr_types: *std.AutoHashMapUnmanaged(*const ast.Expr, *const types.Type),

    /// Mutually recursive walker fns need an explicit error set —
    /// Zig's inferred sets would deadlock the dependency graph.
    const WalkError = error{OutOfMemory};

    // ---------- nil-flow helpers ----------

    /// Mark `name` as statically non-nil. Returns `true` when the
    /// addition is fresh (caller pops on scope exit); `false` when
    /// the binding was already in the set.
    fn pushNonNil(self: *Checker, name: []const u8) WalkError!bool {
        const gop = try self.non_nil.getOrPut(self.arena, name);
        return !gop.found_existing;
    }

    fn popNonNil(self: *Checker, name: []const u8) void {
        _ = self.non_nil.remove(name);
    }

    /// Pattern-match a condition expression of the shape
    /// `ident == nil` / `ident != nil` (in either operand order).
    /// Returns the ident lexeme + whether the relation is `!=` so
    /// callers can pick the right arm to confer non-nil status to.
    fn matchNilCheck(self: *const Checker, cond: *const ast.Expr) ?NilCheck {
        if (cond.* != .binary) return null;
        const b = cond.binary;
        if (b.op != .eq and b.op != .neq) return null;
        const lhs_ident = identName(self, b.lhs);
        const rhs_ident = identName(self, b.rhs);
        const lhs_nil = b.lhs.* == .nil_lit;
        const rhs_nil = b.rhs.* == .nil_lit;
        if (lhs_ident) |n| if (rhs_nil) return .{ .name = n, .is_neq = b.op == .neq };
        if (rhs_ident) |n| if (lhs_nil) return .{ .name = n, .is_neq = b.op == .neq };
        return null;
    }

    const NilCheck = struct {
        name: []const u8,
        /// `true` when the relation is `!=` (then-arm confers
        /// non-nil); `false` when it is `==` (else-arm confers
        /// non-nil, or fall-through if the then-body exits).
        is_neq: bool,
    };

    // ---------- diagnostic helpers ----------

    /// Emit a diagnostic with full span coverage so the renderer
    /// can underline the offending source slice rather than a
    /// single character.
    fn emitSpan(
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

    /// Same as `emitSpan` plus an optional `help:` block printed
    /// after the caret snippet.
    fn emitSpanHelp(
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
        try self.emitSpan("E_TYPE_MISMATCH", span, msg);
    }

    fn lexeme(self: *const Checker, span: ast.Span) []const u8 {
        return self.source[span.start..span.end];
    }

    // ---------- annotation validation (§3.7) ----------

    /// Validate every annotation attached to a decl. `target` is
    /// the decl's target bit (see the `T` namespace). Emits
    /// `E_ANN_UNKNOWN` / `E_ANN_BAD_TARGET` / `E_ANN_BAD_ARG` /
    /// `E_ANN_CONFLICT` per the rules in the annotation spec
    /// table.
    fn validateAnnotations(self: *Checker, anns: []const ast.Annotation, target: u32) WalkError!void {
        for (anns) |ann| {
            const name = self.lexeme(ann.name);
            const spec = findAnnotationSpec(name) orelse {
                const msg = try std.fmt.allocPrint(
                    self.arena,
                    "unknown annotation `@{s}`",
                    .{name},
                );
                try self.emitSpan("E_ANN_UNKNOWN", ann.name, msg);
                continue;
            };
            if ((spec.targets & target) == 0) {
                const msg = try std.fmt.allocPrint(
                    self.arena,
                    "annotation `@{s}` cannot be applied to a {s}",
                    .{ name, targetLabel(target) },
                );
                try self.emitSpan("E_ANN_BAD_TARGET", ann.name, msg);
            }
            try self.validateAnnotationArgs(ann, spec);
        }
        // Conflict pairs — second loop so we only emit each conflict
        // once and so we don't false-positive when an earlier
        // annotation was already rejected.
        for (anns, 0..) |a, i| {
            const a_spec = findAnnotationSpec(self.lexeme(a.name)) orelse continue;
            for (anns[i + 1 ..]) |b| {
                const b_name = self.lexeme(b.name);
                for (a_spec.conflicts_with) |c| {
                    if (std.mem.eql(u8, c, b_name)) {
                        const msg = try std.fmt.allocPrint(
                            self.arena,
                            "annotations `@{s}` and `@{s}` cannot be combined",
                            .{ self.lexeme(a.name), b_name },
                        );
                        try self.emitSpan("E_ANN_CONFLICT", b.name, msg);
                    }
                }
            }
        }
    }

    fn validateAnnotationArgs(self: *Checker, ann: ast.Annotation, spec: *const AnnotationSpec) WalkError!void {
        switch (spec.args) {
            .none => {
                if (ann.args.len != 0) {
                    const msg = try std.fmt.allocPrint(
                        self.arena,
                        "annotation `@{s}` does not take arguments",
                        .{spec.name},
                    );
                    try self.emitSpan("E_ANN_BAD_ARG", ann.span, msg);
                }
            },
            .int_lit => {
                if (ann.args.len != 1 or ann.args[0].* != .int_lit) {
                    const msg = try std.fmt.allocPrint(
                        self.arena,
                        "annotation `@{s}` expects a single integer literal",
                        .{spec.name},
                    );
                    try self.emitSpan("E_ANN_BAD_ARG", ann.span, msg);
                }
            },
            .int_lit_pow2 => {
                if (ann.args.len != 1 or ann.args[0].* != .int_lit) {
                    const msg = try std.fmt.allocPrint(
                        self.arena,
                        "annotation `@{s}` expects a single integer literal",
                        .{spec.name},
                    );
                    try self.emitSpan("E_ANN_BAD_ARG", ann.span, msg);
                    return;
                }
                const v = ann.args[0].int_lit.value;
                if (v <= 0 or (v & (v - 1)) != 0) {
                    const msg = try std.fmt.allocPrint(
                        self.arena,
                        "annotation `@{s}` requires a power-of-two value, got {d}",
                        .{ spec.name, v },
                    );
                    try self.emitSpan("E_ANN_BAD_ARG", ann.span, msg);
                }
            },
        }
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
                try self.emitSpan("E_TYPE_REDEFINED", info.decl_span, msg);
                _ = existing;
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

    /// Build the function-pointer type for a `def` from its
    /// annotations. Params without an explicit type produce a `nil`
    /// placeholder slot — `checkCall` treats those as "skip arg-type
    /// check" pending the parameter-from-call-site inference slice.
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
            .struct_decl => |sd| try self.validateAnnotations(sd.annotations, T.STRUCT),
            .enum_decl => |ed| try self.validateAnnotations(ed.annotations, T.ENUM),
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
    fn walkStatementSequence(self: *Checker, body: []const ast.Statement) WalkError!void {
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
    /// "bail pattern" used by both the simple nullable idiom and
    /// the multi-return tuple idiom.
    ///
    ///   - `if x == nil return end`        → `x` is non-nil after.
    ///   - `if err != nil return end`      → sibling slot of `err`
    ///     (registered via `tuple_correlations`) is non-nil after;
    ///     `err` itself is now nil, not pushed.
    ///
    /// Returns the name to push, or `null` when neither shape
    /// applies.
    fn detectNilBailGain(self: *const Checker, s: ast.Statement) ?[]const u8 {
        if (s != .if_stmt) return null;
        const is_ = s.if_stmt;
        if (is_.arms.len != 1 or is_.else_body != null) return null;
        const arm = is_.arms[0];
        const cond = arm.cond orelse return null;
        const nc = self.matchNilCheck(cond) orelse return null;
        if (!bodyAlwaysExits(arm.body)) return null;
        if (nc.is_neq) {
            // Multi-return: bail when err != nil. After the bail
            // err is statically nil, so its correlated sibling
            // (value slot of `let (n, err) = …`) is valid.
            return self.tuple_correlations.get(nc.name);
        }
        return nc.name;
    }

    fn checkLetDecl(self: *Checker, d: ast.LetDecl) WalkError!void {
        try self.validateAnnotations(d.annotations, T.LET);
        const ann_ty: ?*const types.Type = if (d.type_ann) |t|
            try self.resolveType(t)
        else
            null;
        // Pass annotation type as a hint so int literals pin to the
        // declared primitive (`let x: u8 = 0` now infers u8).
        const init_ty: ?*const types.Type = if (d.init) |e|
            try self.inferExpr(e, ann_ty)
        else
            null;
        if (ann_ty != null and init_ty != null) {
            if (!assignable(init_ty.?.*, ann_ty.?.*)) {
                try self.emitMismatch(d.init.?.span(), ann_ty.?, init_ty.?);
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
    /// `E_TYPE_TUPLE_ARITY`. When the pattern is exactly two idents
    /// and the second slot is nullable, register a sibling
    /// correlation so the bail-pattern flow lifts the non-err slot.
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
        try self.validateAnnotations(d.annotations, T.CONST);
        const ann_ty: ?*const types.Type = if (d.type_ann) |t|
            try self.resolveType(t)
        else
            null;
        const init_ty = try self.inferExpr(d.init, ann_ty);
        const final = ann_ty orelse init_ty;
        if (ann_ty != null and init_ty != null and !assignable(init_ty.?.*, ann_ty.?.*)) {
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
        if (tgt_ty != null and val_ty != null and !assignable(val_ty.?.*, tgt_ty.?.*)) {
            try self.emitMismatch(a.value.span(), tgt_ty.?, val_ty.?);
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
            if (!isIntegerType(t.*)) {
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
        const name = identName(self, target) orelse return;
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
        // Multi-arm `elif` chains skip the bookkeeping (slice 5+
        // can refine if it proves useful).
        const flow: ?NilCheck = if (arms.len == 1 and arms[0].cond != null)
            self.matchNilCheck(arms[0].cond.?)
        else
            null;

        for (arms, 0..) |arm, i| {
            if (arm.cond) |c| _ = try self.inferExpr(c, null);
            if (arm.let_expr) |e| _ = try self.inferExpr(e, null);
            if (arm.let_guard) |g| _ = try self.inferExpr(g, null);

            const arm_gain: ?[]const u8 = if (i == 0 and flow != null and flow.?.is_neq)
                flow.?.name
            else
                null;
            const added = if (arm_gain) |n| try self.pushNonNil(n) else false;
            try self.walkInScope(arm.body);
            if (added) self.popNonNil(arm_gain.?);
        }

        if (else_body) |eb| {
            // The else-arm fires when the `if` cond was false, so
            // `x == nil` confers non-nil in the else.
            const else_gain: ?[]const u8 = if (flow != null and !flow.?.is_neq)
                flow.?.name
            else
                null;
            const added = if (else_gain) |n| try self.pushNonNil(n) else false;
            try self.walkInScope(eb);
            if (added) self.popNonNil(else_gain.?);
        }
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

    fn checkMatch(self: *Checker, ms: ast.MatchStmt) WalkError!void {
        const scrut_ty = try self.inferExpr(ms.scrutinee, null);

        // Lookup enum decl when scrutinee resolves to a named-enum.
        const enum_decl: ?*const ast.EnumDecl = if (scrut_ty) |st|
            self.enumDeclForType(st.*)
        else
            null;

        // Track variant-name coverage when scrutinee is an enum.
        var covered: std.StringHashMapUnmanaged(void) = .{};
        defer covered.deinit(self.arena);
        var has_wildcard: bool = false;

        for (ms.arms) |arm| {
            // Exhaustiveness + reachability checks (enum scrutinee only).
            if (enum_decl) |ed| try self.recordArmCoverage(arm, ed, &covered, &has_wildcard);

            const saved = self.current_scope;
            var child: Scope = .init(self.arena, saved);
            self.current_scope = &child;
            defer self.current_scope = saved;
            try self.registerPatternBindings(arm.pattern);
            if (arm.guard) |g| _ = try self.inferExpr(g, null);
            try self.walkStatementSequence(arm.body);
        }

        // Exhaustiveness: every variant must be covered (or wildcard).
        if (enum_decl) |ed| if (!has_wildcard) {
            try self.checkExhaustiveness(ms.span, ed, &covered);
        };
    }

    /// Resolve `ty` to its underlying enum decl (when `ty` is a
    /// `Named(EnumName)` whose name maps to a registered enum
    /// declaration). Returns `null` otherwise.
    fn enumDeclForType(self: *const Checker, ty: types.Type) ?*const ast.EnumDecl {
        if (ty != .named) return null;
        return self.enum_registry.get(ty.named.name);
    }

    /// `true` when `name` is one of `ed`'s declared variant names.
    /// Names compare by the source-buffer lexeme.
    fn variantExists(self: *const Checker, ed: *const ast.EnumDecl, name: []const u8) bool {
        for (ed.variants) |v| {
            if (std.mem.eql(u8, self.lexeme(v.name), name)) return true;
        }
        return false;
    }

    /// Walk one match arm's pattern (including or-pattern
    /// alternatives) and record which variant names it covers.
    /// Emits `E_MATCH_UNREACHABLE_ARM` on duplicates and on any arm
    /// that follows a wildcard.
    fn recordArmCoverage(
        self: *Checker,
        arm: ast.MatchArm,
        ed: *const ast.EnumDecl,
        covered: *std.StringHashMapUnmanaged(void),
        has_wildcard: *bool,
    ) WalkError!void {
        if (has_wildcard.*) {
            try self.emitSpan("E_MATCH_UNREACHABLE_ARM", arm.span, "this arm cannot be reached — a wildcard `_` arm above already handles every remaining variant");
        }
        try self.walkArmPattern(arm.pattern, ed, covered, has_wildcard);
    }

    fn walkArmPattern(
        self: *Checker,
        pat: *const ast.Pattern,
        ed: *const ast.EnumDecl,
        covered: *std.StringHashMapUnmanaged(void),
        has_wildcard: *bool,
    ) WalkError!void {
        switch (pat.*) {
            .wildcard, .ident => {
                // Bare ident in match-arm position binds the value
                // — equivalent to `_` from the exhaustiveness POV.
                has_wildcard.* = true;
            },
            .variant_pattern => |vp| {
                const split = splitPath(self.lexeme(vp.path));
                // Verify the head matches the enum name (skip when
                // it doesn't — pattern targets a different enum).
                if (split.head.len > 0 and !std.mem.eql(u8, split.head, self.lexeme(ed.name))) return;
                // Verify variant exists on this enum.
                if (!self.variantExists(ed, split.tail)) return;
                const gop = try covered.getOrPut(self.arena, split.tail);
                if (gop.found_existing) {
                    const msg = try std.fmt.allocPrint(
                        self.arena,
                        "variant `{s}.{s}` is already handled by an earlier arm",
                        .{ self.lexeme(ed.name), split.tail },
                    );
                    try self.emitSpan("E_MATCH_UNREACHABLE_ARM", pat.span(), msg);
                }
            },
            .or_pattern => |op| {
                for (op.alts) |alt| try self.walkArmPattern(alt, ed, covered, has_wildcard);
            },
            else => {
                // Literal / range / tuple / struct patterns don't
                // contribute to enum-variant coverage and don't
                // qualify as a catch-all.
            },
        }
    }

    fn checkExhaustiveness(
        self: *Checker,
        match_span: ast.Span,
        ed: *const ast.EnumDecl,
        covered: *const std.StringHashMapUnmanaged(void),
    ) WalkError!void {
        // Collect uncovered variant names for the message body.
        var missing: std.ArrayList([]const u8) = .empty;
        defer missing.deinit(self.arena);
        for (ed.variants) |v| {
            const name = self.lexeme(v.name);
            if (!covered.contains(name)) try missing.append(self.arena, name);
        }
        if (missing.items.len == 0) return;

        // Render "A, B, C" (cap at 3 to keep messages compact).
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.arena);
        const limit: usize = @min(missing.items.len, 3);
        for (missing.items[0..limit], 0..) |name, i| {
            if (i > 0) try buf.appendSlice(self.arena, ", ");
            try buf.appendSlice(self.arena, name);
        }
        if (missing.items.len > limit) try buf.appendSlice(self.arena, ", …");

        const suffix: []const u8 = if (missing.items.len == 1) "" else "s";
        const msg = try std.fmt.allocPrint(
            self.arena,
            "non-exhaustive match on enum `{s}` — missing variant{s}: {s}",
            .{ self.lexeme(ed.name), suffix, buf.items },
        );
        try self.emitSpan("E_MATCH_NON_EXHAUSTIVE", match_span, msg);
    }

    /// Defer bodies may not redirect control flow (per spec §4.10
    /// — see `docs/lang-diagnostics.md` §5.11). Reject the immediate
    /// `return` / `break` / `continue` shapes as
    /// `E_DEFER_CONTROL_FLOW` and `defer defer` as `E_DEFER_NESTED`;
    /// legitimate bodies fall through to the regular statement walk.
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
                if (!assignable(vt.*, rt.*) and !isNilType(rt.*)) {
                    try self.emitMismatch(v.span(), rt, vt);
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
        const name = identName(self, inner) orelse return;
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
        try self.validateAnnotations(d.annotations, T.DEF);
        try self.checkVariadicPosition(d);
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

        // Bake context: `bake def` body must satisfy bake rules.
        // Nested non-bake defs reset the flag (a bake fn calling a
        // non-bake-defined inner fn isn't itself in a bake context
        // for the inner body — but the call itself still checks).
        const saved_bake = self.in_bake;
        self.in_bake = d.is_bake;
        defer self.in_bake = saved_bake;

        // `@no_capture` context: inner lambdas in this fn's body
        // must not mutate captured bindings. Nested `def`s inherit
        // the flag so a closure two levels deep still flags.
        const saved_nc = self.in_no_capture;
        self.in_no_capture = saved_nc or defHasNoCapture(self, d);
        defer self.in_no_capture = saved_nc;

        // Bake fn return type must be bakeable. `Vec(T)` and `&T`
        // are runtime-only.
        if (d.is_bake) if (d.ret_type) |r| {
            const rt = try self.resolveType(r);
            if (!isBakeableType(rt.*)) {
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
                try self.resolveType(t)
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
        self.current_ret_ty = if (d.ret_type) |r| try self.resolveType(r) else null;
        defer self.current_ret_ty = saved_ret;

        try self.walkStatementSequence(d.body);
    }

    fn checkClassDecl(self: *Checker, d: ast.ClassDecl) WalkError!void {
        try self.validateAnnotations(d.annotations, T.CLASS);
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

        for (d.fields) |f| {
            try self.validateAnnotations(f.annotations, T.CLASS_FIELD);
            const ty: ?*const types.Type = if (f.type_ann) |t|
                try self.resolveType(t)
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
                try self.emitSpan("E_TYPE_UNDEFINED", n.name, msg);
                return try types.mkNamed(self.arena, name, n.span);
            },
            .nullable => |n| {
                const inner = try self.resolveType(n.inner);
                if (!self.isPointerLike(inner.*)) {
                    const inner_s = try types.render(self.arena, inner.*);
                    const msg = try std.fmt.allocPrint(
                        self.arena,
                        "type `{s}?` is invalid — `T?` only applies to pointer-like types (`str`, class, fn-pointer, references)",
                        .{inner_s},
                    );
                    try self.emitSpan("E_NULL_NON_POINTER", n.span, msg);
                }
                return try types.mkOptional(self.arena, inner);
            },
            .array => |a| {
                const elem = try self.resolveType(a.elem);
                const len_val: u32 = if (a.len_expr.* == .int_lit)
                    // safety: parser stores array lengths as i32; §3.4 requires non-negative comptime int. Slice 3+ will range-check; bit-cast preserves bytes.
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

    /// Pointer-like types per §3.4.1 — `str`, references, function
    /// pointers, and class names. Struct / enum / numeric / bool /
    /// fixed are by-value and therefore not nullable-eligible.
    fn isPointerLike(self: *const Checker, t: types.Type) bool {
        return switch (t) {
            .primitive => |p| p == .str,
            .reference, .function => true,
            .named => |n| {
                if (self.current_scope.lookup(n.name)) |info| {
                    return switch (info.kind) {
                        .class, .module_alias, .imported => true,
                        else => false,
                    };
                }
                // Unresolved named type — accept defensively so the
                // diagnostic surfaces from the resolution step.
                return true;
            },
            else => false,
        };
    }

    // ---------- expression walking + inference + checking ----------

    /// Infer the type of an expression. `hint` is the type the
    /// caller expects this expression to produce, used by literal
    /// inference to pin to the requested primitive. `null` when no
    /// context is available.
    ///
    /// Records the inferred type on `expr_types` before returning so
    /// the codegen can consume it without re-walking the AST.
    fn inferExpr(self: *Checker, e: *const ast.Expr, hint: ?*const types.Type) WalkError!?*const types.Type {
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
                            return try self.constructorSignatureFor(cd, name, i.span);
                        }
                    }
                    return info.ty;
                }
                const msg = try std.fmt.allocPrint(
                    self.arena,
                    "undefined symbol `{s}`",
                    .{name},
                );
                try self.emitSpan("E_UNDEFINED_SYMBOL", i.span, msg);
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
            .unary => |u| return try self.checkUnary(u, hint),
            .binary => |b| return try self.checkBinary(b, hint),
            .range => |r| {
                _ = try self.inferExpr(r.start, null);
                _ = try self.inferExpr(r.end, null);
                return null;
            },
            .call => |c| return try self.checkCall(c, hint),
            .method_call => |m| {
                // `mem.X(args)` parses as a method call on the
                // synthetic `mem` module — dispatch through the
                // stdlib resolver rather than the class-method path.
                if (m.receiver.* == .ident) {
                    const recv_name = self.lexeme(m.receiver.ident.span);
                    if (std.mem.eql(u8, recv_name, "mem")) {
                        return try self.checkMemMethodCall(m);
                    }
                }
                const recv_ty = try self.inferExpr(m.receiver, null);
                try self.checkNotNullableDeref(m.receiver, recv_ty, m.span);
                return try self.checkMethodCall(m, recv_ty);
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
                        return try self.resolveEnumVariant(ed, recv_name, f);
                    }
                    if (std.mem.eql(u8, recv_name, "mem")) {
                        return try self.resolveMemBuiltin(f);
                    }
                }
                const recv_ty = try self.inferExpr(f.receiver, null);
                try self.checkNotNullableDeref(f.receiver, recv_ty, f.span);
                return try self.resolveFieldAccess(f, recv_ty);
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
            .list_lit => |ll| return try self.inferListLit(ll, hint),
            .list_repeat => |lr| return try self.inferListRepeat(lr, hint),
            .struct_lit => |sl| return try self.checkStructLit(sl),
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
            .is_test => |it| {
                _ = try self.inferExpr(it.lhs, null);
                return try self.primitive(.bool_);
            },
            .cast => |c| return try self.checkCast(c),
            .ref_of => |r| return try self.checkRefOf(r),
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
        if (identName(self, receiver)) |name| {
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

    // ---------- field / method resolution ----------

    /// Look up `f.field` against the receiver's named-type decl.
    /// Returns the field's declared type, or emits
    /// `E_TYPE_UNDEFINED_FIELD` when the field is unknown. Returns
    /// `null` when the receiver type isn't a resolvable named
    /// struct / class — downstream callers treat that as "unknown
    /// for now" rather than another error.
    /// Resolve an enum-variant constructor expression
    /// (`EnumName.Variant`). Nullary variants resolve directly to
    /// the enum's `Named` type — `let s = Color.Red` infers as
    /// `Color`. Payload-bearing variants resolve to the constructor
    /// function type `fn(payload_types) -> Enum` so a wrapping
    /// `CallExpr` (`Item.Potion(20)`) type-checks through the
    /// regular `checkCall` path.
    fn resolveEnumVariant(
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
            const pt = try self.resolveType(pf.type_ann);
            try param_tys.append(self.arena, pt);
        }
        const fn_ty = try self.arena.create(types.Type);
        fn_ty.* = .{ .function = .{
            .params = try param_tys.toOwnedSlice(self.arena),
            .ret = enum_ty,
        } };
        return fn_ty;
    }

    /// Type-check `mem.X(args)` as a method-call expression. The
    /// stdlib `mem` module is compiler-recognized; the call's
    /// arity + per-arg types are validated against the builtin's
    /// declared signature. `mem.addr_of` accepts any addressable
    /// argument so it skips per-arg checking — codegen rejects
    /// non-addressable targets later.
    fn checkMemMethodCall(self: *Checker, m: ast.MethodCallExpr) WalkError!?*const types.Type {
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

    /// Resolve `mem.X` builtin field expressions. The `mem` module
    /// is compiler-recognized rather than a regular source module —
    /// each entry here synthesizes a function type so the wrapping
    /// `CallExpr` flows through the normal `checkCall` path (arity
    /// + per-arg type check).
    ///
    /// `mem.addr_of` is the one shape that doesn't fit the regular
    /// arity / type rules — its argument can be any place
    /// expression. We synthesize `fn() -> u16` and rely on the
    /// codegen to do the address resolution; the call-site arity
    /// check still validates one-arg-ness.
    fn resolveMemBuiltin(self: *Checker, f: ast.FieldExpr) WalkError!?*const types.Type {
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
        // Special case: `mem.addr_of` accepts any addressable
        // expression as its single arg; surface its signature as
        // `fn(<anything>) -> u16` by deferring the param type
        // validation to codegen.
        if (sig.?.is_addr_of) {
            var params: std.ArrayList(*const types.Type) = .empty;
            errdefer params.deinit(self.arena);
            // Single-element `nil` placeholder — the codegen path
            // accepts whatever the source supplies.
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

    fn resolveFieldAccess(
        self: *Checker,
        f: ast.FieldExpr,
        recv_ty: ?*const types.Type,
    ) WalkError!?*const types.Type {
        const rt = recv_ty orelse return null;
        const named_name = namedNameOf(rt.*) orelse return null;
        const field_name = self.lexeme(f.field);
        if (self.struct_registry.get(named_name)) |sd| {
            for (sd.fields) |fld| {
                if (std.mem.eql(u8, self.lexeme(fld.name), field_name)) {
                    return try self.resolveType(fld.type_ann);
                }
            }
            try self.emitUndefinedField(named_name, field_name, f.field);
            return null;
        }
        if (self.class_registry.get(named_name)) |cd| {
            if (try self.lookupClassFieldType(cd, field_name)) |t| return t;
            try self.emitUndefinedField(named_name, field_name, f.field);
            return null;
        }
        return null;
    }

    /// Walk a class's inherited chain looking for a field named
    /// `field_name`. Returns the resolved type when found.
    fn lookupClassFieldType(
        self: *Checker,
        cd: *const ast.ClassDecl,
        field_name: []const u8,
    ) WalkError!?*const types.Type {
        for (cd.fields) |fld| {
            if (std.mem.eql(u8, self.lexeme(fld.name), field_name)) {
                if (fld.type_ann) |t| return try self.resolveType(t);
                return null;
            }
        }
        if (cd.extends) |ext| if (self.class_registry.get(self.lexeme(ext))) |parent| {
            return try self.lookupClassFieldType(parent, field_name);
        };
        return null;
    }

    fn emitUndefinedField(self: *Checker, type_name: []const u8, field_name: []const u8, span: ast.Span) WalkError!void {
        const msg = try std.fmt.allocPrint(
            self.arena,
            "type `{s}` has no field `{s}`",
            .{ type_name, field_name },
        );
        try self.emitSpan("E_TYPE_UNDEFINED_FIELD", span, msg);
    }

    /// Type-check a method call against the class registry.
    /// Walks args regardless so unrelated diagnostics still fire.
    /// Emits `E_TYPE_UNDEFINED_METHOD` when the named method is
    /// missing on the receiver class. Otherwise behaves like a
    /// regular call: arity + per-arg type check against the method's
    /// signature.
    fn checkMethodCall(
        self: *Checker,
        m: ast.MethodCallExpr,
        recv_ty: ?*const types.Type,
    ) WalkError!?*const types.Type {
        const rt = recv_ty orelse {
            for (m.args) |a| _ = try self.inferExpr(a, null);
            return null;
        };
        const named_name = namedNameOf(rt.*) orelse {
            for (m.args) |a| _ = try self.inferExpr(a, null);
            return null;
        };
        const cd = self.class_registry.get(named_name) orelse {
            for (m.args) |a| _ = try self.inferExpr(a, null);
            return null;
        };
        const method_name = self.lexeme(m.method);
        const method = self.lookupClassMethod(cd, method_name) orelse {
            const msg = try std.fmt.allocPrint(
                self.arena,
                "class `{s}` has no method `{s}`",
                .{ named_name, method_name },
            );
            try self.emitSpan("E_TYPE_UNDEFINED_METHOD", m.method, msg);
            for (m.args) |a| _ = try self.inferExpr(a, null);
            return null;
        };
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
                    try self.resolveType(t)
                else
                    null;
                const skip = if (param_ty) |pt| isNilType(pt.*) else true;
                const arg_ty = try self.inferExpr(arg, if (skip) null else param_ty);
                if (!skip and param_ty != null and arg_ty != null and !assignable(arg_ty.?.*, param_ty.?.*)) {
                    try self.emitMismatch(arg.span(), param_ty.?, arg_ty.?);
                }
            }
        }
        if (method.ret_type) |r| return try self.resolveType(r);
        return try self.primitive(.nil_);
    }

    /// Validate a struct literal against its decl. Reports
    /// unknown / missing / mistyped fields and returns the named
    /// type so the surrounding expression continues to type-check.
    fn checkStructLit(self: *Checker, sl: ast.StructLit) WalkError!?*const types.Type {
        const type_name = self.lexeme(sl.type_name);
        const named_ty = try types.mkNamed(self.arena, type_name, sl.type_name);

        // Struct literals can be used to construct classes too
        // (`Player { name: "Cecil" }` shorthand) — try both
        // registries.
        if (self.struct_registry.get(type_name)) |sd| {
            try self.checkStructLitFields(sl, type_name, sd.fields);
            return named_ty;
        }
        if (self.class_registry.get(type_name)) |cd| {
            try self.checkClassLitFields(sl, type_name, cd);
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
        try self.emitSpan("E_TYPE_UNDEFINED", sl.type_name, msg);
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
            const decl_field = findStructField(self, decl_fields, field_name) orelse {
                try self.emitUndefinedField(type_name, field_name, lit_field.name);
                _ = try self.inferExpr(lit_field.value, null);
                continue;
            };
            const expected_ty = try self.resolveType(decl_field.type_ann);
            const actual_ty = try self.inferExpr(lit_field.value, expected_ty);
            if (actual_ty) |at| if (!assignable(at.*, expected_ty.*)) {
                try self.emitMismatch(lit_field.value.span(), expected_ty, at);
            };
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
            const expected_ty: ?*const types.Type = try self.lookupClassFieldType(cd, field_name);
            if (expected_ty == null and findClassField(self, cd, field_name) == null) {
                try self.emitUndefinedField(type_name, field_name, lit_field.name);
                _ = try self.inferExpr(lit_field.value, null);
                continue;
            }
            const actual_ty = try self.inferExpr(lit_field.value, expected_ty);
            if (expected_ty) |et| if (actual_ty) |at| if (!assignable(at.*, et.*)) {
                try self.emitMismatch(lit_field.value.span(), et, at);
            };
        }
        // Class literals don't require every field to be set
        // (constructors fill defaults). Slice 7 may tighten this
        // when annotation rules pin field requiredness.
    }

    /// Synthesize a constructor signature for a class. Uses the
    /// `init` method's params (sans implicit `self`) when present;
    /// otherwise the constructor is nullary. Return type is always
    /// `Named(class_name)`.
    fn constructorSignatureFor(
        self: *Checker,
        cd: *const ast.ClassDecl,
        class_name: []const u8,
        name_span: ast.Span,
    ) WalkError!*const types.Type {
        var param_types: std.ArrayList(*const types.Type) = .empty;
        errdefer param_types.deinit(self.arena);
        if (self.lookupClassMethod(cd, "init")) |init_method| {
            var has_self = false;
            if (init_method.params.len > 0 and std.mem.eql(u8, self.lexeme(init_method.params[0].name), "self")) has_self = true;
            const skip: usize = if (has_self) 1 else 0;
            for (init_method.params[skip..]) |p| {
                const pt: *const types.Type = if (p.type_ann) |t|
                    try self.resolveType(t)
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
    fn lookupClassMethod(
        self: *const Checker,
        cd: *const ast.ClassDecl,
        method_name: []const u8,
    ) ?*const ast.DefDecl {
        for (cd.methods) |*method| {
            if (std.mem.eql(u8, self.lexeme(method.name), method_name)) return method;
        }
        if (cd.extends) |ext| if (self.class_registry.get(self.lexeme(ext))) |parent| {
            return self.lookupClassMethod(parent, method_name);
        };
        return null;
    }

    // ---------- literal inference with bidirectional hint ----------

    fn inferIntLit(self: *Checker, lit: ast.IntLitExpr, hint: ?*const types.Type) WalkError!?*const types.Type {
        // Bidirectional: pin to hint when the hint is an integer-like
        // primitive. Range-check the literal against the pinned width.
        if (hint) |h| if (h.* == .primitive) {
            const p = h.primitive;
            if (isIntegerPrimitive(p)) {
                if (!intLitFits(lit.value, p)) {
                    const msg = try std.fmt.allocPrint(
                        self.arena,
                        "literal `{d}` does not fit in `{s}`",
                        .{ lit.value, primitiveName(p) },
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

    // ---------- operator type rules (§4.2.1) ----------

    fn checkUnary(self: *Checker, u: ast.UnaryExpr, hint: ?*const types.Type) WalkError!?*const types.Type {
        const op_hint: ?*const types.Type = if (u.op == .log_not)
            try self.primitive(.bool_)
        else
            hint;
        const operand_ty = try self.inferExpr(u.operand, op_hint);
        if (operand_ty == null) return null;
        const ot = operand_ty.?;
        switch (u.op) {
            .neg => {
                if (!isNumericType(ot.*)) {
                    try self.emitOperatorRequires(u.span, "negation `-`", "a numeric type", ot);
                    return null;
                }
                return ot;
            },
            .log_not => {
                if (!isBoolType(ot.*)) {
                    try self.emitOperatorRequires(u.span, "logical `not`", "`bool`", ot);
                    return null;
                }
                return try self.primitive(.bool_);
            },
            .bit_not => {
                if (!isIntegerType(ot.*)) {
                    try self.emitOperatorRequires(u.span, "bitwise `~`", "an integer type", ot);
                    return null;
                }
                return ot;
            },
        }
    }

    fn checkBinary(self: *Checker, b: ast.BinaryExpr, hint: ?*const types.Type) WalkError!?*const types.Type {
        return switch (b.op) {
            .add, .sub, .mul, .div, .mod => try self.checkArith(b, hint),
            .shl, .shr => try self.checkShift(b, hint),
            .bit_and, .bit_or, .bit_xor => try self.checkBitwise(b, hint),
            .eq, .neq, .lt, .lte, .gt, .gte => try self.checkComparison(b),
            .log_and, .log_or => try self.checkLogical(b),
        };
    }

    fn checkArith(self: *Checker, b: ast.BinaryExpr, hint: ?*const types.Type) WalkError!?*const types.Type {
        const lhs_ty = try self.inferExpr(b.lhs, hint);
        // Pin RHS to LHS once known; otherwise fall back to the outer hint.
        const rhs_hint = lhs_ty orelse hint;
        const rhs_ty = try self.inferExpr(b.rhs, rhs_hint);
        if (lhs_ty == null or rhs_ty == null) return lhs_ty orelse rhs_ty;
        // String concatenation: only `+`, both sides `str`.
        if (b.op == .add and isStrType(lhs_ty.?.*) and isStrType(rhs_ty.?.*)) {
            return try self.primitive(.str);
        }
        if (!isNumericType(lhs_ty.?.*)) {
            try self.emitOperatorRequires(b.span, opLexeme(b.op), "a numeric type", lhs_ty.?);
            return null;
        }
        if (!isNumericType(rhs_ty.?.*)) {
            try self.emitOperatorRequires(b.span, opLexeme(b.op), "a numeric type", rhs_ty.?);
            return null;
        }
        if (!lhs_ty.?.eql(rhs_ty.?.*)) {
            try self.emitMismatch(b.rhs.span(), lhs_ty.?, rhs_ty.?);
        }
        return lhs_ty;
    }

    fn checkShift(self: *Checker, b: ast.BinaryExpr, hint: ?*const types.Type) WalkError!?*const types.Type {
        const lhs_ty = try self.inferExpr(b.lhs, hint);
        // Shift count is itself an integer; default to u8-ish via i16 (no specific hint).
        const rhs_ty = try self.inferExpr(b.rhs, null);
        if (lhs_ty == null or rhs_ty == null) return lhs_ty;
        if (!isIntegerType(lhs_ty.?.*)) {
            try self.emitOperatorRequires(b.span, opLexeme(b.op), "an integer type", lhs_ty.?);
            return null;
        }
        if (!isIntegerType(rhs_ty.?.*)) {
            try self.emitOperatorRequires(b.span, opLexeme(b.op), "an integer shift count", rhs_ty.?);
            return null;
        }
        return lhs_ty;
    }

    fn checkBitwise(self: *Checker, b: ast.BinaryExpr, hint: ?*const types.Type) WalkError!?*const types.Type {
        const lhs_ty = try self.inferExpr(b.lhs, hint);
        const rhs_hint = lhs_ty orelse hint;
        const rhs_ty = try self.inferExpr(b.rhs, rhs_hint);
        if (lhs_ty == null or rhs_ty == null) return lhs_ty orelse rhs_ty;
        if (!isIntegerType(lhs_ty.?.*)) {
            try self.emitOperatorRequires(b.span, opLexeme(b.op), "an integer type", lhs_ty.?);
            return null;
        }
        if (!isIntegerType(rhs_ty.?.*)) {
            try self.emitOperatorRequires(b.span, opLexeme(b.op), "an integer type", rhs_ty.?);
            return null;
        }
        if (!lhs_ty.?.eql(rhs_ty.?.*)) {
            try self.emitMismatch(b.rhs.span(), lhs_ty.?, rhs_ty.?);
        }
        return lhs_ty;
    }

    fn checkComparison(self: *Checker, b: ast.BinaryExpr) WalkError!?*const types.Type {
        const lhs_ty = try self.inferExpr(b.lhs, null);
        const rhs_ty = try self.inferExpr(b.rhs, lhs_ty);
        if (lhs_ty != null and rhs_ty != null) {
            // Allow nil-comparison (`x != nil` / `nil == p`) — the
            // canonical nullable idiom per §3.4.1. Strict-equality
            // only when neither side is the nil literal.
            const either_is_nil = isNilType(lhs_ty.?.*) or isNilType(rhs_ty.?.*);
            if (!either_is_nil and !lhs_ty.?.eql(rhs_ty.?.*)) {
                try self.emitMismatch(b.rhs.span(), lhs_ty.?, rhs_ty.?);
            }
        }
        return try self.primitive(.bool_);
    }

    fn checkLogical(self: *Checker, b: ast.BinaryExpr) WalkError!?*const types.Type {
        const bool_ty = try self.primitive(.bool_);
        const lhs_ty = try self.inferExpr(b.lhs, bool_ty);
        const rhs_ty = try self.inferExpr(b.rhs, bool_ty);
        if (lhs_ty) |t| if (!isBoolType(t.*)) {
            try self.emitOperatorRequires(b.span, opLexeme(b.op), "`bool`", t);
        };
        if (rhs_ty) |t| if (!isBoolType(t.*)) {
            try self.emitOperatorRequires(b.span, opLexeme(b.op), "`bool`", t);
        };
        return bool_ty;
    }

    fn emitOperatorRequires(
        self: *Checker,
        span: ast.Span,
        op_name: []const u8,
        wants: []const u8,
        actual: *const types.Type,
    ) WalkError!void {
        const actual_s = try types.render(self.arena, actual.*);
        const msg = try std.fmt.allocPrint(
            self.arena,
            "operator {s} requires {s}, found `{s}`",
            .{ op_name, wants, actual_s },
        );
        try self.emitSpan("E_TYPE_MISMATCH", span, msg);
    }

    // ---------- cast (`as T`) checking ----------

    fn checkCast(self: *Checker, c: ast.CastExpr) WalkError!?*const types.Type {
        const inner_ty = try self.inferExpr(c.inner, null);
        const target_ty = try self.resolveType(c.target_type);
        if (inner_ty) |it| {
            if (!canCast(it.*, target_ty.*)) {
                const from_s = try types.render(self.arena, it.*);
                const to_s = try types.render(self.arena, target_ty.*);
                const msg = try std.fmt.allocPrint(
                    self.arena,
                    "cannot cast `{s}` to `{s}`",
                    .{ from_s, to_s },
                );
                try self.emitSpan("E_CAST_INVALID", c.span, msg);
            }
        }
        return target_ty;
    }

    // ---------- function call ----------

    fn checkCall(self: *Checker, c: ast.CallExpr, hint: ?*const types.Type) WalkError!?*const types.Type {
        _ = hint;
        const callee_ty = try self.inferExpr(c.callee, null);
        // Bake-context rule: only `bake def` fns may be called.
        if (self.in_bake) try self.checkBakeCall(c);
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
            return try self.checkVariadicCall(c, decl, f);
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
            // call-site inference for those lands in a later slice.
            const skip = isNilType(param_ty.*);
            const arg_ty = try self.inferExpr(arg, if (skip) null else param_ty);
            if (!skip and arg_ty != null and !assignable(arg_ty.?.*, param_ty.*)) {
                try self.emitMismatch(arg.span(), param_ty, arg_ty.?);
            }
        }
        return f.ret;
    }

    // ---------- variadic (§4.6.2) ----------

    /// Verify a `def`'s param list places the (optional) variadic
    /// param last. Parser may already enforce; this check routes
    /// any out-of-place variadic through `E_VAR_NOT_LAST`.
    fn checkVariadicPosition(self: *Checker, d: ast.DefDecl) WalkError!void {
        for (d.params, 0..) |p, i| {
            if (p.variadic and i != d.params.len - 1) {
                try self.emitSpan("E_VAR_NOT_LAST", p.span, "variadic parameter must be the last in the parameter list");
                return;
            }
        }
    }

    /// Type-check a call whose callee has a trailing variadic
    /// param. The leading fixed params match positionally; every
    /// arg passed into the variadic slot must share a single type.
    fn checkVariadicCall(
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
            const skip = isNilType(param_ty.*);
            const arg_ty = try self.inferExpr(arg, if (skip) null else param_ty);
            if (!skip and arg_ty != null and !assignable(arg_ty.?.*, param_ty.*)) {
                try self.emitMismatch(arg.span(), param_ty, arg_ty.?);
            }
        }
        // Variadic slot: all trailing args must share a type.
        var pivot: ?*const types.Type = null;
        for (c.args[fixed_count..]) |arg| {
            const arg_ty = try self.inferExpr(arg, pivot);
            const at = arg_ty orelse continue;
            if (pivot) |p| {
                if (!assignable(at.*, p.*)) {
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
        return f.ret;
    }

    // ---------- bake-context rules (§3.8) ----------

    fn checkBakeCall(self: *Checker, c: ast.CallExpr) WalkError!void {
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

fn structLitMentions(c: *const Checker, fields: []const ast.StructLitField, name: []const u8) bool {
    for (fields) |f| if (c.exprMentions(f.value, name)) return true;
    return false;
}

// ---------- callee resolution helpers ----------

/// Extract the lexeme of a callee that is a bare ident (possibly
/// wrapped in `paren`). Used by call-site rules that need to find
/// the underlying decl (bake-call check, variadic detection).
fn directCalleeName(c: *const Checker, callee: *const ast.Expr) ?[]const u8 {
    return identName(c, callee);
}

/// When `callee` resolves to a `def` decl whose last param is
/// variadic, return that decl. Returns `null` otherwise — callers
/// fall back to the regular fixed-arity path.
fn variadicCalleeDecl(c: *const Checker, callee: *const ast.Expr) ?*const ast.DefDecl {
    const name = identName(c, callee) orelse return null;
    const decl = c.def_registry.get(name) orelse return null;
    if (decl.params.len == 0) return null;
    if (!decl.params[decl.params.len - 1].variadic) return null;
    return decl;
}

// ---------- flow-analysis helpers ----------

/// Extract the source-buffer lexeme when `e` is a bare ident
/// (possibly wrapped in `paren`). Returns `null` otherwise — used
/// by nil-check pattern matching and by flow-sensitive deref
/// lookups.
fn identName(c: *const Checker, e: *const ast.Expr) ?[]const u8 {
    return switch (e.*) {
        .ident => |i| c.lexeme(i.span),
        .paren => |p| identName(c, p.inner),
        else => null,
    };
}

/// `true` when the last statement of `body` is `return` / `break` /
/// `continue` — used by the `if x == nil then return end`
/// fall-through detector.
fn bodyAlwaysExits(body: []const ast.Statement) bool {
    if (body.len == 0) return false;
    return switch (body[body.len - 1]) {
        .return_stmt, .break_stmt, .continue_stmt => true,
        else => false,
    };
}

/// Lexeme of a `Named` type, or `null` for other type shapes.
fn namedNameOf(t: types.Type) ?[]const u8 {
    return switch (t) {
        .named => |n| n.name,
        else => null,
    };
}

/// Locate a field on a struct decl by name.
fn findStructField(c: *const Checker, fields: []const ast.StructField, name: []const u8) ?*const ast.StructField {
    for (fields) |*f| {
        if (std.mem.eql(u8, c.lexeme(f.name), name)) return f;
    }
    return null;
}

/// Locate a field on a class decl by name (walks the inheritance
/// chain). Returns the first hit.
fn findClassField(c: *const Checker, cd: *const ast.ClassDecl, name: []const u8) ?*const ast.ClassField {
    for (cd.fields) |*f| {
        if (std.mem.eql(u8, c.lexeme(f.name), name)) return f;
    }
    if (cd.extends) |ext| if (c.class_registry.get(c.lexeme(ext))) |parent| {
        return findClassField(c, parent, name);
    };
    return null;
}

/// Split a dotted variant path lexeme (`Enum.Variant`) into head /
/// tail. Returns an empty head when there is no `.` in the path.
fn splitPath(text: []const u8) struct { head: []const u8, tail: []const u8 } {
    if (std.mem.lastIndexOfScalar(u8, text, '.')) |dot| {
        return .{ .head = text[0..dot], .tail = text[dot + 1 ..] };
    }
    return .{ .head = "", .tail = text };
}

// ---------- type predicates ----------

fn isIntegerPrimitive(p: types.Primitive) bool {
    return switch (p) {
        .i8, .u8, .i16, .u16 => true,
        else => false,
    };
}

fn isIntegerType(t: types.Type) bool {
    return switch (t) {
        .primitive => |p| isIntegerPrimitive(p),
        else => false,
    };
}

fn isNumericType(t: types.Type) bool {
    return switch (t) {
        .primitive => |p| isIntegerPrimitive(p) or p == .fixed,
        else => false,
    };
}

fn isBoolType(t: types.Type) bool {
    return switch (t) {
        .primitive => |p| p == .bool_,
        else => false,
    };
}

fn isStrType(t: types.Type) bool {
    return switch (t) {
        .primitive => |p| p == .str,
        else => false,
    };
}

/// `true` when `d` carries a `@no_capture` annotation.
fn defHasNoCapture(c: *const Checker, d: ast.DefDecl) bool {
    for (d.annotations) |ann| {
        if (std.mem.eql(u8, c.lexeme(ann.name), "no_capture")) return true;
    }
    return false;
}

fn isNilType(t: types.Type) bool {
    return switch (t) {
        .primitive => |p| p == .nil_,
        else => false,
    };
}

/// `true` when a type is representable as static data — i.e. safe
/// as the return type or output of a `bake` context. `Vec(T)` and
/// references live in the runtime allocator / borrow domain and
/// therefore can't be baked.
fn isBakeableType(t: types.Type) bool {
    return switch (t) {
        .primitive => true,
        .array => |a| isBakeableType(a.elem.*),
        .tuple => |xs| blk: {
            for (xs) |e| if (!isBakeableType(e.*)) break :blk false;
            break :blk true;
        },
        .optional => |inner| isBakeableType(inner.*),
        .named => true,
        .vec, .reference, .function => false,
    };
}

fn primitiveName(p: types.Primitive) []const u8 {
    return switch (p) {
        .i8 => "i8",
        .u8 => "u8",
        .i16 => "i16",
        .u16 => "u16",
        .bool_ => "bool",
        .nil_ => "nil",
        .str => "str",
        .fixed => "fixed",
        .char => "char",
    };
}

fn intLitFits(value: i32, p: types.Primitive) bool {
    return switch (p) {
        .i8 => value >= -128 and value <= 127,
        .u8 => value >= 0 and value <= 255,
        .i16 => value >= -32768 and value <= 32767,
        .u16 => value >= 0 and value <= 65535,
        else => false,
    };
}

fn opLexeme(op: ast.BinaryOp) []const u8 {
    return switch (op) {
        .add => "`+`",
        .sub => "`-`",
        .mul => "`*`",
        .div => "`/`",
        .mod => "`%`",
        .shl => "`<<`",
        .shr => "`>>`",
        .bit_and => "`&`",
        .bit_or => "`|`",
        .bit_xor => "`^`",
        .eq => "`==`",
        .neq => "`!=`",
        .lt => "`<`",
        .lte => "`<=`",
        .gt => "`>`",
        .gte => "`>=`",
        .log_and => "`and`",
        .log_or => "`or`",
    };
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

// ---------- annotation validation (§3.7) ----------

/// Bit flags for annotation `targets:` — which decl kinds an
/// annotation may attach to.
const T = struct {
    const LET: u32 = 1 << 0;
    const CONST: u32 = 1 << 1;
    const DEF: u32 = 1 << 2;
    const CLASS: u32 = 1 << 3;
    const STRUCT: u32 = 1 << 4;
    const ENUM: u32 = 1 << 5;
    const CLASS_FIELD: u32 = 1 << 6;
};

/// Shape an annotation's args must take.
const ArgRule = enum {
    none, // no args (marker)
    int_lit, // single int literal
    int_lit_pow2, // single int literal, power of two
};

const AnnotationSpec = struct {
    name: []const u8,
    targets: u32,
    args: ArgRule,
    /// Annotation names that conflict with this one when both are
    /// applied to the same decl.
    conflicts_with: []const []const u8 = &.{},
};

/// Spec inventory per `docs/gero-lang.md` §3.7.
const annotation_specs = [_]AnnotationSpec{
    // Memory placement (§3.7.1)
    .{ .name = "bank", .targets = T.DEF | T.LET | T.CONST, .args = .int_lit },
    .{ .name = "zero_page", .targets = T.LET, .args = .none },
    .{ .name = "addr", .targets = T.LET, .args = .int_lit },
    .{ .name = "volatile", .targets = T.LET, .args = .none },
    .{ .name = "align", .targets = T.LET | T.CONST | T.STRUCT, .args = .int_lit_pow2 },
    // Codegen control (§3.7.2)
    .{ .name = "inline", .targets = T.DEF, .args = .none },
    .{ .name = "cold", .targets = T.DEF, .args = .none },
    .{ .name = "no_capture", .targets = T.DEF, .args = .none },
    // Misc
    .{ .name = "noreturn", .targets = T.DEF, .args = .none },
    .{ .name = "interrupt", .targets = T.DEF, .args = .int_lit },
    .{ .name = "test", .targets = T.DEF, .args = .none },
    .{ .name = "bench", .targets = T.DEF, .args = .none },
    // OOP (§6)
    .{
        .name = "override",
        .targets = T.DEF,
        .args = .none,
        .conflicts_with = &.{ "final", "abstract" },
    },
    .{
        .name = "final",
        .targets = T.DEF | T.CLASS,
        .args = .none,
        .conflicts_with = &.{ "override", "abstract" },
    },
    .{
        .name = "abstract",
        .targets = T.DEF | T.CLASS,
        .args = .none,
        .conflicts_with = &.{ "override", "final", "static" },
    },
    .{
        .name = "static",
        .targets = T.DEF,
        .args = .none,
        .conflicts_with = &.{ "abstract", "override" },
    },
    .{ .name = "private", .targets = T.DEF | T.LET | T.CLASS_FIELD, .args = .none },
};

fn findAnnotationSpec(name: []const u8) ?*const AnnotationSpec {
    for (&annotation_specs) |*s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

fn targetLabel(target: u32) []const u8 {
    return switch (target) {
        T.LET => "let",
        T.CONST => "const",
        T.DEF => "def",
        T.CLASS => "class",
        T.STRUCT => "struct",
        T.ENUM => "enum",
        T.CLASS_FIELD => "class field",
        else => "decl",
    };
}

// ---------- assignability ----------

/// `true` when an `actual` typed value can be stored / returned /
/// passed into an `expected` slot. Wider than `Type.eql` — allows
/// `T → T?` (non-nil to nullable) and recurses into tuples for
/// per-slot assignability. Used by return / let-init / assignment
/// / call-arg checks; operator arms keep strict equality.
fn assignable(actual: types.Type, expected: types.Type) bool {
    if (actual.eql(expected)) return true;
    if (expected == .optional) {
        if (actual == .primitive and actual.primitive == .nil_) return true;
        if (assignable(actual, expected.optional.*)) return true;
    }
    if (expected == .tuple and actual == .tuple and expected.tuple.len == actual.tuple.len) {
        for (expected.tuple, actual.tuple) |e, a| {
            if (!assignable(a.*, e.*)) return false;
        }
        return true;
    }
    return false;
}

// ---------- cast convertibility (§3.5.1) ----------

/// Spec §3.5.1 conversion table. Allows integer ↔ integer (any
/// width / sign), bool ↔ integer, fixed ↔ integer, u8 ↔ char, and
/// any same-primitive identity cast. Rejects everything else
/// (class casts, function-pointer reinterpret, reference casts).
fn canCast(from: types.Type, to: types.Type) bool {
    if (from != .primitive or to != .primitive) return false;
    const f = from.primitive;
    const t = to.primitive;
    if (f == t) return true;
    const f_int = isIntegerPrimitive(f);
    const t_int = isIntegerPrimitive(t);
    if (f_int and t_int) return true;
    if (f == .bool_ and t_int) return true;
    if (f_int and t == .bool_) return true;
    if (f == .fixed and t_int) return true;
    if (f_int and t == .fixed) return true;
    if ((f == .u8 and t == .char) or (f == .char and t == .u8)) return true;
    return false;
}
