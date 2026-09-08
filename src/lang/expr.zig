const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const decl_mod = @import("decl.zig");

const Parser = parser_mod.Parser;
const ParserError = parser_mod.ParserError;
const Kind = lexer.Token.Kind;

/// Precedence levels — higher binds tighter. Used by the Pratt
/// loop to encode `docs/gero-lang.md` §3.3.
pub const Prec = struct {
    /// Initial level passed by callers that want the full expression.
    pub const lowest: u8 = 0;
    /// `..` / `..=` — produce range values; bind loosest.
    pub const range: u8 = 1;
    /// `or` — logical OR, short-circuits.
    pub const log_or: u8 = 2;
    /// `and` — logical AND, short-circuits.
    pub const log_and: u8 = 3;
    /// `==` / `!=` / `<` / `<=` / `>` / `>=`.
    pub const compare: u8 = 4;
    /// `|` — bitwise OR.
    pub const bit_or: u8 = 5;
    /// `^` — bitwise XOR.
    pub const bit_xor: u8 = 6;
    /// `&` — bitwise AND.
    pub const bit_and: u8 = 7;
    /// `<<` / `>>` — bit shifts.
    pub const shift: u8 = 8;
    /// `+` / `-` — additive arithmetic.
    pub const add: u8 = 9;
    /// `*` / `/` / `%` — multiplicative arithmetic.
    pub const mul: u8 = 10;
    /// `is` — variant-tag test. Binds tighter than arithmetic.
    pub const is_test: u8 = 11;
    /// `as` — explicit type cast. Binds tighter than `is` so
    /// `x as u8 is Foo.A` reads as `(x as u8) is Foo.A`.
    pub const as_cast: u8 = 12;
    /// Unary prefix: `-x` / `not x` / `~x`.
    pub const unary: u8 = 13;
    /// Postfix: call `( )`, index `[ ]`, field `.`.
    pub const call: u8 = 14;
};

/// Parse an expression with the Pratt loop. `min_prec` is the
/// minimum operator precedence the loop will consume — call sites
/// pass `0` for "full expression".
pub fn parseExpression(p: *Parser, min_prec: u8) ParserError!*ast.Expr {
    p.skipNewlinesInBrackets();
    var lhs = try parseUnary(p);
    errdefer ast.freeExpr(p.allocator, lhs);

    // Whether THIS loop built `lhs` as an `and`. A parenthesized
    // `(a and b)` arrives through `parseUnary` instead, which is what
    // separates the ternary from the boolean chain (§4.2.3).
    var lhs_is_bare_and = false;

    while (true) {
        p.skipNewlinesInBrackets();
        const k = p.peek().kind;

        if (k == .dot_dot or k == .dot_dot_eq) {
            const prec = Prec.range;
            if (prec < min_prec) break;
            const inclusive = k == .dot_dot_eq;
            p.pos += 1;
            const rhs = try parseExpression(p, prec + 1);
            const new_node = try p.allocExpr(.{ .range = .{
                .start = lhs,
                .end = rhs,
                .inclusive = inclusive,
                .span = .{ .start = lhs.span().start, .end = rhs.span().end },
            } });
            lhs = new_node;
            continue;
        }

        if (k == .kw_is) {
            const prec = Prec.is_test;
            if (prec < min_prec) break;
            p.pos += 1;
            const head_tok = try p.expect(.ident, "enum or class name");
            // Two shapes:
            //   `is Enum.Variant` — qualified variant path (existing).
            //   `is ClassName`    — bare ident → class-type probe.
            if (p.check(.dot)) {
                p.pos += 1;
                const var_tok = try p.expect(.ident, "variant name");
                const path: ast.Span = .{ .start = head_tok.start, .end = var_tok.end };
                const new_node = try p.allocExpr(.{ .is_test = .{
                    .lhs = lhs,
                    .kind = .{ .variant = path },
                    .span = .{ .start = lhs.span().start, .end = var_tok.end },
                } });
                lhs = new_node;
                continue;
            }
            const class_span: ast.Span = .{ .start = head_tok.start, .end = head_tok.end };
            // Guarded downcast: `is ClassName as <lowercase-ident>`
            // binds the receiver under the new name inside the
            // surrounding `if` arm. Casing heuristic: uppercase
            // after `as` is a regular cast (`x is Foo as Bar` →
            // `(x is Foo) as Bar`), so we leave it for the
            // cast-operator branch one tier up.
            var binding_span: ?ast.Span = null;
            var test_end = head_tok.end;
            if (p.check(.kw_as) and isLowercaseIdentAt(p, p.pos + 1)) {
                p.pos += 1; // consume `as`
                const bind_tok = try p.expect(.ident, "binding name");
                binding_span = .{ .start = bind_tok.start, .end = bind_tok.end };
                test_end = bind_tok.end;
            }
            const new_node = try p.allocExpr(.{ .is_test = .{
                .lhs = lhs,
                .kind = .{ .class_type = .{ .class_name = class_span, .binding = binding_span } },
                .span = .{ .start = lhs.span().start, .end = test_end },
            } });
            lhs = new_node;
            continue;
        }

        // `x as T` — explicit type conversion (§3.8). RHS is a type
        // annotation, not an expression; uses the same parser as
        // `let x: T` / `-> T`.
        if (k == .kw_as) {
            const prec = Prec.as_cast;
            if (prec < min_prec) break;
            p.pos += 1;
            const type_mod = @import("type_ann.zig");
            const target_type = try type_mod.parseTypeAnn(p);
            const new_node = try p.allocExpr(.{ .cast = .{
                .inner = lhs,
                .target_type = target_type,
                .span = .{ .start = lhs.span().start, .end = target_type.span().end },
            } });
            lhs = new_node;
            continue;
        }

        if (binaryOpOf(k)) |info| {
            if (info.prec < min_prec) break;

            // `cond and x or y` — the ternary (§4.2.3). Parsed at the
            // `or` rather than built from two boolean operators, so
            // `and` / `or` keep their meaning everywhere else.
            if (info.op == .log_or and lhs_is_bare_and) {
                lhs = try finishAndOrTernary(p, lhs, info.prec);
                lhs_is_bare_and = false;
                continue;
            }

            p.pos += 1;
            const rhs = try parseExpression(p, info.prec + 1);
            const new_node = try p.allocExpr(.{ .binary = .{
                .op = info.op,
                .lhs = lhs,
                .rhs = rhs,
                .span = .{ .start = lhs.span().start, .end = rhs.span().end },
            } });
            lhs = new_node;
            lhs_is_bare_and = info.op == .log_and;
            continue;
        }

        break;
    }
    return lhs;
}

