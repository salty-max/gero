/// Gero-lang AST — what the parser emits, what the typechecker
/// and codegen consume. Every node carries a `Span` so diagnostics
/// can resolve back to `(file, line, col)` against the original
/// source text.
///
/// Mirrors the shape of `src/asm/ast.zig`: discriminated unions
/// for `Statement`, `Expr`, `Pattern`, `TypeAnn`; allocated child
/// trees are owned by the program allocator and released via
/// `Program.deinit`.
///
/// Per gero-lang spec (see `docs/gero-lang.md`).
const std = @import("std");
const lexer = @import("lexer.zig");

/// Byte range in the source buffer. Used by every AST node so a
/// downstream pass (typechecker, codegen, formatter) can locate
/// the original token sequence.
pub const Span = struct {
    start: u32,
    end: u32,

    /// Span covering exactly one token.
    pub fn fromToken(t: lexer.Token) Span {
        return .{ .start = t.start, .end = t.end };
    }

    /// Smallest span covering both `a` and `b`.
    pub fn join(a: Span, b: Span) Span {
        return .{
            .start = @min(a.start, b.start),
            .end = @max(a.end, b.end),
        };
    }
};

// =====================================================================
// Annotations — `@name` / `@name(arg)` markers attached to a decl.
// =====================================================================

/// One `@name(...)` annotation. Bound to the following decl by the
/// parser. The argument list is captured verbatim as expressions so
/// each annotation's semantics (e.g. `@bank 5`, `@interrupt 0x06`,
/// `@addr $FE40`, `@asm("swap {a}, {b}")`) stay decoupled from the
/// parser shape. The downstream typechecker / codegen interprets
/// the args per the annotation's contract.
pub const Annotation = struct {
    /// Span of the annotation name (without the `@` prefix). Lexeme
    /// bytes recover via `source[name.start..name.end]`.
    name: Span,
    /// Args in source order. Empty for marker annotations (`@final`,
    /// `@inline`, `@override`, `@noreturn`, `@private`, `@static`,
    /// `@abstract`, `@test`, `@bench`, `@zero_page`).
    args: []*Expr,
    /// Span covering `@name` plus any `(...)`. End-to-end.
    span: Span,
};

// =====================================================================
// Type annotations — appear after `:` in `let x: T = ...`, after
// `->` in `def name(...) -> T`, and in `fn(T1, T2) -> T3` types.
// =====================================================================

/// Type expression — parses the surface syntax of `docs/gero-lang.md`
/// §3.1 (primitives), §3.2 (`str`), §3.3 (`fixed`), §3.4 (compound
/// types), §3.4.1 (nullable suffix `?`), §3.4.3 (`Vec(T)`).
pub const TypeAnn = union(enum) {
    /// `i16`, `u8`, `bool`, `str`, `fixed`, a class name, an enum
    /// name, etc. The typechecker resolves the lexeme to a primitive
    /// or a user-defined declaration.
    named: NamedType,
    /// `T?` — nullable suffix. Per §3.4.1, restricted to pointer-like
    /// inner types; the typechecker enforces that, the parser
    /// accepts the syntax uniformly.
    nullable: NullableType,
    /// `[T; N]` — fixed-size array. `N` is a compile-time integer
    /// expression (typically a literal).
    array: ArrayType,
    /// `Vec(T)` — compiler-known dynamic array. The inner type is
    /// the element type.
    vec: VecType,
    /// `(T1, T2, ...)` — tuple. Per §3.4 max 4 elements; the parser
    /// accepts more and the typechecker rejects oversize tuples.
    tuple: TupleType,
    /// `fn(args...) -> ret` — function pointer type. `ret` is
    /// optional (defaults to `nil`).
    fn_type: FnType,

    /// Smallest `Span` covering the whole type annotation.
    pub fn span(self: TypeAnn) Span {
        return switch (self) {
            .named => |n| n.span,
            .nullable => |n| n.span,
            .array => |a| a.span,
            .vec => |v| v.span,
            .tuple => |t| t.span,
            .fn_type => |f| f.span,
        };
    }
};

/// `i16`, `MyClass`, `Foo.Bar`, etc. — a single named type.
pub const NamedType = struct {
    /// Span of the type name (and any `.qualified.path` segments
    /// joined dot-separated).
    name: Span,
    span: Span,
};

/// `T?` — wraps an inner type, marks the binding nullable.
pub const NullableType = struct {
    inner: *TypeAnn,
    span: Span,
};

/// `[T; N]` — fixed-size array. `len_expr` is a comptime integer.
pub const ArrayType = struct {
    elem: *TypeAnn,
    /// Compile-time length expression. Typically an int literal.
    len_expr: *Expr,
    span: Span,
};

/// `Vec(T)` — compiler-known dynamic array. `elem` is the element
/// type.
pub const VecType = struct {
    elem: *TypeAnn,
    span: Span,
};

/// `(T1, T2, ...)` — anonymous tuple type.
pub const TupleType = struct {
    elems: []*TypeAnn,
    span: Span,
};

/// `fn(T1, T2, ...) -> R` — function-pointer type.
pub const FnType = struct {
    params: []*TypeAnn,
    /// `null` when the arrow is omitted — the parser canonicalizes
    /// "no return type" to `nil`. Provided here so the printer can
    /// round-trip the source shape.
    ret: ?*TypeAnn,
    span: Span,
};

// =====================================================================
// Patterns — appear in `let` destructuring (§4.1.1), `if let`
// (§4.4.1), `while let` (§4.5.2), `match` arms (§4.8.1).
// =====================================================================

