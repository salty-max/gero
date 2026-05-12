/// Assembler AST — what the unified knit parser emits, what the
/// symbol pass / codegen consume. Each node carries a `Span` so
/// diagnostics can resolve back to `(file, line, col)` via the
/// `SourceMap` from the include resolver.
const std = @import("std");
const lexer = @import("lexer.zig");
const vm = @import("../vm/vm.zig");

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
    data8: DataDecl,
    data16: DataDecl,
    struct_decl: StructDecl,
    org: OrgDecl,
    instruction: Instruction,
    /// Catch-all for unrecognized lines — carries a span so the
    /// consumer can skip past it cleanly.
    unknown: Unknown,

    /// Smallest `Span` covering the whole statement.
    pub fn span(self: Statement) Span {
        return switch (self) {
            .label => |l| l.span,
            .const_decl => |c| c.span,
            .data8 => |d| d.span,
            .data16 => |d| d.span,
            .struct_decl => |s| s.span,
            .org => |o| o.span,
            .instruction => |i| i.span,
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

/// `data8 NAME = value, ...` / `data16 NAME = value, ...` —
/// emits a labeled byte (or LE word) sequence at the current
/// emit position. The kind (data8 vs data16) lives in the
/// `Statement` variant, so this struct is shared between both.
pub const DataDecl = struct {
    /// Span of the identifier being bound (without the directive
    /// keyword or the `=`).
    name: Span,
    /// Comma-separated value list, in source order. Owned by the
    /// program allocator (each entry may carry an owned `*Expr`
    /// sub-tree).
    values: []DataValue,
    /// Span covering `<kw> NAME = v1, v2, ...` end-to-end.
    span: Span,
};

/// One entry in a `data8` / `data16` value list. Per asm spec
/// §2.2 the form can be one of:
///
/// - hex literal, char literal, or parenthesized expression —
///   captured as `.expr` (the general compile-time-u16 case)
/// - address literal `&FFFF` — `.addr_lit`
/// - `@`-prefixed symbol reference — `.sym_ref`
/// - string literal `"..."` — `.string` (data8 only; the parser
///   rejects strings inside `data16`)
/// - `reserve N` — `.reserve` (emits N zero units; N is itself
///   an expression)
pub const DataValue = union(enum) {
    expr: ExprValue,
    addr_lit: AddrLit,
    sym_ref: SymRef,
    string: StringLit,
    reserve: ReserveForm,

    /// Smallest `Span` covering the value's source bytes.
    pub fn span(self: DataValue) Span {
        return switch (self) {
            .expr => |e| e.span,
            .addr_lit => |a| a.span,
            .sym_ref => |s| s.span,
            .string => |s| s.span,
            .reserve => |r| r.span,
        };
    }
};

/// Pre-parsed expression value wrapped to keep the union flat.
pub const ExprValue = struct {
    expr: *Expr,
    span: Span,
};

/// `&FFFF` — already-parsed `u16` address.
pub const AddrLit = struct {
    value: u16,
    span: Span,
};

/// `@sym` — symbol reference. The actual address gets patched in
/// during the symbol-resolution pass (#35); for now the parser
/// just records the lexeme span.
pub const SymRef = struct {
    /// Span of the `@sym` token, including the leading `@`.
    span: Span,
};

/// `"..."` — string literal. The raw bytes (with escape
/// sequences) live at `source[span.start + 1 .. span.end - 1]`.
/// Codegen decodes the escapes per asm spec §1.5.
pub const StringLit = struct {
    span: Span,
};

/// `reserve N` — emits N zero units (bytes in `data8`, LE words
/// in `data16`). `count_expr` is folded at parse time; the
/// resulting count is stored alongside for emission convenience.
pub const ReserveForm = struct {
    count_expr: *Expr,
    /// `null` if the count expression failed to evaluate at parse
    /// time (a diagnostic was emitted). Codegen treats this as a
    /// no-op for the failed entry.
    count: ?u16,
    span: Span,
};

/// `struct NAME { field: TYPE, ... }` — compile-time struct
/// layout. No bytes get emitted at the struct's source position;
/// each field produces an offset constant accessible as
/// `NAME.field` in expressions (the parser injects these into
/// the `ConstantTable` as it walks fields).
pub const StructDecl = struct {
    /// Span of the struct type name (without `struct` keyword
    /// or the `{`).
    name: Span,
    /// Fields in declaration order. The parser computes each
    /// field's offset as it walks: `u8` adds 1 to the running
    /// offset, `u16` adds 2. Layout is packed — no padding.
    fields: []StructField,
    /// Total layout size (= last field's offset + its width).
    /// `0` for an empty struct.
    size: u16,
    /// Span covering `struct NAME { ... }` end-to-end.
    span: Span,
};

/// One field of a `struct` block. Field offsets start at zero
/// for the first field and accumulate as fields are walked.
pub const StructField = struct {
    /// Span of the field's identifier.
    name: Span,
    /// `u8` (1 byte) or `u16` (2 bytes). Per asm spec §2.2 these
    /// are the only field types in v0.1.
    ty: FieldType,
    /// Byte offset within the struct.
    offset: u16,
    /// Span covering `field: type` end-to-end.
    span: Span,
};

/// Field type per asm spec §2.2. The width values are 1 byte for
/// `u8`, 2 bytes for `u16`; nothing wider in v0.1. Variant names
/// match the source-level keyword so `std.meta.stringToEnum`
/// resolves them directly.
pub const FieldType = enum {
    u8,
    u16,

    /// Byte width of this type.
    pub fn width(self: FieldType) u16 {
        return switch (self) {
            .u8 => 1,
            .u16 => 2,
        };
    }
};

/// `org $ADDR` — relocate the codegen emit cursor. The RHS is a
/// compile-time expression (typically a hex literal or a const
/// reference). The parser folds it eagerly so codegen can use
/// `addr` directly. Backward-`org` checking (overlap → E014)
/// happens at codegen against the actual emit position, not
/// here.
pub const OrgDecl = struct {
    /// RHS expression tree, owned by the program allocator.
    addr_expr: *Expr,
    /// Folded address value, or `null` if eval failed (in which
    /// case a diagnostic was emitted). Codegen treats `null` as
    /// a no-op for the directive.
    addr: ?u16,
    /// Span covering `org <expr>` end-to-end.
    span: Span,
};

/// An instruction line — a mnemonic followed by zero or more
/// operands. Per asm spec §2.3 the assembler picks the right
/// opcode encoding from the operand types at codegen time
/// (#36's job). The parser just records the mnemonic name +
/// operand shapes.
pub const Instruction = struct {
    /// Span of the mnemonic identifier (lexeme bytes recover via
    /// `source[mnemonic.start..mnemonic.end]`).
    mnemonic: Span,
    /// Comma-separated operands in source order, owned by the
    /// program allocator.
    operands: []Operand,
    /// Span covering the whole instruction.
    span: Span,
};

/// One operand of an instruction. Per asm spec §3, an operand
/// is one of these shapes. Slice A of the parser covers the
/// simple forms; the complex address forms (`&[expr]`,
/// `[addr + reg]` indexed, `<Type> @sym.field` cast) arrive in
/// slice B.
pub const Operand = union(enum) {
    /// A register name (`r1`, `acu`, `sp`, …) — see asm spec §3.1.
    register: RegisterRef,
    /// Indirect via register: `[r1]` — see asm spec §3.2.
    indirect: IndirectReg,
    /// Immediate value: `$FFFF` / `'A'` / a compile-time
    /// expression. The evaluator folds it to a `u16` at codegen
    /// time (or earlier, if the expression contains no forward
    /// refs).
    immediate: *Expr,
    /// `&FFFF` — pre-resolved address literal.
    addr_lit: AddrLit,
    /// `@sym` — symbol reference (resolved by #35).
    sym_ref: SymRef,
    /// Bare identifier in operand position — refers to a label
    /// or a `const`. Resolution is the symbol-table pass's job.
    label_ref: LabelRef,

    /// Smallest `Span` covering the operand.
    pub fn span(self: Operand) Span {
        return switch (self) {
            .register => |r| r.span,
            .indirect => |i| i.span,
            .immediate => |e| e.span(),
            .addr_lit => |a| a.span,
            .sym_ref => |s| s.span,
            .label_ref => |l| l.span,
        };
    }
};

/// Register reference (`r1`, `acu`, …). The parser resolves the
/// identifier to a `vm.Register` enum at parse time so codegen
/// can emit the operand index directly via `@intFromEnum`.
pub const RegisterRef = struct {
    id: vm.Register,
    span: Span,
};

/// `[reg]` — indirect via register. The inner register reference
/// lives in `reg`; `span` covers the brackets too.
pub const IndirectReg = struct {
    reg: RegisterRef,
    span: Span,
};

/// Bare identifier in operand position — refers to a label
/// (`jmp loop`) or a previously-defined `const`. The symbol pass
/// (#35) resolves it; the parser just records the lexeme span.
pub const LabelRef = struct {
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
    /// trees hanging off `const_decl` / `data8` / `data16`
    /// statements.
    pub fn deinit(self: *Program) void {
        for (self.statements) |s| {
            switch (s) {
                .const_decl => |c| freeExpr(self.allocator, c.expr),
                .data8, .data16 => |d| {
                    for (d.values) |v| switch (v) {
                        .expr => |e| freeExpr(self.allocator, e.expr),
                        .reserve => |r| freeExpr(self.allocator, r.count_expr),
                        .addr_lit, .sym_ref, .string => {},
                    };
                    self.allocator.free(d.values);
                },
                .struct_decl => |sd| self.allocator.free(sd.fields),
                .org => |o| freeExpr(self.allocator, o.addr_expr),
                .instruction => |i| {
                    for (i.operands) |op| switch (op) {
                        .immediate => |e| freeExpr(self.allocator, e),
                        .register, .indirect, .addr_lit, .sym_ref, .label_ref => {},
                    };
                    self.allocator.free(i.operands);
                },
                else => {},
            }
        }
        self.allocator.free(self.statements);
    }
};