/// Rewrite `cond and x` (already parsed as `and_node`) plus the `or y`
/// at the cursor into the `if cond x else y end` it means. The else is
/// parsed at the `or` level so a chain nests to the right:
/// `a and b or c and d or e` is `a ? b : (c ? d : e)`.
fn finishAndOrTernary(p: *Parser, and_node: *ast.Expr, or_prec: u8) ParserError!*ast.Expr {
    p.pos += 1; // consume `or`
    const cond = and_node.binary.lhs;
    const then_expr = and_node.binary.rhs;
    // The `and` wrapper is replaced, but its operands live on in the
    // arms — release the node itself, not the tree under it.
    p.allocator.destroy(and_node);

    const else_expr = try parseExpression(p, or_prec);

    const arms = try p.allocator.alloc(ast.IfArm, 1);
    errdefer p.allocator.free(arms);
    arms[0] = .{
        .cond = cond,
        .let_pattern = null,
        .let_expr = null,
        .let_guard = null,
        .body = try exprAsBody(p, then_expr),
        .span = .{ .start = cond.span().start, .end = then_expr.span().end },
    };

    return try p.allocExpr(.{ .if_expr = .{
        .arms = arms,
        .else_body = try exprAsBody(p, else_expr),
        .from_and_or = true,
        .span = .{ .start = cond.span().start, .end = else_expr.span().end },
    } });
}

/// Wrap one expression as a single-statement branch body.
fn exprAsBody(p: *Parser, e: *ast.Expr) ParserError![]ast.Statement {
    const body = try p.allocator.alloc(ast.Statement, 1);
    body[0] = .{ .expr_stmt = .{ .expr = e, .span = e.span() } };
    return body;
}

const BinaryInfo = struct {
    op: ast.BinaryOp,
    prec: u8,
};

