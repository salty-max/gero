/// Type-annotation parser — primitives, generics (`Vec(T)`),
/// nullable suffix (`T?`), arrays (`[T; N]`), tuples (`(T1, T2)`),
/// function types (`fn(args) -> ret`). Per gero-lang spec §3.
///
/// Imports `Parser` + `ParserError` from `parser.zig`; calls
/// `expr.parseExpression` for the comptime length expression in
/// `[T; N]`.
const std = @import("std");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");
const expr_mod = @import("expr.zig");

const Parser = parser_mod.Parser;
const ParserError = parser_mod.ParserError;

/// Parse a full type annotation. Postfix `?` chains so `T??` parses
/// (the typechecker is responsible for flagging the redundancy).
pub fn parseTypeAnn(p: *Parser) ParserError!*ast.TypeAnn {
    var base = try parseTypeBase(p);
    errdefer ast.freeTypeAnn(p.allocator, base);

    while (p.accept(.question)) |q| {
        const wrapped = try p.allocTypeAnn(.{ .nullable = .{
            .inner = base,
            .span = .{ .start = base.span().start, .end = q.end },
        } });
        base = wrapped;
    }
    return base;
}

fn parseTypeBase(p: *Parser) ParserError!*ast.TypeAnn {
    const tok = p.peek();
    switch (tok.kind) {
        .lbracket => return try parseArrayType(p),
        .lparen => return try parseTupleOrParenType(p),
        .ident => return try parseNamedOrVecType(p),
        else => {
            try p.recordError("expected type annotation", "type");
            return error.ParseFailed;
        },
    }
}

/// `[T; N]`.
fn parseArrayType(p: *Parser) ParserError!*ast.TypeAnn {
    const lb_tok = p.peek();
    p.pos += 1;

    const elem = try parseTypeAnn(p);
    errdefer ast.freeTypeAnn(p.allocator, elem);

    _ = try p.expect(.semicolon, ";");
    const len_expr = try expr_mod.parseExpression(p, 0);
    errdefer ast.freeExpr(p.allocator, len_expr);

    const rb_tok = try p.expect(.rbracket, "]");
    return try p.allocTypeAnn(.{ .array = .{
        .elem = elem,
        .len_expr = len_expr,
        .span = .{ .start = lb_tok.start, .end = rb_tok.end },
    } });
}

/// `(T)` → just `T` (span widened to cover the parens);
/// `(T1, T2, ...)` → tuple.
fn parseTupleOrParenType(p: *Parser) ParserError!*ast.TypeAnn {
    const lp_tok = p.peek();
    p.pos += 1;
    const first = try parseTypeAnn(p);
    errdefer ast.freeTypeAnn(p.allocator, first);

    if (p.accept(.rparen)) |rp| {
        first.* = switch (first.*) {
            .named => |n| .{ .named = .{ .name = n.name, .span = .{ .start = lp_tok.start, .end = rp.end } } },
            .nullable => |n| .{ .nullable = .{ .inner = n.inner, .span = .{ .start = lp_tok.start, .end = rp.end } } },
            .array => |a| .{ .array = .{ .elem = a.elem, .len_expr = a.len_expr, .span = .{ .start = lp_tok.start, .end = rp.end } } },
            .vec => |v| .{ .vec = .{ .elem = v.elem, .span = .{ .start = lp_tok.start, .end = rp.end } } },
            .tuple => |t| .{ .tuple = .{ .elems = t.elems, .span = .{ .start = lp_tok.start, .end = rp.end } } },
            .fn_type => |f| .{ .fn_type = .{ .params = f.params, .ret = f.ret, .span = .{ .start = lp_tok.start, .end = rp.end } } },
        };
        return first;
    }

    var elems: std.ArrayList(*ast.TypeAnn) = .empty;
    errdefer {
        for (elems.items) |t| ast.freeTypeAnn(p.allocator, t);
        elems.deinit(p.allocator);
    }
    try elems.append(p.allocator, first);

    _ = try p.expect(.comma, ",");
    while (true) {
        const t = try parseTypeAnn(p);
        try elems.append(p.allocator, t);
        if (p.accept(.comma) == null) break;
    }
    const rp = try p.expect(.rparen, ")");
    return try p.allocTypeAnn(.{ .tuple = .{
        .elems = try elems.toOwnedSlice(p.allocator),
        .span = .{ .start = lp_tok.start, .end = rp.end },
    } });
}

/// Named type, `Vec(T)`, or `fn(args) -> ret`.
fn parseNamedOrVecType(p: *Parser) ParserError!*ast.TypeAnn {
    const name_tok = p.peek();
    p.pos += 1;
    const name_lex = p.source[name_tok.start..name_tok.end];

    if (std.mem.eql(u8, name_lex, "Vec") and p.check(.lparen)) {
        p.pos += 1;
        const elem = try parseTypeAnn(p);
        errdefer ast.freeTypeAnn(p.allocator, elem);
        const rp = try p.expect(.rparen, ")");
        return try p.allocTypeAnn(.{ .vec = .{
            .elem = elem,
            .span = .{ .start = name_tok.start, .end = rp.end },
        } });
    }

    if (std.mem.eql(u8, name_lex, "fn") and p.check(.lparen)) {
        p.pos += 1;
        var params: std.ArrayList(*ast.TypeAnn) = .empty;
        errdefer {
            for (params.items) |t| ast.freeTypeAnn(p.allocator, t);
            params.deinit(p.allocator);
        }
        if (!p.check(.rparen)) {
            while (true) {
                const t = try parseTypeAnn(p);
                try params.append(p.allocator, t);
                if (p.accept(.comma) == null) break;
            }
        }
        const rp_tok = try p.expect(.rparen, ")");
        var ret: ?*ast.TypeAnn = null;
        var end: u32 = rp_tok.end;
        if (p.accept(.arrow)) |_| {
            const r = try parseTypeAnn(p);
            end = r.span().end;
            ret = r;
        }
        return try p.allocTypeAnn(.{ .fn_type = .{
            .params = try params.toOwnedSlice(p.allocator),
            .ret = ret,
            .span = .{ .start = name_tok.start, .end = end },
        } });
    }

    // Plain named type — accumulate `.qualified.path` segments. The
    // AST captures the joined source span; the typechecker
    // re-tokenizes against the lexeme.
    var end_idx: u32 = name_tok.end;
    while (p.check(.dot) and p.peekAt(1).kind == .ident) {
        p.pos += 1; // dot
        const seg = p.peek();
        p.pos += 1;
        end_idx = seg.end;
    }

    return try p.allocTypeAnn(.{ .named = .{
        .name = .{ .start = name_tok.start, .end = end_idx },
        .span = .{ .start = name_tok.start, .end = end_idx },
    } });
}