/// One pattern node. The parser builds these for every binding
/// shape the spec lists in §4.8.1.
pub const Pattern = union(enum) {
    /// `_` — matches anything, binds nothing.
    wildcard: SpanOnly,
    /// `ident` — matches anything, binds the value to `ident`.
    ident: IdentPattern,
    /// `42` / `0xFF` / `-1` — integer literal.
    int_lit: IntLitPattern,
    /// `"hello"` — string literal (compares byte-wise).
    str_lit: SpanOnly,
    /// `'A'` — char literal.
    char_lit: CharLitPattern,
    /// `true` / `false`.
    bool_lit: BoolLitPattern,
    /// `nil`.
    nil_lit: SpanOnly,
    /// `A | B | C` — or-pattern; any sub-pattern matches.
    or_pattern: OrPattern,
    /// `0..=15` / `0..16` — range pattern.
    range_pattern: RangePattern,
    /// `(p1, p2, ...)` — tuple pattern; binds element-wise.
    tuple_pattern: TuplePattern,
    /// `Enum.Variant(p1, p2, ...)` — enum variant; `args` is empty
    /// for nullary variants like `Item.Sword`. The parser captures
    /// the variant path as a span; the typechecker resolves it.
    variant_pattern: VariantPattern,
    /// `Type { field, field: pat, ... }` — struct pattern; missing
    /// binders shorthand to `field: field`.
    struct_pattern: StructPattern,

    /// Smallest `Span` covering the whole pattern.
    pub fn span(self: Pattern) Span {
        return switch (self) {
            .wildcard, .str_lit, .nil_lit => |p| p.span,
            .ident => |p| p.span,
            .int_lit => |p| p.span,
            .char_lit => |p| p.span,
            .bool_lit => |p| p.span,
            .or_pattern => |p| p.span,
            .range_pattern => |p| p.span,
            .tuple_pattern => |p| p.span,
            .variant_pattern => |p| p.span,
            .struct_pattern => |p| p.span,
        };
    }
};

/// Shared payload for span-only AST variants (`wildcard`,
/// `nil_lit`, `str_lit` pattern, etc.).
pub const SpanOnly = struct {
    span: Span,
};

/// `x` — binding-style pattern: matches anything, captures the
/// value under `name`.
pub const IdentPattern = struct {
    /// Span of the bound identifier.
    name: Span,
    span: Span,
};

/// `42` — integer-literal pattern.
pub const IntLitPattern = struct {
    value: i32,
    span: Span,
};

/// `'A'` — char-literal pattern.
pub const CharLitPattern = struct {
    /// ASCII byte value the char literal compiled to.
    value: u8,
    span: Span,
};

/// `true` / `false` — bool-literal pattern.
pub const BoolLitPattern = struct {
    value: bool,
    span: Span,
};

/// `A | B | C` — or-pattern. `alts` is non-empty.
pub const OrPattern = struct {
    alts: []*Pattern,
    span: Span,
};

/// `0..10` / `0..=15` — range pattern (matches values inside the
/// range).
pub const RangePattern = struct {
    start: *Expr,
    end: *Expr,
    /// `true` for `..=`, `false` for `..`.
    inclusive: bool,
    span: Span,
};

/// `(p1, p2, ...)` — tuple destructuring.
pub const TuplePattern = struct {
    elems: []*Pattern,
    span: Span,
};

/// `Enum.Variant(p1, p2, ...)` — enum-variant pattern (with
/// optional payload binders).
pub const VariantPattern = struct {
    /// Variant path like `Item.Sword` or `Item.Potion`. The
    /// typechecker resolves the head to an enum decl and the tail
    /// to a variant.
    path: Span,
    /// Sub-patterns for the variant's payload, in declaration order.
    /// Empty for nullary variants.
    args: []*Pattern,
    span: Span,
};

/// `Type { field, field: pat, ... }` — struct-destructuring
/// pattern.
pub const StructPattern = struct {
    /// Type name (`Player`, etc.).
    type_name: Span,
    fields: []StructPatternField,
    span: Span,
};

/// One field of a struct pattern: `name` plus a nested pattern.
pub const StructPatternField = struct {
    /// Field name as it appears in the type definition.
    name: Span,
    /// Sub-pattern matching the field's value. Shorthand
    /// `Player { hp, mp }` desugars at parse time to `{ hp: hp,
    /// mp: mp }` — the parser allocates an `IdentPattern` with the
    /// same name + span.
    sub: *Pattern,
    span: Span,
};

// =====================================================================
// Expressions — every value-producing form. Pratt precedence per
// `docs/gero-lang.md` §3.3.
// =====================================================================