fn binaryOpOf(k: Kind) ?BinaryInfo {
    return switch (k) {
        .kw_or => .{ .op = .log_or, .prec = Prec.log_or },
        .kw_and => .{ .op = .log_and, .prec = Prec.log_and },
        .eq_eq => .{ .op = .eq, .prec = Prec.compare },
        .bang_eq => .{ .op = .neq, .prec = Prec.compare },
        .lt => .{ .op = .lt, .prec = Prec.compare },
        .lt_eq => .{ .op = .lte, .prec = Prec.compare },
        .gt => .{ .op = .gt, .prec = Prec.compare },
        .gt_eq => .{ .op = .gte, .prec = Prec.compare },
        .pipe => .{ .op = .bit_or, .prec = Prec.bit_or },
        .caret => .{ .op = .bit_xor, .prec = Prec.bit_xor },
        .amp => .{ .op = .bit_and, .prec = Prec.bit_and },
        .shl => .{ .op = .shl, .prec = Prec.shift },
        .shr => .{ .op = .shr, .prec = Prec.shift },
        .plus => .{ .op = .add, .prec = Prec.add },
        .minus => .{ .op = .sub, .prec = Prec.add },
        .star => .{ .op = .mul, .prec = Prec.mul },
        .slash => .{ .op = .div, .prec = Prec.mul },
        .percent => .{ .op = .mod, .prec = Prec.mul },
        else => null,
    };
}

fn parseUnary(p: *Parser) ParserError!*ast.Expr {
    p.skipNewlinesInBrackets();
    const tok = p.peek();
    switch (tok.kind) {
        .minus => {
            p.pos += 1;
            const operand = try parseUnary(p);
            return try p.allocExpr(.{ .unary = .{
                .op = .neg,
                .operand = operand,
                .span = .{ .start = tok.start, .end = operand.span().end },
            } });
        },
        .kw_not => {
            p.pos += 1;
            const operand = try parseUnary(p);
            return try p.allocExpr(.{ .unary = .{
                .op = .log_not,
                .operand = operand,
                .span = .{ .start = tok.start, .end = operand.span().end },
            } });
        },
        .tilde => {
            p.pos += 1;
            const operand = try parseUnary(p);
            return try p.allocExpr(.{ .unary = .{
                .op = .bit_not,
                .operand = operand,
                .span = .{ .start = tok.start, .end = operand.span().end },
            } });
        },
        .amp => {
            // `&x` — take a borrowed reference (§3.4.4). Same
            // precedence as other unary prefix operators.
            p.pos += 1;
            const operand = try parseUnary(p);
            return try p.allocExpr(.{ .ref_of = .{
                .inner = operand,
                .span = .{ .start = tok.start, .end = operand.span().end },
            } });
        },
        else => return try parseCallChain(p),
    }
}

fn parseCallChain(p: *Parser) ParserError!*ast.Expr {
    var e = try parsePrimary(p);
    errdefer ast.freeExpr(p.allocator, e);

    while (true) {
        // Leading-dot line continuation (§4.6.1): a `.` at the
        // start of the next line continues the postfix chain.
        // `xs\n  .filter(p)\n  .map(f)` reads as a single chained
        // expression. Only the dot triggers — bare newlines still
        // terminate the expression for binary ops.
        if (p.check(.newline) and p.peekAt(1).kind == .dot) {
            p.pos += 1;
        }
        switch (p.peek().kind) {
            // §4.6 — the bracket opening an argument list or an index
            // must touch what it applies to. `foo (x)` is `foo` then
            // `(x)`, not a call, which is what keeps a one-line block's
            // parenthesized body from being swallowed by its head. Same
            // rule as `x--` (decrement) versus `x --` (comment).
            .lparen, .lbracket => {
                if (p.peek().start != e.span().end) break;
                e = if (p.check(.lparen))
                    try parseCallArgs(p, e)
                else
                    try parseIndexAccess(p, e);
            },
            .dot => e = try parseFieldOrMethod(p, e),
            else => break,
        }
    }
    return e;
}

fn parseCallArgs(p: *Parser, callee: *ast.Expr) ParserError!*ast.Expr {
    p.pos += 1;
    p.openBracket();
    defer p.closeBracket();
    p.skipNewlines();
    var args: std.ArrayList(*ast.Expr) = .empty;
    errdefer {
        for (args.items) |a| ast.freeExpr(p.allocator, a);
        args.deinit(p.allocator);
    }
    if (!p.check(.rparen)) {
        while (true) {
            const a = try parseExpression(p, 0);
            try args.append(p.allocator, a);
            if (p.accept(.comma) == null) break;
            p.skipNewlines();
            if (p.check(.rparen)) break; // trailing comma
        }
    }
    p.skipNewlines();
    const rp = try p.expect(.rparen, ")");
    return try p.allocExpr(.{ .call = .{
        .callee = callee,
        .args = try args.toOwnedSlice(p.allocator),
        .span = .{ .start = callee.span().start, .end = rp.end },
    } });
}

