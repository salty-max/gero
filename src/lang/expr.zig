/// Expression parser — Pratt loop over the precedence hierarchy
/// from `docs/gero-lang.md` §3.3. Primaries cover every literal
/// + ident + paren + tuple + list + struct literal + `do…end` /
/// `if…end` / `lambda…end` expression form.
///
/// The Pratt loop in `parseExpression(min_prec)` consumes operators
/// whose precedence is ≥ `min_prec`, recursing on RHS at one tier
/// higher. Unary prefix and postfix call/index/field are folded
/// into the leaf path (`parseUnary` → `parseCallChain` →
/// `parsePrimary`).
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
    var lhs = try parseUnary(p);
    errdefer ast.freeExpr(p.allocator, lhs);

    while (true) {
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
            const head_tok = try p.expect(.ident, "enum name");
            _ = try p.expect(.dot, ".");
            const var_tok = try p.expect(.ident, "variant name");
            const path: ast.Span = .{ .start = head_tok.start, .end = var_tok.end };
            const new_node = try p.allocExpr(.{ .is_test = .{
                .lhs = lhs,
                .variant_path = path,
                .span = .{ .start = lhs.span().start, .end = var_tok.end },
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
            p.pos += 1;
            const rhs = try parseExpression(p, info.prec + 1);
            const new_node = try p.allocExpr(.{ .binary = .{
                .op = info.op,
                .lhs = lhs,
                .rhs = rhs,
                .span = .{ .start = lhs.span().start, .end = rhs.span().end },
            } });
            lhs = new_node;
            continue;
        }

        break;
    }
    return lhs;
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
            .lparen => e = try parseCallArgs(p, e),
            .lbracket => e = try parseIndexAccess(p, e),
            .dot => e = try parseFieldOrMethod(p, e),
            else => break,
        }
    }
    return e;
}

fn parseCallArgs(p: *Parser, callee: *ast.Expr) ParserError!*ast.Expr {
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
    return try p.allocExpr(.{ .call = .{
        .callee = callee,
        .args = try args.toOwnedSlice(p.allocator),
        .span = .{ .start = callee.span().start, .end = rp.end },
    } });
}

fn parseIndexAccess(p: *Parser, receiver: *ast.Expr) ParserError!*ast.Expr {
    p.pos += 1;
    const idx = try parseExpression(p, 0);
    const rb = try p.expect(.rbracket, "]");
    return try p.allocExpr(.{ .index = .{
        .receiver = receiver,
        .index = idx,
        .span = .{ .start = receiver.span().start, .end = rb.end },
    } });
}

fn parseFieldOrMethod(p: *Parser, receiver: *ast.Expr) ParserError!*ast.Expr {
    p.pos += 1;
    const name_tok = try p.expect(.ident, "field or method name");
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
        .kw_if => return try parseIfExpr(p),
        .kw_lambda => return try parseLambda(p),
        else => {
            try p.recordError("expected expression", "expression");
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

fn parseStructLit(p: *Parser) ParserError!*ast.Expr {
    const name_tok = p.peek();
    p.pos += 1;
    _ = try p.expect(.lbrace, "{");
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
                try p.recordError("malformed string literal", "string part");
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
    p.skipNewlines();
    var elems: std.ArrayList(*ast.Expr) = .empty;
    errdefer {
        for (elems.items) |e| ast.freeExpr(p.allocator, e);
        elems.deinit(p.allocator);
    }
    if (!p.check(.rbracket)) {
        while (true) {
            p.skipNewlines();
            const e = try parseExpression(p, 0);
            try elems.append(p.allocator, e);
            if (p.accept(.comma) == null) break;
            p.skipNewlines();
            if (p.check(.rbracket)) break;
        }
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