/// Every value-producing form in the language. Each variant
/// carries its own struct payload (or `SpanOnly` for the keyword
/// literals); operator precedence is enforced by the parser when
/// it builds these nodes.
pub const Expr = union(enum) {
    int_lit: IntLitExpr,
    /// Fixed-point literal — `1.5`, `0.125`, etc. The lexer
    /// pre-encodes the value as Q8.8 (top byte integer, bottom byte
    /// `round(frac * 256)`).
    fixed_lit: FixedLitExpr,
    bool_lit: BoolLitExpr,
    nil_lit: SpanOnly,
    char_lit: CharLitExpr,
    /// Full string literal (possibly with interpolation parts). The
    /// parser flattens the lexer's `str_start`/`str_part`/
    /// `str_expr_start`/`str_expr_end`/`str_end` stream into a
    /// linear `parts` list of byte runs + interpolated subexprs.
    str_lit: StrLitExpr,
    /// Bare identifier — variable reference.
    ident: IdentExpr,
    /// `self` keyword inside a class method.
    self_expr: SpanOnly,
    /// `super` keyword inside a class method body.
    super_expr: SpanOnly,
    /// `( inner )` — explicit grouping. Kept in the AST for span
    /// integrity and so the printer can round-trip user parens.
    paren: ParenExpr,
    /// `-x` / `not x` / `~x` — unary prefix.
    unary: UnaryExpr,
    /// `lhs op rhs` — every infix operator. The `op` field carries
    /// the operator kind; precedence is encoded at parse time by
    /// the Pratt loop.
    binary: BinaryExpr,
    /// `start .. end` / `start ..= end` (with optional `step` —
    /// `step` arrives via the `for` header, not as an inline part
    /// of a `..` expression; this node just carries `start`/`end`/
    /// `inclusive`).
    range: RangeExpr,
    /// `callee(args...)`. The callee is any expression that
    /// evaluates to a function (ident, lambda, field access, etc.).
    call: CallExpr,
    /// `obj.method(args...)` — sugar for a regular call where the
    /// receiver is bound to the first parameter.
    method_call: MethodCallExpr,
    /// `obj.field` — direct field access, no parentheses.
    field: FieldExpr,
    /// `obj[index]` — bracket-index access. For `Vec(T)` and arrays
    /// codegen emits the `at`/`get` opcode; for strings it's byte
    /// access.
    index: IndexExpr,
    /// `do ... end` as an expression — evaluates to the last
    /// expression of the body. §4.3.
    do_expr: DoExpr,
    /// `if cond then a else b` as an expression (§4.4 — the bodies
    /// are blocks; the value is the last expression of the taken
    /// branch). Optional in the spec — `if` is primarily a
    /// statement; the parser produces this form when an `if` is
    /// found in expression position.
    if_expr: IfExpr,
    /// `lambda (args) -> ret body end` — anonymous function literal.
    lambda: LambdaExpr,
    /// `[expr, expr, ...]` — array literal. Used for `[T; N]` init
    /// and `Vec.from([...])` arg.
    list_lit: ListLit,
    /// `Type { field: expr, ... }` — struct literal.
    struct_lit: StructLit,
    /// `(a, b, ...)` — tuple literal (at least 2 elements; singletons
    /// are paren expressions).
    tuple_lit: TupleLit,
    /// `value is Enum.Variant` — variant-tag test. Rhs is a span over
    /// the qualified variant path.
    is_test: IsTestExpr,
    /// `value as T` — explicit type conversion (§3.8). The runtime
    /// shape depends on the source / target types (truncation,
    /// sign / zero extension, fixed↔int rounding); the parser just
    /// captures the inner expression + target type annotation.
    cast: CastExpr,

    /// Smallest `Span` covering the whole expression.
    pub fn span(self: Expr) Span {
        return switch (self) {
            .int_lit => |e| e.span,
            .fixed_lit => |e| e.span,
            .bool_lit => |e| e.span,
            .nil_lit, .self_expr, .super_expr => |e| e.span,
            .char_lit => |e| e.span,
            .str_lit => |e| e.span,
            .ident => |e| e.span,
            .paren => |e| e.span,
            .unary => |e| e.span,
            .binary => |e| e.span,
            .range => |e| e.span,
            .call => |e| e.span,
            .method_call => |e| e.span,
            .field => |e| e.span,
            .index => |e| e.span,
            .do_expr => |e| e.span,
            .if_expr => |e| e.span,
            .lambda => |e| e.span,
            .list_lit => |e| e.span,
            .struct_lit => |e| e.span,
            .tuple_lit => |e| e.span,
            .is_test => |e| e.span,
            .cast => |e| e.span,
        };
    }
};

/// Integer literal (decimal / hex / binary; the lexer normalizes
/// all three into a single `int_lit` token).
pub const IntLitExpr = struct {
    value: i32,
    span: Span,
};

/// Fixed-point literal — `1.5`, `0.125`, etc. `value` is the
/// pre-encoded Q8.8 (top byte integer part, bottom byte
/// `round(frac * 256)`). Sign carried in the 16-bit two's-complement
/// pattern; the lexer applies negation when the literal is preceded
/// by `-` in operand position.
pub const FixedLitExpr = struct {
    value: i32,
    span: Span,
};

/// `true` / `false` — bool literal.
pub const BoolLitExpr = struct {
    value: bool,
    span: Span,
};

/// `'A'` — single-byte char literal.
pub const CharLitExpr = struct {
    /// Single-byte char-literal value (the lexer already decoded
    /// escape sequences).
    value: u8,
    span: Span,
};

/// String literal — possibly interpolated. `parts` runs in source
/// order; for `"hello, $(name)!"` the list is
/// `[ .lit("hello, "), .interp(<name expr>), .lit("!") ]`. Adjacent
/// interpolations are still separated by an empty `.lit("")` part so
/// downstream consumers can rely on a uniform "literal between every
/// pair of interps" shape.
pub const StrLitExpr = struct {
    parts: []StrPart,
    span: Span,
};

/// One chunk in a possibly-interpolated string literal.
pub const StrPart = union(enum) {
    /// Raw byte run inside the string. Span covers the bytes
    /// between the surrounding delimiters/interps. Escape sequences
    /// are not yet decoded — codegen reads `source[span.start..span.end]`
    /// and resolves escapes there.
    lit: StrLitPart,
    /// `$(expr)` substitution. The optional format spec lives in
    /// `format_spec` and is rendered by the runtime formatter.
    interp: StrInterpPart,
};

/// Plain byte-run part of a string literal.
pub const StrLitPart = struct {
    span: Span,
};

/// `$(expr[:fmt])` part of a string literal.
pub const StrInterpPart = struct {
    expr: *Expr,
    /// `null` when no `:fmt` spec is present. Span covers the bytes
    /// after `:` and up to the closing `)`. Same minimal subset of
    /// Python's spec language as §3.2.2 describes.
    format_spec: ?Span,
    span: Span,
};

/// Bare identifier reference in expression position.
pub const IdentExpr = struct {
    /// Span of the identifier token. Lexeme bytes recover via
    /// `source[span.start..span.end]`.
    span: Span,
};