fn parseIndexAccess(p: *Parser, receiver: *ast.Expr) ParserError!*ast.Expr {
    p.pos += 1;
    p.openBracket();
    defer p.closeBracket();
    const idx = try parseExpression(p, 0);
    p.skipNewlines();
    const rb = try p.expect(.rbracket, "]");
    return try p.allocExpr(.{ .index = .{
        .receiver = receiver,
        .index = idx,
        .span = .{ .start = receiver.span().start, .end = rb.end },
    } });
}

fn parseFieldOrMethod(p: *Parser, receiver: *ast.Expr) ParserError!*ast.Expr {
    p.pos += 1;
    // `tuple.N` — a positional element access. The selector is an int
    // literal (`t.0`); a char literal (`t.'a'`) also lexes as `int_lit`,
    // so exclude it. The index's range vs the tuple's arity is checked
    // in typecheck.
    if (p.check(.int_lit)) {
        const idx_tok = p.peek();
        const is_char = idx_tok.start < p.source.len and p.source[idx_tok.start] == '\'';
        if (is_char or idx_tok.value < 0 or idx_tok.value > 255) {
            try p.recordError("expected a tuple element index (`.0`, `.1`, …)", "E_SYNTAX_MISSING_TOKEN");
            return error.ParseFailed;
        }
        p.pos += 1;
        return try p.allocExpr(.{
            .tuple_index = .{
                .receiver = receiver,
                // safety: bounded to 0..255 just above.
                .index = @intCast(idx_tok.value),
                .span = .{ .start = receiver.span().start, .end = idx_tok.end },
            },
        });
    }
    // `t.0.1` — the lexer folds `0.1` into one `fixed_lit`; split its
    // `N.M` text into two chained tuple-index accesses (nested-tuple
    // element). The Q8.8-encoded `value` can't recover the indices, so
    // read the raw digits.
    if (p.check(.fixed_lit)) {
        const tok = p.peek();
        const txt = p.source[tok.start..tok.end];
        const dot = std.mem.indexOfScalar(u8, txt, '.');
        const lo: ?u8 = if (dot) |d| std.fmt.parseInt(u8, txt[0..d], 10) catch null else null;
        const hi: ?u8 = if (dot) |d| std.fmt.parseInt(u8, txt[d + 1 ..], 10) catch null else null;
        if (lo == null or hi == null) {
            try p.recordError("expected a tuple element index (`.0`, `.1`, …)", "E_SYNTAX_MISSING_TOKEN");
            return error.ParseFailed;
        }
        p.pos += 1;
        // @as: `dot` is an index within the token text, well under u32.
        const inner_end: u32 = tok.start + @as(u32, @intCast(dot.?));
        const inner = try p.allocExpr(.{ .tuple_index = .{
            .receiver = receiver,
            .index = lo.?,
            .span = .{ .start = receiver.span().start, .end = inner_end },
        } });
        return try p.allocExpr(.{ .tuple_index = .{
            .receiver = inner,
            .index = hi.?,
            .span = .{ .start = receiver.span().start, .end = tok.end },
        } });
    }
    // A name after `.` is unambiguously a member — accept the `from`
    // keyword (otherwise reserved for `use … from`) so `Vec.from(…)` parses.
    const name_tok = if (p.accept(.kw_from)) |t| t else try p.expect(.ident, "field or method name");
    if (p.check(.lparen)) {
        p.pos += 1;
        p.skipNewlines();
        var args: std.ArrayList(*ast.Expr) = .empty;
        errdefer {
            for (args.items) |a| ast.freeExpr(p.allocator, a);
            args.deinit(p.allocator);
        }
        if (!p.check(.rparen)) {
            while (true) {
                const a = try parseExpression(p, 0);
                try args.append(p.allocator, a);
                if (p.accept(.comma) == null) break;
                p.skipNewlines();
                if (p.check(.rparen)) break; // trailing comma
            }
        }
        p.skipNewlines();
        const rp = try p.expect(.rparen, ")");
        return try p.allocExpr(.{ .method_call = .{
            .receiver = receiver,
            .method = ast.Span.fromToken(name_tok),
            .args = try args.toOwnedSlice(p.allocator),
            .span = .{ .start = receiver.span().start, .end = rp.end },
        } });
    }
    return try p.allocExpr(.{ .field = .{
        .receiver = receiver,
        .field = ast.Span.fromToken(name_tok),
        .span = .{ .start = receiver.span().start, .end = name_tok.end },
    } });
}

