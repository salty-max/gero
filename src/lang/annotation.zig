/// Annotation parser — `@name` / `@name(args...)` markers that
/// the parser accumulates into a pending buffer and attaches to
/// the following decl. Both the paren form (`@bank(5)`) and the
/// bare-arg sugar (`@bank 5` — single inline arg on the same line)
/// are recognized. §3.7.
///
/// Imports `Parser` + `ParserError` from `parser.zig`; calls
/// `expr.parseExpression` to capture arg expressions.
const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const expr_mod = @import("expr.zig");

const Parser = parser_mod.Parser;
const ParserError = parser_mod.ParserError;
const Kind = lexer.Token.Kind;

/// Parse a single `@name[(args...)]` annotation. The lexer emits
/// the `@`+identifier as one `.annotation` token whose span covers
/// both bytes.
pub fn parseAnnotation(p: *Parser) ParserError!ast.Annotation {
    const at_tok = p.peek();
    p.pos += 1;

    const name_span: ast.Span = .{
        .start = at_tok.start + 1,
        .end = at_tok.end,
    };

    var args: std.ArrayList(*ast.Expr) = .empty;
    errdefer {
        for (args.items) |a| ast.freeExpr(p.allocator, a);
        args.deinit(p.allocator);
    }

    var end: u32 = at_tok.end;

    if (p.accept(.lparen)) |_| {
        if (!p.check(.rparen)) {
            while (true) {
                const arg = try expr_mod.parseExpression(p, 0);
                try args.append(p.allocator, arg);
                if (p.accept(.comma) == null) break;
            }
        }
        const close = try p.expect(.rparen, ")");
        end = close.end;
    } else if (canStartParenlessAnnotationArg(p.peek().kind)) {
        // Sugar: `@bank 5`, `@interrupt 0x06`, `@addr $FE40`. Stops
        // at the line boundary (newline) — only one expression
        // captured.
        const arg = try expr_mod.parseExpression(p, 0);
        const arg_span = arg.span();
        try args.append(p.allocator, arg);
        end = arg_span.end;
    }

    return .{
        .name = name_span,
        .args = try args.toOwnedSlice(p.allocator),
        .span = .{ .start = at_tok.start, .end = end },
    };
}

fn canStartParenlessAnnotationArg(k: Kind) bool {
    return switch (k) {
        .int_lit, .ident, .str_start, .kw_true, .kw_false, .kw_nil => true,
        else => false,
    };
}