/// `( inner )` — explicit grouping wrapper.
pub const ParenExpr = struct {
    inner: *Expr,
    span: Span,
};

/// `op operand` — unary prefix expression.
pub const UnaryExpr = struct {
    op: UnaryOp,
    operand: *Expr,
    span: Span,
};

/// Unary prefix operators per §4.2.1.
pub const UnaryOp = enum {
    /// `-x` — two's-complement negation.
    neg,
    /// `not x` — logical NOT. Boolean-valued.
    log_not,
    /// `~x` — bitwise NOT.
    bit_not,
};

/// `lhs op rhs` — binary infix expression.
pub const BinaryExpr = struct {
    op: BinaryOp,
    lhs: *Expr,
    rhs: *Expr,
    span: Span,
};

/// Binary operators per §4.2.1. Precedence is encoded by the
/// Pratt loop in `parser.zig`; this enum just names every operator
/// the parser recognizes.
pub const BinaryOp = enum {
    // arithmetic
    add, // +
    sub, // -
    mul, // *
    div, // /
    mod, // %

    // shift
    shl, // <<
    shr, // >>

    // bitwise
    bit_and, // &
    bit_or, // |
    bit_xor, // ^

    // comparison
    eq, // ==
    neq, // !=
    lt, // <
    lte, // <=
    gt, // >
    gte, // >=

    // logical
    log_and, // and
    log_or, // or
};

/// `start..end` / `start..=end` — range expression.
pub const RangeExpr = struct {
    start: *Expr,
    end: *Expr,
    /// `true` for `..=`, `false` for `..`.
    inclusive: bool,
    span: Span,
};

/// `callee(args...)` — function call.
pub const CallExpr = struct {
    callee: *Expr,
    args: []*Expr,
    span: Span,
};

/// `receiver.method(args...)` — method-call sugar.
pub const MethodCallExpr = struct {
    receiver: *Expr,
    /// Method name span.
    method: Span,
    args: []*Expr,
    span: Span,
};

/// `receiver.field` — field access (no parens).
pub const FieldExpr = struct {
    receiver: *Expr,
    /// Field name span.
    field: Span,
    span: Span,
};

/// `receiver[index]` — bracket-index access.
pub const IndexExpr = struct {
    receiver: *Expr,
    index: *Expr,
    span: Span,
};

/// `do ... end` used as an expression.
pub const DoExpr = struct {
    body: []Statement,
    span: Span,
};

/// `if cond then ... [else ...] end` used as an expression.
pub const IfExpr = struct {
    /// `cond / then-body` pairs in source order. The first arm is
    /// the `if`; subsequent arms are `else if` / `elif`.
    arms: []IfArm,
    /// `else` body, `null` when omitted.
    else_body: ?[]Statement,
    span: Span,
};

/// One `cond / body` arm of an if / elif chain. The arm is either
/// the plain shape (`cond` set, let_* null) or the `if let pat =
/// expr [when guard]` shape (cond null, let_* set). §4.4 / §4.4.1.
pub const IfArm = struct {
    cond: ?*Expr,
    let_pattern: ?*Pattern,
    let_expr: ?*Expr,
    let_guard: ?*Expr,
    body: []Statement,
    span: Span,
};

/// `lambda (args) [-> ret] body end` — anonymous function value.
pub const LambdaExpr = struct {
    params: []Param,
    /// Optional return-type annotation. `null` when the source
    /// omits the `-> T` part.
    ret_type: ?*TypeAnn,
    body: []Statement,
    span: Span,
};

/// `[a, b, c, ...]` — array / list literal.
pub const ListLit = struct {
    elems: []*Expr,
    span: Span,
};

/// `Type { field: expr, ... }` — struct literal.
pub const StructLit = struct {
    /// Type name (`Player`, `Stats`, etc.).
    type_name: Span,
    fields: []StructLitField,
    span: Span,
};

/// One field of a struct literal.
pub const StructLitField = struct {
    name: Span,
    value: *Expr,
    span: Span,
};

/// `(a, b, ...)` — tuple literal.
pub const TupleLit = struct {
    elems: []*Expr,
    span: Span,
};

/// `lhs is Enum.Variant` — variant-tag test.
pub const IsTestExpr = struct {
    lhs: *Expr,
    /// Variant path span — typically `EnumType.Variant`.
    variant_path: Span,
    span: Span,
};

/// `inner as T` — explicit type conversion.
pub const CastExpr = struct {
    inner: *Expr,
    target_type: *TypeAnn,
    span: Span,
};

// =====================================================================
// Function parameters — shared between `def`, `lambda`, and class
// methods.
// =====================================================================

/// One parameter of a `def` / `lambda` / class method.
pub const Param = struct {
    name: Span,
    /// `null` when the parameter has no explicit type — inference
    /// will pin it from call-site usage (§3.5).
    type_ann: ?*TypeAnn,
    span: Span,
};

// =====================================================================
// Statements — the top-level units of a program.
// =====================================================================