fn parsePrimary(p: *Parser) ParserError!*ast.Expr {
    const tok = p.peek();
    switch (tok.kind) {
        .int_lit => {
            p.pos += 1;
            // The lexer emits char literals (`'A'`) as `int_lit`
            // tokens whose span starts with `'`. Disambiguate here
            // so the AST preserves the source form — `char` is a
            // distinct primitive per spec §3.1.
            if (tok.start < p.source.len and p.source[tok.start] == '\'') {
                // safety: lexer stores the byte value of a char literal in `tok.value` as u8 widened to i32; truncating back to u8 preserves bytes.
                return try p.allocExpr(.{ .char_lit = .{
                    .value = @intCast(tok.value),
                    .span = .{ .start = tok.start, .end = tok.end },
                } });
            }
            return try p.allocExpr(.{ .int_lit = .{
                .value = tok.value,
                .span = .{ .start = tok.start, .end = tok.end },
            } });
        },
        .fixed_lit => {
            p.pos += 1;
            return try p.allocExpr(.{ .fixed_lit = .{
                .value = tok.value,
                .span = .{ .start = tok.start, .end = tok.end },
            } });
        },
        .kw_true => {
            p.pos += 1;
            return try p.allocExpr(.{ .bool_lit = .{
                .value = true,
                .span = .{ .start = tok.start, .end = tok.end },
            } });
        },
        .kw_false => {
            p.pos += 1;
            return try p.allocExpr(.{ .bool_lit = .{
                .value = false,
                .span = .{ .start = tok.start, .end = tok.end },
            } });
        },
        .kw_nil => {
            p.pos += 1;
            return try p.allocExpr(.{ .nil_lit = .{
                .span = .{ .start = tok.start, .end = tok.end },
            } });
        },
        .kw_self => {
            p.pos += 1;
            return try p.allocExpr(.{ .self_expr = .{
                .span = .{ .start = tok.start, .end = tok.end },
            } });
        },
        .kw_super => {
            p.pos += 1;
            return try p.allocExpr(.{ .super_expr = .{
                .span = .{ .start = tok.start, .end = tok.end },
            } });
        },
        .ident => {
            const next = p.peekAt(1).kind;
            if (next == .lbrace and looksLikeStructLit(p)) {
                return try parseStructLit(p);
            }
            p.pos += 1;
            return try p.allocExpr(.{ .ident = .{
                .span = .{ .start = tok.start, .end = tok.end },
            } });
        },
        .str_start => return try parseStringLit(p),
        .lparen => return try parseParenOrTupleExpr(p),
        .lbracket => return try parseListLit(p),
        .kw_do => return try parseDoExpr(p),
        .kw_bake => return try parseBakeExpr(p),
        .kw_sizeof => return try parseSizeofExpr(p),
        .kw_if => return try parseIfExpr(p),
        .kw_lambda => return try parseLambda(p),
        // Short lambda form `|x| expr`, `|x, y| expr`, `|| expr`.
        // §4.7.1. At expression start, a leading `|` always means a
        // short lambda — bitwise OR is binary and never appears at
        // primary position.
        .pipe => return try parseShortLambda(p),
        else => {
            try p.recordError("expected expression", "E_SYNTAX_MISSING_TOKEN");
            return error.ParseFailed;
        },
    }
}

/// Heuristic: `TypeName { ... }` in expression position is a struct
/// literal. We use ASCII uppercase as the marker — same convention
/// the lang docs use for type names.
fn looksLikeStructLit(p: *const Parser) bool {
    const tok = p.peek();
    if (tok.start >= p.source.len) return false;
    const b = p.source[tok.start];
    return b >= 'A' and b <= 'Z';
}

/// `true` when the token at `pos` is an identifier whose first
/// byte is ASCII lowercase. Used to disambiguate `is X as Y` —
/// lowercase Y is a binding, uppercase Y is a cast target type.
fn isLowercaseIdentAt(p: *const Parser, pos: usize) bool {
    if (pos >= p.tokens.len) return false;
    const tok = p.tokens[pos];
    if (tok.kind != .ident) return false;
    if (tok.start >= p.source.len) return false;
    const b = p.source[tok.start];
    return b >= 'a' and b <= 'z';
}

