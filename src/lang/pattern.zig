/// Pattern parser — `let` destructuring (§4.1.1), `if let`
/// (§4.4.1), `while let` (§4.5.2), `match` arms (§4.8.1). Builds
/// every pattern shape the spec lists.
///
/// Imports `Parser` + `ParserError` from `parser.zig`; calls
/// `expr.parseExpression` for the bounds of a range pattern.
const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const expr_mod = @import("expr.zig");

const Parser = parser_mod.Parser;
const ParserError = parser_mod.ParserError;

/// Parse a pattern. Handles or-patterns `A | B | C` at the top
/// level — atoms compose via the leading bar.
pub fn parsePattern(p: *Parser) ParserError!*ast.Pattern {
    var first = try parseAtomicPattern(p);
    errdefer ast.freePattern(p.allocator, first);

    if (!p.check(.pipe)) return first;

    var alts: std.ArrayList(*ast.Pattern) = .empty;
    errdefer {
        for (alts.items) |a| ast.freePattern(p.allocator, a);
        alts.deinit(p.allocator);
    }
    try alts.append(p.allocator, first);
    var end_span = first.span();

    while (p.accept(.pipe)) |_| {
        const next = try parseAtomicPattern(p);
        end_span = next.span();
        try alts.append(p.allocator, next);
    }
    const start = alts.items[0].span().start;
    return try p.allocPattern(.{ .or_pattern = .{
        .alts = try alts.toOwnedSlice(p.allocator),
        .span = .{ .start = start, .end = end_span.end },
    } });
}

fn parseAtomicPattern(p: *Parser) ParserError!*ast.Pattern {
    const tok = p.peek();
    switch (tok.kind) {
        .int_lit => {
            p.pos += 1;
            if (p.check(.dot_dot) or p.check(.dot_dot_eq)) {
                return try parseRangePatternFrom(p, intLitExpr(tok), tok.start);
            }
            // Char literals lex as `int_lit` (lexer normalizes `'A'`
            // to int_lit with the byte value). Disambiguate here so
            // pattern matching against `'A'` produces a `char_lit`
            // pattern, not an int_lit pattern.
            if (tok.start < p.source.len and p.source[tok.start] == '\'') {
                // safety: lexer stores byte value of a char literal as u8 widened to i32; truncating back to u8 preserves bytes.
                return try p.allocPattern(.{ .char_lit = .{
                    .value = @intCast(tok.value),
                    .span = .{ .start = tok.start, .end = tok.end },
                } });
            }
            return try p.allocPattern(.{ .int_lit = .{
                .value = tok.value,
                .span = .{ .start = tok.start, .end = tok.end },
            } });
        },
        .kw_true => {
            p.pos += 1;
            return try p.allocPattern(.{ .bool_lit = .{
                .value = true,
                .span = .{ .start = tok.start, .end = tok.end },
            } });
        },
        .kw_false => {
            p.pos += 1;
            return try p.allocPattern(.{ .bool_lit = .{
                .value = false,
                .span = .{ .start = tok.start, .end = tok.end },
            } });
        },
        .kw_nil => {
            p.pos += 1;
            return try p.allocPattern(.{ .nil_lit = .{
                .span = .{ .start = tok.start, .end = tok.end },
            } });
        },
        .str_start => return try parseStringLitPattern(p),
        .ident => {
            const lex = p.source[tok.start..tok.end];
            if (std.mem.eql(u8, lex, "_")) {
                p.pos += 1;
                return try p.allocPattern(.{ .wildcard = .{
                    .span = .{ .start = tok.start, .end = tok.end },
                } });
            }
            const next = p.peekAt(1).kind;
            if (next == .lbrace) return try parseStructPattern(p);
            if (next == .dot) return try parseVariantPattern(p);
            p.pos += 1;
            return try p.allocPattern(.{ .ident = .{
                .name = .{ .start = tok.start, .end = tok.end },
                .span = .{ .start = tok.start, .end = tok.end },
            } });
        },
        .lparen => return try parseTuplePattern(p),
        else => {
            try p.recordError("expected pattern", "pattern");
            return error.ParseFailed;
        },
    }
}

fn intLitExpr(t: lexer.Token) ast.Expr {
    return .{ .int_lit = .{
        .value = t.value,
        .span = .{ .start = t.start, .end = t.end },
    } };
}