/// Top-level statement node. The parser unwraps `local` shims into
/// the inner decl's `is_local: true`, so `local_decl` itself only
/// appears for malformed inputs.
pub const Statement = union(enum) {
    /// `let pattern[: T] = expr` / `let name: T` (uninit form).
    let_decl: LetDecl,
    /// `const NAME = expr`. The parser captures the RHS verbatim;
    /// comptime-folding happens in the codegen pass.
    const_decl: ConstDecl,
    /// `target = expr` and the compound-assign family.
    assign: AssignStmt,
    /// `x++` / `x--`.
    inc_dec: IncDecStmt,
    /// `_ = expr` — explicit discard. Per §4.2.2.
    discard: DiscardStmt,
    /// Bare expression as a statement — function/method call whose
    /// return value is discarded implicitly (`nil`-typed calls).
    expr_stmt: ExprStmt,
    /// `do ... end` at statement position.
    block: BlockStmt,
    /// `if cond then ... [elif ...] [else ...] end`.
    if_stmt: IfStmt,
    /// `while cond do ... end`.
    while_stmt: WhileStmt,
    /// `for binding in iter [step expr] do ... end`.
    for_stmt: ForStmt,
    /// `match scrutinee case pat [when guard] then body ... end`.
    match_stmt: MatchStmt,
    /// `return [expr]`.
    return_stmt: ReturnStmt,
    /// `break [:label]` (§4.5.4).
    break_stmt: LoopJumpStmt,
    /// `continue [:label]` (§4.5.4).
    continue_stmt: LoopJumpStmt,
    /// `print expr1, expr2, ...`.
    print_stmt: PrintStmt,
    /// `def name(params) [-> T] body end`.
    def_decl: DefDecl,
    /// `class Name [extends Parent] { ... }`.
    class_decl: ClassDecl,
    /// `struct Name field: T, ... end`.
    struct_decl: StructDecl,
    /// `enum Name case Variant[(payload)] ... end`.
    enum_decl: EnumDecl,
    /// `use module [as alias]` and `use sym from module`.
    use_decl: UseDecl,
    /// `local <decl>` — visibility modifier wrapping a let/const/def/
    /// class/struct/enum/use decl. The parser flattens this by
    /// setting the inner decl's `is_local` field rather than
    /// nesting; this variant remains here for unrecognized shapes.
    local_decl: LocalDecl,
    /// `@asm("...")` — single inline-asm escape hatch line.
    asm_stmt: AsmStmt,
    /// `defer <stmt>` — schedule `stmt` to run when the enclosing
    /// block exits (§4.10). LIFO across multiple defers in the same
    /// block. Codegen owns the cleanup-label management.
    defer_stmt: DeferStmt,
    /// Catch-all for unrecognized lines. Carries a span so consumers
    /// can skip cleanly.
    unknown: UnknownStmt,

    /// Smallest `Span` covering the whole statement.
    pub fn span(self: Statement) Span {
        return switch (self) {
            .let_decl => |s| s.span,
            .const_decl => |s| s.span,
            .assign => |s| s.span,
            .inc_dec => |s| s.span,
            .discard => |s| s.span,
            .expr_stmt => |s| s.span,
            .block => |s| s.span,
            .if_stmt => |s| s.span,
            .while_stmt => |s| s.span,
            .for_stmt => |s| s.span,
            .match_stmt => |s| s.span,
            .return_stmt => |s| s.span,
            .break_stmt, .continue_stmt => |s| s.span,
            .print_stmt => |s| s.span,
            .def_decl => |s| s.span,
            .class_decl => |s| s.span,
            .struct_decl => |s| s.span,
            .enum_decl => |s| s.span,
            .use_decl => |s| s.span,
            .local_decl => |s| s.span,
            .asm_stmt => |s| s.span,
            .defer_stmt => |s| s.span,
            .unknown => |s| s.span,
        };
    }
};

/// `let pattern[: T][ = expr]` — variable binding.
pub const LetDecl = struct {
    /// `@bank N` / `@zero_page` / `@addr $1234` attach here at
    /// module scope (§3.7.1). Empty for nested `let`s.
    annotations: []Annotation,
    /// Pattern bound by the `let`. For the canonical single-name
    /// case it's `Pattern.ident`; destructuring (§4.1.1) uses other
    /// pattern shapes.
    pattern: *Pattern,
    /// `null` when no `: T` annotation is given.
    type_ann: ?*TypeAnn,
    /// `null` when the form is `let name: T` (declared but
    /// uninitialized; the typechecker requires the annotation in
    /// that case).
    init: ?*Expr,
    /// Set by `local let ...` — the visibility shim.
    is_local: bool,
    span: Span,
};

/// `const NAME[: T] = expr` — immutable binding.
pub const ConstDecl = struct {
    /// `@bank N` attaches here at module scope (§3.7.1).
    annotations: []Annotation,
    /// Span of the identifier being bound.
    name: Span,
    /// `null` when the form omits the type annotation (typical for
    /// `const`).
    type_ann: ?*TypeAnn,
    init: *Expr,
    is_local: bool,
    span: Span,
};

/// `target op= value` (or plain `=`) — assignment statement.
pub const AssignStmt = struct {
    /// L-value (`x`, `obj.field`, `arr[i]`, etc.). The parser does
    /// not enforce assignability here — that's a typechecker pass.
    target: *Expr,
    op: AssignOp,
    value: *Expr,
    span: Span,
};

/// Assignment operator kinds per §4.2.
pub const AssignOp = enum {
    /// Plain `=`.
    set,
    /// `+=` / `-=` / `*=` / `/=` / `%=`
    add_set,
    sub_set,
    mul_set,
    div_set,
    mod_set,
    /// `&=` / `|=` / `^=`
    bit_and_set,
    bit_or_set,
    bit_xor_set,
    /// `<<=` / `>>=`
    shl_set,
    shr_set,
};

/// `target++` / `target--` — statement-level increment / decrement.
pub const IncDecStmt = struct {
    /// L-value being mutated.
    target: *Expr,
    /// `true` for `++`, `false` for `--`.
    inc: bool,
    span: Span,
};

/// `_ = expr` — explicit value discard.
pub const DiscardStmt = struct {
    /// Expression whose value is evaluated then dropped.
    expr: *Expr,
    span: Span,
};

/// Bare expression statement (typically a call whose return value
/// is `nil`).
pub const ExprStmt = struct {
    expr: *Expr,
    span: Span,
};