fn parseStructLit(p: *Parser) ParserError!*ast.Expr {
    const name_tok = p.peek();
    p.pos += 1;
    _ = try p.expect(.lbrace, "{");
    p.openBracket();
    defer p.closeBracket();
    p.skipNewlines();

    var fields: std.ArrayList(ast.StructLitField) = .empty;
    errdefer {
        for (fields.items) |f| ast.freeExpr(p.allocator, f.value);
        fields.deinit(p.allocator);
    }

    if (!p.check(.rbrace)) {
        while (true) {
            p.skipNewlines();
            if (p.check(.rbrace)) break;
            const fname_tok = try p.expect(.ident, "field name");
            _ = try p.expect(.colon, ":");
            const value = try parseExpression(p, 0);
            try fields.append(p.allocator, .{
                .name = ast.Span.fromToken(fname_tok),
                .value = value,
                .span = .{ .start = fname_tok.start, .end = value.span().end },
            });
            if (p.accept(.comma) == null) break;
            p.skipNewlines();
        }
    }
    p.skipNewlines();
    const rb = try p.expect(.rbrace, "}");
    return try p.allocExpr(.{ .struct_lit = .{
        .type_name = ast.Span.fromToken(name_tok),
        .fields = try fields.toOwnedSlice(p.allocator),
        .span = .{ .start = name_tok.start, .end = rb.end },
    } });
}

fn parseStringLit(p: *Parser) ParserError!*ast.Expr {
    const start_tok = p.peek();
    p.pos += 1;
    var parts: std.ArrayList(ast.StrPart) = .empty;
    errdefer cleanupStrParts(p.allocator, &parts);

    var end_idx: u32 = start_tok.end;
    while (true) {
        const t = p.peek();
        switch (t.kind) {
            .str_part => {
                p.pos += 1;
                try parts.append(p.allocator, .{ .lit = .{
                    .span = .{ .start = t.start, .end = t.end },
                } });
                end_idx = t.end;
            },
            .str_expr_start => {
                p.pos += 1;
                const inner = try parseExpression(p, 0);
                // Optional `:fmt` spec — captured verbatim as a byte
                // span; the runtime formatter parses it per
                // `docs/gero-lang.md` §3.2.2.
                var fmt_span: ?ast.Span = null;
                if (p.accept(.colon)) |colon_tok| {
                    const fmt_start = colon_tok.end;
                    var depth: u32 = 0;
                    while (true) {
                        const nt = p.peek();
                        if (nt.kind == .str_expr_end and depth == 0) break;
                        if (nt.kind == .lparen) depth += 1;
                        if (nt.kind == .rparen and depth > 0) depth -= 1;
                        if (nt.kind == .eof) break;
                        p.pos += 1;
                    }
                    const fmt_end = p.peek().start;
                    fmt_span = .{ .start = fmt_start, .end = fmt_end };
                }
                const close = try p.expect(.str_expr_end, ")");
                try parts.append(p.allocator, .{ .interp = .{
                    .expr = inner,
                    .format_spec = fmt_span,
                    .span = .{ .start = t.start, .end = close.end },
                } });
                end_idx = close.end;
            },
            .str_end => {
                p.pos += 1;
                end_idx = t.end;
                break;
            },
            else => {
                try p.recordError("malformed string literal", "E_SYNTAX_MALFORMED_LITERAL");
                return error.ParseFailed;
            },
        }
    }
    return try p.allocExpr(.{ .str_lit = .{
        .parts = try parts.toOwnedSlice(p.allocator),
        .span = .{ .start = start_tok.start, .end = end_idx },
    } });
}

fn cleanupStrParts(
    allocator: std.mem.Allocator,
    parts: *std.ArrayList(ast.StrPart),
) void {
    for (parts.items) |part| switch (part) {
        .lit => {},
        .interp => |ip| ast.freeExpr(allocator, ip.expr),
    };
    parts.deinit(allocator);
}

fn parseParenOrTupleExpr(p: *Parser) ParserError!*ast.Expr {
    const lp = p.peek();
    p.pos += 1;
    p.openBracket();
    defer p.closeBracket();
    p.skipNewlines();
    const first = try parseExpression(p, 0);
    errdefer ast.freeExpr(p.allocator, first);

    if (p.accept(.rparen)) |rp| {
        return try p.allocExpr(.{ .paren = .{
            .inner = first,
            .span = .{ .start = lp.start, .end = rp.end },
        } });
    }

    var elems: std.ArrayList(*ast.Expr) = .empty;
    errdefer {
        for (elems.items) |e| ast.freeExpr(p.allocator, e);
        elems.deinit(p.allocator);
    }
    try elems.append(p.allocator, first);
    while (p.accept(.comma)) |_| {
        p.skipNewlines();
        if (p.check(.rparen)) break; // trailing comma
        const e = try parseExpression(p, 0);
        try elems.append(p.allocator, e);
    }
    const rp = try p.expect(.rparen, ")");
    return try p.allocExpr(.{ .tuple_lit = .{
        .elems = try elems.toOwnedSlice(p.allocator),
        .span = .{ .start = lp.start, .end = rp.end },
    } });
}

