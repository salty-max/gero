/// Assembler AST — what the unified knit parser emits, what the
/// symbol pass / codegen consume. Each node carries a `Span` so
/// diagnostics can resolve back to `(file, line, col)` via the
/// `SourceMap` from the include resolver.
const std = @import("std");
const lexer = @import("lexer.zig");

/// Byte range in the fused source buffer. The `SourceMap`
/// (`include.zig`) resolves these to per-file `(line, col)` at
/// diagnostic time.
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

/// Top-level node — every line of asm parses to one of these.
/// Directive + instruction variants land in subsequent PRs.
pub const Statement = union(enum) {
    label: Label,
    const_decl: ConstDecl,
    /// Catch-all for unrecognized lines — carries a span so the
    /// consumer can skip past it cleanly.
    unknown: Unknown,

    /// Smallest `Span` covering the whole statement.
    pub fn span(self: Statement) Span {
        return switch (self) {
            .label => |l| l.span,
            .const_decl => |c| c.span,
            .unknown => |u| u.span,
        };
    }
};

/// `name:` — binds the current emit address to `name`.
/// Resolution (forward refs, duplicates) lives in #35.
pub const Label = struct {
    /// Span of the bare identifier (without the trailing colon).
    name: Span,
    /// Span covering both the identifier and the colon.
    span: Span,
};

/// Catch-all for lines the parser failed to recognize.
pub const Unknown = struct {
    span: Span,
};

/// `const NAME = <expr>` — compile-time constant binding.
/// The RHS is evaluated at parse time (the parser maintains a
/// `ConstantTable` for cross-references). Diagnostics for
/// unresolvable `expr` end up in the parse tree's error list.
pub const ConstDecl = struct {
    /// Span of the identifier being bound (without the `const`
    /// keyword or the `=`).
    name: Span,
    /// RHS expression tree, owned by the program allocator.
    expr: *Expr,
    /// Span covering `const NAME = expr` end-to-end.
    span: Span,
};

/// Compile-time expression — what shows up on the RHS of `const`,
/// inside `&[ ... ]` address expressions, and as `data8`/`data16`
/// value-list entries. Walks via `expr.evalExpr` to a `u16` (or
/// diagnostic). The tree is allocator-owned; `freeExpr` releases
/// it recursively.
pub const Expr = union(enum) {
    hex: HexLit,
    char: CharLit,
    ident: IdentRef,
    paren: Paren,
    unary: Unary,
    binary: Binary,

    /// Smallest `Span` covering the whole expression.
    pub fn span(self: Expr) Span {
        return switch (self) {
            .hex => |h| h.span,
            .char => |c| c.span,
            .ident => |i| i.span,
            .paren => |p| p.span,
            .unary => |u| u.span,
            .binary => |b| b.span,
        };
    }
};

/// `$FFFF` — already-parsed `u16` value.
pub const HexLit = struct {
    value: u16,
    span: Span,
};

/// `'A'` — already-resolved single byte (escapes decoded by lexer).
pub const CharLit = struct {
    value: u16, // top byte always 0
    span: Span,
};

/// Bare identifier in expression position — refers to a
/// previously-defined `const`. Resolution happens at eval time.
pub const IdentRef = struct {
    /// Span of the identifier token (the lexeme bytes are
    /// recoverable via `source[span.start..span.end]`).
    span: Span,
};

/// `( inner )` — explicit grouping. The parser only keeps these
/// for span integrity; the evaluator unwraps `inner` directly.
pub const Paren = struct {
    inner: *Expr,
    span: Span,
};

/// `~x`, `-x` — unary prefix operator.
pub const Unary = struct {
    op: UnaryOp,
    operand: *Expr,
    span: Span,
};

/// `lhs op rhs` — binary infix operator. C precedence per asm
/// spec §1.7; left-associative for every level except the unary
/// chain.
pub const Binary = struct {
    op: BinaryOp,
    lhs: *Expr,
    rhs: *Expr,
    span: Span,
};

/// Unary operators per asm spec §1.7.
pub const UnaryOp = enum {
    /// `~x` — bitwise NOT.
    bit_not,
    /// `-x` — two's-complement negation (wraps in u16).
    neg,
};

/// Binary operators per asm spec §1.7. Precedence runs from
/// highest (`mul`/`div`/`mod`) to lowest (`bit_or`).
pub const BinaryOp = enum {
    mul, // *
    div, // /
    mod, // %
    add, // +
    sub, // -
    shl, // <<
    shr, // >>
    bit_and, // &
    bit_xor, // ^
    bit_or, // |
};

/// Recursively release an expression tree. Caller passes the
/// allocator that built the tree (typically the program's).
pub fn freeExpr(allocator: std.mem.Allocator, expr: *Expr) void {
    switch (expr.*) {
        .hex, .char, .ident => {},
        .paren => |p| freeExpr(allocator, p.inner),
        .unary => |u| freeExpr(allocator, u.operand),
        .binary => |b| {
            freeExpr(allocator, b.lhs);
            freeExpr(allocator, b.rhs);
        },
    }
    allocator.destroy(expr);
}

/// Output of `parse` — owned statement list. Diagnostics live
/// alongside in the `ParseTree` wrapper at the parser-level.
pub const Program = struct {
    statements: []Statement,
    allocator: std.mem.Allocator,

    /// Release the owned statement list, including any expression
    /// trees hanging off `const_decl` statements.
    pub fn deinit(self: *Program) void {
        for (self.statements) |s| {
            switch (s) {
                .const_decl => |c| freeExpr(self.allocator, c.expr),
                else => {},
            }
        }
        self.allocator.free(self.statements);
    }
};