/// `do ... end` at statement position.
pub const BlockStmt = struct {
    body: []Statement,
    span: Span,
};

/// `if cond then ... [elif ...] [else ...] end` — statement form.
pub const IfStmt = struct {
    /// `cond / then-body` pairs in source order; the first arm is
    /// the `if`, the rest are `else if` / `elif`.
    arms: []IfArm,
    else_body: ?[]Statement,
    span: Span,
};

/// `while cond ... end` (or the `while let` variant). Optional
/// trailing `:label` (§4.5.4) lets nested loops target this one via
/// `break :label` / `continue :label`.
pub const WhileStmt = struct {
    /// For `while let pat = expr ... end`, `cond` is null and
    /// `let_pattern` / `let_expr` carry the binding shape.
    cond: ?*Expr,
    let_pattern: ?*Pattern,
    let_expr: ?*Expr,
    /// Optional `when guard` clause on the `while let` form.
    let_guard: ?*Expr,
    /// Loop label, if the head carried a `:name` suffix. `null` for
    /// unlabeled loops.
    label: ?Span,
    body: []Statement,
    span: Span,
};

/// `for x in iter [step N] ... end`. Optional trailing `:label`
/// (§4.5.4) — see `WhileStmt`.
pub const ForStmt = struct {
    /// Binding name (typical `for x in xs` form). Tuple destructuring
    /// can be added later by upgrading to a `Pattern`; today the
    /// parser accepts a single identifier per spec §4.5 examples.
    binding: Span,
    /// Iterable / range expression.
    iter: *Expr,
    /// `null` unless the source explicitly carried `step N`.
    step: ?*Expr,
    /// Loop label, if the head carried a `:name` suffix.
    label: ?Span,
    body: []Statement,
    span: Span,
};

/// `match expr case pat ... end` — pattern dispatch.
pub const MatchStmt = struct {
    scrutinee: *Expr,
    arms: []MatchArm,
    span: Span,
};

/// One `case pat [when guard] then body` arm of a `match`.
pub const MatchArm = struct {
    pattern: *Pattern,
    /// Optional `when` guard following the pattern.
    guard: ?*Expr,
    body: []Statement,
    span: Span,
};

/// `return [expr]` statement.
pub const ReturnStmt = struct {
    /// `null` for bare `return`.
    value: ?*Expr,
    span: Span,
};

/// `print expr, expr, ...` statement.
pub const PrintStmt = struct {
    /// Comma-separated argument list. Per §4.9, items are space-
    /// separated in output and a newline is appended.
    args: []*Expr,
    span: Span,
};

/// `def name(params) [-> T] body end` — function declaration.
pub const DefDecl = struct {
    annotations: []Annotation,
    /// Function name span. Lexeme via `source[name.start..name.end]`.
    name: Span,
    params: []Param,
    ret_type: ?*TypeAnn,
    body: []Statement,
    is_local: bool,
    span: Span,
};

/// `class Name [extends Parent] { ... }` — class declaration.
pub const ClassDecl = struct {
    annotations: []Annotation,
    /// Class name span.
    name: Span,
    /// Span of the parent class name when `extends Foo` is present;
    /// `null` otherwise.
    extends: ?Span,
    /// Field declarations (`let name: T` lines inside the class
    /// body).
    fields: []ClassField,
    /// Method declarations.
    methods: []DefDecl,
    is_local: bool,
    span: Span,
};

/// `let name: T [= init]` inside a class body.
pub const ClassField = struct {
    annotations: []Annotation,
    name: Span,
    type_ann: ?*TypeAnn,
    /// `null` when no default value is specified.
    init: ?*Expr,
    span: Span,
};

/// `struct Name field: T ... end` — struct declaration (POD).
pub const StructDecl = struct {
    annotations: []Annotation,
    name: Span,
    fields: []StructField,
    is_local: bool,
    span: Span,
};

/// One field of a `struct` declaration.
pub const StructField = struct {
    name: Span,
    type_ann: *TypeAnn,
    span: Span,
};

/// `enum Name case Variant ... end` — sum-type declaration.
pub const EnumDecl = struct {
    annotations: []Annotation,
    name: Span,
    variants: []EnumVariant,
    is_local: bool,
    span: Span,
};

/// One `case` arm of an `enum` declaration.
pub const EnumVariant = struct {
    name: Span,
    /// Per-payload-field type annotations. Empty for nullary
    /// variants. Each entry carries an optional binding name; the
    /// `Item.Key(name: str, count: u8)` form has names, the
    /// `Item.Potion(i16)` form has anonymous payloads (name span is
    /// zero-width).
    payload: []EnumPayloadField,
    span: Span,
};

/// One payload slot inside an `enum` variant.
pub const EnumPayloadField = struct {
    /// Zero-width span when the payload is anonymous (`(i16)`);
    /// otherwise the field's binding name.
    name: Span,
    type_ann: *TypeAnn,
    span: Span,
};

/// `use module [as alias]` / `use a, b from module` — import.
pub const UseDecl = struct {
    /// Module path span — either a bare ident (`math`) or a quoted
    /// path (`"./physics"`). The parser captures the span as-is;
    /// resolution semantics are the linker's job.
    module: Span,
    /// `true` when the module spec was a quoted-path form.
    quoted_path: bool,
    /// Optional selective-import list (`use abs, sqrt from math`).
    /// Empty for a whole-module import.
    items: []UseItem,
    /// Optional whole-module alias (`use math as m`).
    alias: ?Span,
    is_local: bool,
    span: Span,
};

/// One name in a selective-import list (`use a, b from m`).
pub const UseItem = struct {
    name: Span,
    /// Optional per-item alias (`use abs as absolute from math`).
    alias: ?Span,
    span: Span,
};