fn parseListLit(p: *Parser) ParserError!*ast.Expr {
    const lb = p.peek();
    p.pos += 1;
    p.openBracket();
    defer p.closeBracket();
    p.skipNewlines();
    var elems: std.ArrayList(*ast.Expr) = .empty;
    errdefer {
        for (elems.items) |e| ast.freeExpr(p.allocator, e);
        elems.deinit(p.allocator);
    }
    if (p.check(.rbracket)) {
        // `[]` — empty list.
        const rb_empty = p.peek();
        p.pos += 1;
        return try p.allocExpr(.{ .list_lit = .{
            .elems = try elems.toOwnedSlice(p.allocator),
            .span = .{ .start = lb.start, .end = rb_empty.end },
        } });
    }

    const first = try parseExpression(p, 0);

    // `[value; count]` — array-repeat literal. Disambiguated by the
    // `;` after the first element.
    if (p.accept(.semicolon)) |_| {
        errdefer ast.freeExpr(p.allocator, first);
        const count = try parseExpression(p, 0);
        errdefer ast.freeExpr(p.allocator, count);
        p.skipNewlines();
        const rb_rep = try p.expect(.rbracket, "]");
        return try p.allocExpr(.{ .list_repeat = .{
            .value = first,
            .count = count,
            .span = .{ .start = lb.start, .end = rb_rep.end },
        } });
    }

    try elems.append(p.allocator, first);
    while (p.accept(.comma)) |_| {
        p.skipNewlines();
        if (p.check(.rbracket)) break;
        const e = try parseExpression(p, 0);
        try elems.append(p.allocator, e);
    }
    p.skipNewlines();
    const rb = try p.expect(.rbracket, "]");
    return try p.allocExpr(.{ .list_lit = .{
        .elems = try elems.toOwnedSlice(p.allocator),
        .span = .{ .start = lb.start, .end = rb.end },
    } });
}

fn parseDoExpr(p: *Parser) ParserError!*ast.Expr {
    const do_tok = p.peek();
    p.pos += 1;
    p.skipNewlines();

    var body: std.ArrayList(ast.Statement) = .empty;
    errdefer parser_mod.cleanupStatements(p.allocator, &body);
    while (!p.atEnd() and !p.check(.kw_end)) {
        try parser_mod.parseStatement(p, &body);
        p.skipNewlines();
    }
    const end_tok = try p.expect(.kw_end, "end");
    return try p.allocExpr(.{ .do_expr = .{
        .body = try body.toOwnedSlice(p.allocator),
        .span = .{ .start = do_tok.start, .end = end_tok.end },
    } });
}

/// `bake do … end` — `do`-expression flagged for compile-time
/// evaluation (§3.8). `bake_start` is the start byte of the `bake`
/// keyword so the resulting span covers the whole `bake do … end`.
/// Caller must already have consumed the `bake` keyword and have
/// the parser positioned at `kw_do`.
pub fn parseBakeDoExpr(p: *Parser, bake_start: u32) ParserError!*ast.Expr {
    const inner = try parseDoExpr(p);
    inner.do_expr.is_bake = true;
    inner.do_expr.span = .{ .start = bake_start, .end = inner.do_expr.span.end };
    return inner;
}

/// `bake do … end` in expression position — e.g. `const X = bake do
/// … end`. Only `bake do` is accepted here; `bake def` lives at
/// statement position only.
/// `sizeof(T)` — compile-time byte width of a type. The arg slot
/// is a type annotation (not an expression), parsed via the
/// regular `type_ann.parseTypeAnn` path so all type forms (named,
/// array, tuple, etc.) work.
fn parseSizeofExpr(p: *Parser) ParserError!*ast.Expr {
    const sizeof_tok = p.peek();
    p.pos += 1; // consume `sizeof`
    _ = try p.expect(.lparen, "(");
    const type_mod = @import("type_ann.zig");
    const type_ann = try type_mod.parseTypeAnn(p);
    errdefer ast.freeTypeAnn(p.allocator, type_ann);
    const close = try p.expect(.rparen, ")");
    return try p.allocExpr(.{ .sizeof = .{
        .type_ann = type_ann,
        .span = .{ .start = sizeof_tok.start, .end = close.end },
    } });
}

fn parseBakeExpr(p: *Parser) ParserError!*ast.Expr {
    const bake_tok = p.peek();
    p.pos += 1; // consume `bake`
    p.skipNewlines();
    if (!p.check(.kw_do)) {
        try p.recordError(
            "in expression position `bake` must prefix a `do` block",
            "E_SYNTAX_UNEXPECTED_TOKEN",
        );
        return error.ParseFailed;
    }
    return try parseBakeDoExpr(p, bake_tok.start);
}