fn parseRangePatternFrom(
    p: *Parser,
    lo_expr_val: ast.Expr,
    start: u32,
) ParserError!*ast.Pattern {
    const inclusive = p.check(.dot_dot_eq);
    p.pos += 1;

    const lo = try p.allocExpr(lo_expr_val);
    errdefer ast.freeExpr(p.allocator, lo);

    const hi = try expr_mod.parseExpression(p, 0);

    return try p.allocPattern(.{ .range_pattern = .{
        .start = lo,
        .end = hi,
        .inclusive = inclusive,
        .span = .{ .start = start, .end = hi.span().end },
    } });
}

fn parseStringLitPattern(p: *Parser) ParserError!*ast.Pattern {
    const start_tok = try p.expect(.str_start, "\"");
    var end_idx: u32 = start_tok.end;
    while (true) {
        const t = p.peek();
        switch (t.kind) {
            .str_part => {
                p.pos += 1;
                end_idx = t.end;
            },
            .str_end => {
                p.pos += 1;
                end_idx = t.end;
                break;
            },
            .str_expr_start => {
                try p.recordError(
                    "interpolation not allowed in pattern position",
                    "literal string",
                );
                return error.ParseFailed;
            },
            else => return error.ParseFailed,
        }
    }
    return try p.allocPattern(.{ .str_lit = .{
        .span = .{ .start = start_tok.start, .end = end_idx },
    } });
}

fn parseStructPattern(p: *Parser) ParserError!*ast.Pattern {
    const name_tok = p.peek();
    p.pos += 1;
    _ = try p.expect(.lbrace, "{");

    var fields: std.ArrayList(ast.StructPatternField) = .empty;
    errdefer {
        for (fields.items) |f| ast.freePattern(p.allocator, f.sub);
        fields.deinit(p.allocator);
    }

    if (!p.check(.rbrace)) {
        while (true) {
            const fname_tok = try p.expect(.ident, "field name");
            const fname_span = ast.Span.fromToken(fname_tok);
            var sub: *ast.Pattern = undefined;
            if (p.accept(.colon)) |_| {
                sub = try parsePattern(p);
            } else {
                // Shorthand: `Foo { hp, mp }` → `hp: hp, mp: mp`.
                sub = try p.allocPattern(.{ .ident = .{
                    .name = fname_span,
                    .span = fname_span,
                } });
            }
            try fields.append(p.allocator, .{
                .name = fname_span,
                .sub = sub,
                .span = .{ .start = fname_span.start, .end = sub.span().end },
            });
            if (p.accept(.comma) == null) break;
        }
    }
    const rb = try p.expect(.rbrace, "}");
    return try p.allocPattern(.{ .struct_pattern = .{
        .type_name = ast.Span.fromToken(name_tok),
        .fields = try fields.toOwnedSlice(p.allocator),
        .span = .{ .start = name_tok.start, .end = rb.end },
    } });
}

fn parseVariantPattern(p: *Parser) ParserError!*ast.Pattern {
    const head_tok = p.peek();
    p.pos += 1;
    _ = try p.expect(.dot, ".");
    const variant_tok = try p.expect(.ident, "variant name");
    var end_idx: u32 = variant_tok.end;

    var args: std.ArrayList(*ast.Pattern) = .empty;
    errdefer {
        for (args.items) |a| ast.freePattern(p.allocator, a);
        args.deinit(p.allocator);
    }

    if (p.accept(.lparen)) |_| {
        if (!p.check(.rparen)) {
            while (true) {
                const a = try parsePattern(p);
                try args.append(p.allocator, a);
                if (p.accept(.comma) == null) break;
            }
        }
        const rp = try p.expect(.rparen, ")");
        end_idx = rp.end;
    }
    return try p.allocPattern(.{ .variant_pattern = .{
        .path = .{ .start = head_tok.start, .end = variant_tok.end },
        .args = try args.toOwnedSlice(p.allocator),
        .span = .{ .start = head_tok.start, .end = end_idx },
    } });
}

fn parseTuplePattern(p: *Parser) ParserError!*ast.Pattern {
    const lp = p.peek();
    p.pos += 1;
    var elems: std.ArrayList(*ast.Pattern) = .empty;
    errdefer {
        for (elems.items) |e| ast.freePattern(p.allocator, e);
        elems.deinit(p.allocator);
    }

    if (!p.check(.rparen)) {
        while (true) {
            const e = try parsePattern(p);
            try elems.append(p.allocator, e);
            if (p.accept(.comma) == null) break;
        }
    }
    const rp = try p.expect(.rparen, ")");
    return try p.allocPattern(.{ .tuple_pattern = .{
        .elems = try elems.toOwnedSlice(p.allocator),
        .span = .{ .start = lp.start, .end = rp.end },
    } });
}