/// `local <decl>` shim with a non-decl payload — produced only on
/// malformed inputs (real `local` decls flatten into the inner
/// decl's `is_local: true`).
pub const LocalDecl = struct {
    /// Unparsed body span when the `local` keyword was followed by
    /// a non-decl shape. Kept here for diagnostics.
    span: Span,
};

/// `@asm("...")` — inline-assembly escape hatch (§3.7.7).
pub const AsmStmt = struct {
    /// Span covering the string literal (including the surrounding
    /// quotes). Codegen reads the bytes and performs `{name}`
    /// substitution against the enclosing scope.
    body: Span,
    span: Span,
};

/// `break` / `continue` with optional `:label` (§4.5.4). When the
/// source has no label, `label` is `null` and the statement targets
/// the innermost enclosing loop; otherwise it targets the loop
/// whose `WhileStmt.label` / `ForStmt.label` matches.
pub const LoopJumpStmt = struct {
    label: ?Span,
    span: Span,
};

/// `defer <stmt>` — schedule a statement to run when the enclosing
/// block exits (§4.10). The body is held as a single `*Statement`;
/// wrap in `do … end` for multi-statement cleanups. LIFO order
/// across multiple defers in the same block.
pub const DeferStmt = struct {
    body: *Statement,
    span: Span,
};

/// Catch-all for unrecognized statement-position input. The span
/// covers the recovered source range; consumers usually just emit a
/// diagnostic and skip.
pub const UnknownStmt = struct {
    span: Span,
};

// =====================================================================
// Program — output of `parse`. Owns every allocated child node.
// =====================================================================

/// Top-level parse output. Owns the statement list and every child
/// node hanging off it (expressions, patterns, type annotations).
pub const Program = struct {
    statements: []Statement,
    allocator: std.mem.Allocator,

    /// Release the owned statement list and every allocated child
    /// node hanging off it.
    pub fn deinit(self: *Program) void {
        for (self.statements) |*s| freeStatement(self.allocator, s);
        self.allocator.free(self.statements);
    }
};

// =====================================================================
// Tree-recursive free helpers. The parser allocates child nodes via
// `allocator.create(...)`; these mirror that traversal exactly.
// =====================================================================

/// Release every child allocation hanging off `s`. Used by
/// `Program.deinit` and by the parser's recovery paths.
pub fn freeStatement(allocator: std.mem.Allocator, s: *Statement) void {
    switch (s.*) {
        .let_decl => |ld| {
            freeAnnotations(allocator, ld.annotations);
            freePattern(allocator, ld.pattern);
            if (ld.type_ann) |t| freeTypeAnn(allocator, t);
            if (ld.init) |e| freeExpr(allocator, e);
        },
        .const_decl => |cd| {
            freeAnnotations(allocator, cd.annotations);
            if (cd.type_ann) |t| freeTypeAnn(allocator, t);
            freeExpr(allocator, cd.init);
        },
        .assign => |as_| {
            freeExpr(allocator, as_.target);
            freeExpr(allocator, as_.value);
        },
        .inc_dec => |id| freeExpr(allocator, id.target),
        .discard => |d| freeExpr(allocator, d.expr),
        .expr_stmt => |es| freeExpr(allocator, es.expr),
        .block => |b| freeStatementList(allocator, b.body),
        .if_stmt => |is_| freeIfArmsAndElse(allocator, is_.arms, is_.else_body),
        .while_stmt => |ws| {
            if (ws.cond) |c| freeExpr(allocator, c);
            if (ws.let_pattern) |p| freePattern(allocator, p);
            if (ws.let_expr) |e| freeExpr(allocator, e);
            if (ws.let_guard) |g| freeExpr(allocator, g);
            freeStatementList(allocator, ws.body);
        },
        .for_stmt => |fs| {
            freeExpr(allocator, fs.iter);
            if (fs.step) |s_| freeExpr(allocator, s_);
            freeStatementList(allocator, fs.body);
        },
        .match_stmt => |ms| {
            freeExpr(allocator, ms.scrutinee);
            for (ms.arms) |arm| {
                freePattern(allocator, arm.pattern);
                if (arm.guard) |g| freeExpr(allocator, g);
                freeStatementList(allocator, arm.body);
            }
            allocator.free(ms.arms);
        },
        .return_stmt => |rs| {
            if (rs.value) |v| freeExpr(allocator, v);
        },
        .break_stmt, .continue_stmt => {},
        .print_stmt => |ps| {
            for (ps.args) |a| freeExpr(allocator, a);
            allocator.free(ps.args);
        },
        .def_decl => |dd| freeDefDecl(allocator, dd),
        .class_decl => |cd| {
            freeAnnotations(allocator, cd.annotations);
            for (cd.fields) |f| {
                freeAnnotations(allocator, f.annotations);
                if (f.type_ann) |t| freeTypeAnn(allocator, t);
                if (f.init) |e| freeExpr(allocator, e);
            }
            allocator.free(cd.fields);
            for (cd.methods) |m| freeDefDecl(allocator, m);
            allocator.free(cd.methods);
        },
        .struct_decl => |sd| {
            freeAnnotations(allocator, sd.annotations);
            for (sd.fields) |f| freeTypeAnn(allocator, f.type_ann);
            allocator.free(sd.fields);
        },
        .enum_decl => |ed| {
            freeAnnotations(allocator, ed.annotations);
            for (ed.variants) |v| {
                for (v.payload) |p| freeTypeAnn(allocator, p.type_ann);
                allocator.free(v.payload);
            }
            allocator.free(ed.variants);
        },
        .use_decl => |ud| allocator.free(ud.items),
        .defer_stmt => |d| {
            freeStatement(allocator, d.body);
            allocator.destroy(d.body);
        },
        .local_decl, .asm_stmt, .unknown => {},
    }
}