fn parseIfExpr(p: *Parser) ParserError!*ast.Expr {
    const start_tok = p.peek();
    const stmt_mod = @import("stmt.zig");
    const result = try stmt_mod.parseIfChain(p);
    return try p.allocExpr(.{ .if_expr = .{
        .arms = result.arms,
        .else_body = result.else_body,
        .span = .{ .start = start_tok.start, .end = result.end },
    } });
}

fn parseLambda(p: *Parser) ParserError!*ast.Expr {
    const lambda_tok = p.peek();
    p.pos += 1;
    _ = try p.expect(.lparen, "(");
    const params = try decl_mod.parseParamList(p);
    errdefer decl_mod.freeParams(p.allocator, params);

    var ret_type: ?*ast.TypeAnn = null;
    if (p.accept(.arrow)) |_| {
        const type_mod = @import("type_ann.zig");
        ret_type = try type_mod.parseTypeAnn(p);
    }
    errdefer if (ret_type) |r| ast.freeTypeAnn(p.allocator, r);

    p.skipNewlines();
    var body: std.ArrayList(ast.Statement) = .empty;
    errdefer parser_mod.cleanupStatements(p.allocator, &body);
    while (!p.atEnd() and !p.check(.kw_end)) {
        try parser_mod.parseStatement(p, &body);
        p.skipNewlines();
    }
    const end_tok = try p.expect(.kw_end, "end");
    return try p.allocExpr(.{ .lambda = .{
        .params = params,
        .ret_type = ret_type,
        .body = try body.toOwnedSlice(p.allocator),
        .span = .{ .start = lambda_tok.start, .end = end_tok.end },
    } });
}

/// Short lambda form per §4.7.1:
///
///   |x| x*2                         -- one param, expression body
///   |x, y| x + y                    -- multiple params
///   || read_input()                 -- zero params (`||` lexes as
///                                      two consecutive `pipe` tokens)
///   |x: i16| -> i16  x * 2          -- explicit types
///
/// Desugars to a `LambdaExpr` whose body is a single `return <expr>`
/// statement, so downstream passes (typechecker, codegen) handle one
/// shape only.
fn parseShortLambda(p: *Parser) ParserError!*ast.Expr {
    const open_tok = p.peek();
    p.pos += 1; // consume opening `|`

    var params: std.ArrayList(ast.Param) = .empty;
    errdefer decl_mod.freeParams(p.allocator, params.toOwnedSlice(p.allocator) catch &.{});

    if (!p.check(.pipe)) {
        while (true) {
            p.skipNewlines();
            const name_tok = try p.expect(.ident, "parameter name");
            var type_ann: ?*ast.TypeAnn = null;
            if (p.accept(.colon)) |_| {
                const type_mod = @import("type_ann.zig");
                type_ann = try type_mod.parseTypeAnn(p);
            }
            try params.append(p.allocator, .{
                .name = ast.Span.fromToken(name_tok),
                .type_ann = type_ann,
                .span = ast.Span.fromToken(name_tok),
            });
            p.skipNewlines();
            if (!p.check(.comma)) break;
            p.pos += 1; // consume `,`
        }
    }
    _ = try p.expect(.pipe, "|");

    var ret_type: ?*ast.TypeAnn = null;
    if (p.accept(.arrow)) |_| {
        const type_mod = @import("type_ann.zig");
        ret_type = try type_mod.parseTypeAnn(p);
    }
    errdefer if (ret_type) |r| ast.freeTypeAnn(p.allocator, r);

    const body_expr = try parseExpression(p, 0);
    errdefer ast.freeExpr(p.allocator, body_expr);

    // Wrap the body expression in a `return` statement so the
    // resulting `LambdaExpr` body is `[]Statement` like the long
    // form.
    var body: std.ArrayList(ast.Statement) = .empty;
    errdefer parser_mod.cleanupStatements(p.allocator, &body);
    const body_span = body_expr.span();
    try body.append(p.allocator, .{ .return_stmt = .{
        .value = body_expr,
        .span = body_span,
    } });

    const params_slice = try params.toOwnedSlice(p.allocator);
    return try p.allocExpr(.{ .lambda = .{
        .params = params_slice,
        .ret_type = ret_type,
        .body = try body.toOwnedSlice(p.allocator),
        .span = .{ .start = open_tok.start, .end = body_span.end },
    } });
}