fn freeDefDecl(allocator: std.mem.Allocator, d: DefDecl) void {
    freeAnnotations(allocator, d.annotations);
    for (d.params) |p| if (p.type_ann) |t| freeTypeAnn(allocator, t);
    allocator.free(d.params);
    if (d.ret_type) |r| freeTypeAnn(allocator, r);
    freeStatementList(allocator, d.body);
}

fn freeStatementList(allocator: std.mem.Allocator, list: []Statement) void {
    for (list) |*s| freeStatement(allocator, s);
    allocator.free(list);
}

fn freeIfArmsAndElse(
    allocator: std.mem.Allocator,
    arms: []IfArm,
    else_body: ?[]Statement,
) void {
    for (arms) |arm| {
        if (arm.cond) |c| freeExpr(allocator, c);
        if (arm.let_pattern) |p| freePattern(allocator, p);
        if (arm.let_expr) |e| freeExpr(allocator, e);
        if (arm.let_guard) |g| freeExpr(allocator, g);
        freeStatementList(allocator, arm.body);
    }
    allocator.free(arms);
    if (else_body) |body| freeStatementList(allocator, body);
}

fn freeAnnotations(allocator: std.mem.Allocator, anns: []Annotation) void {
    for (anns) |a| {
        for (a.args) |arg| freeExpr(allocator, arg);
        allocator.free(a.args);
    }
    allocator.free(anns);
}

/// Recursively release an expression tree owned by `allocator`.
pub fn freeExpr(allocator: std.mem.Allocator, e: *Expr) void {
    switch (e.*) {
        .int_lit, .fixed_lit, .bool_lit, .nil_lit, .char_lit, .ident, .self_expr, .super_expr => {},
        .str_lit => |s| {
            for (s.parts) |p| switch (p) {
                .lit => {},
                .interp => |ip| freeExpr(allocator, ip.expr),
            };
            allocator.free(s.parts);
        },
        .paren => |p| freeExpr(allocator, p.inner),
        .unary => |u| freeExpr(allocator, u.operand),
        .binary => |b| {
            freeExpr(allocator, b.lhs);
            freeExpr(allocator, b.rhs);
        },
        .range => |r| {
            freeExpr(allocator, r.start);
            freeExpr(allocator, r.end);
        },
        .call => |c| {
            freeExpr(allocator, c.callee);
            for (c.args) |a| freeExpr(allocator, a);
            allocator.free(c.args);
        },
        .method_call => |m| {
            freeExpr(allocator, m.receiver);
            for (m.args) |a| freeExpr(allocator, a);
            allocator.free(m.args);
        },
        .field => |f| freeExpr(allocator, f.receiver),
        .index => |i| {
            freeExpr(allocator, i.receiver);
            freeExpr(allocator, i.index);
        },
        .do_expr => |d| freeStatementList(allocator, d.body),
        .if_expr => |ie| freeIfArmsAndElse(allocator, ie.arms, ie.else_body),
        .lambda => |l| {
            for (l.params) |p| if (p.type_ann) |t| freeTypeAnn(allocator, t);
            allocator.free(l.params);
            if (l.ret_type) |r| freeTypeAnn(allocator, r);
            freeStatementList(allocator, l.body);
        },
        .list_lit => |ll| {
            for (ll.elems) |x| freeExpr(allocator, x);
            allocator.free(ll.elems);
        },
        .struct_lit => |sl| {
            for (sl.fields) |f| freeExpr(allocator, f.value);
            allocator.free(sl.fields);
        },
        .tuple_lit => |tl| {
            for (tl.elems) |x| freeExpr(allocator, x);
            allocator.free(tl.elems);
        },
        .is_test => |it| freeExpr(allocator, it.lhs),
        .cast => |c| {
            freeExpr(allocator, c.inner);
            freeTypeAnn(allocator, c.target_type);
        },
    }
    allocator.destroy(e);
}

/// Recursively release a pattern tree owned by `allocator`.
pub fn freePattern(allocator: std.mem.Allocator, p: *Pattern) void {
    switch (p.*) {
        .wildcard,
        .ident,
        .int_lit,
        .str_lit,
        .char_lit,
        .bool_lit,
        .nil_lit,
        => {},
        .or_pattern => |op| {
            for (op.alts) |a| freePattern(allocator, a);
            allocator.free(op.alts);
        },
        .range_pattern => |rp| {
            freeExpr(allocator, rp.start);
            freeExpr(allocator, rp.end);
        },
        .tuple_pattern => |tp| {
            for (tp.elems) |e| freePattern(allocator, e);
            allocator.free(tp.elems);
        },
        .variant_pattern => |vp| {
            for (vp.args) |a| freePattern(allocator, a);
            allocator.free(vp.args);
        },
        .struct_pattern => |sp| {
            for (sp.fields) |f| freePattern(allocator, f.sub);
            allocator.free(sp.fields);
        },
    }
    allocator.destroy(p);
}

/// Recursively release a type-annotation tree owned by `allocator`.
pub fn freeTypeAnn(allocator: std.mem.Allocator, t: *TypeAnn) void {
    switch (t.*) {
        .named => {},
        .nullable => |n| freeTypeAnn(allocator, n.inner),
        .array => |a| {
            freeTypeAnn(allocator, a.elem);
            freeExpr(allocator, a.len_expr);
        },
        .vec => |v| freeTypeAnn(allocator, v.elem),
        .tuple => |tu| {
            for (tu.elems) |e| freeTypeAnn(allocator, e);
            allocator.free(tu.elems);
        },
        .fn_type => |fn_t| {
            for (fn_t.params) |p| freeTypeAnn(allocator, p);
            allocator.free(fn_t.params);
            if (fn_t.ret) |r| freeTypeAnn(allocator, r);
        },
    }
    allocator.destroy(t);
}
