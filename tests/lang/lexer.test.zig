const std = @import("std");
const gero = @import("gero");
const Token = gero.lang.Token;

const alloc = std.testing.allocator;

fn tokenize(source: []const u8) !gero.lang.TokenStream {
    return gero.lang.tokenize(alloc, source);
}

fn expectKinds(source: []const u8, kinds: []const Token.Kind) !void {
    var ts = try tokenize(source);
    defer ts.deinit();
    // Compare every kind except the trailing `.eof` so callers
    // don't have to repeat it in every test.
    try std.testing.expectEqual(kinds.len + 1, ts.tokens.len);
    for (kinds, 0..) |want, i| {
        try std.testing.expectEqual(want, ts.tokens[i].kind);
    }
    try std.testing.expectEqual(Token.Kind.eof, ts.tokens[ts.tokens.len - 1].kind);
    try std.testing.expectEqual(@as(usize, 0), ts.errors.len);
}

// ---------- happy path: empty + whitespace ----------

test "lex: empty source produces only EOF" {
    var ts = try tokenize("");
    defer ts.deinit();
    try std.testing.expectEqual(@as(usize, 1), ts.tokens.len);
    try std.testing.expectEqual(Token.Kind.eof, ts.tokens[0].kind);
}

test "lex: whitespace-only source skips to EOF" {
    var ts = try tokenize("   \t   ");
    defer ts.deinit();
    try std.testing.expectEqual(@as(usize, 1), ts.tokens.len);
}

test "lex: leading newlines suppressed, trailing collapsed" {
    var ts = try tokenize("\n\n\nlet x\n\n");
    defer ts.deinit();
    // Expected: kw_let, ident, newline, eof.
    try std.testing.expectEqual(@as(usize, 4), ts.tokens.len);
    try std.testing.expectEqual(Token.Kind.kw_let, ts.tokens[0].kind);
    try std.testing.expectEqual(Token.Kind.ident, ts.tokens[1].kind);
    try std.testing.expectEqual(Token.Kind.newline, ts.tokens[2].kind);
    try std.testing.expectEqual(Token.Kind.eof, ts.tokens[3].kind);
}

// ---------- comments ----------

test "lex: -- comment runs to end of line, newline preserved" {
    try expectKinds(
        "let x -- a trailing comment\nlet y",
        &.{ .kw_let, .ident, .newline, .kw_let, .ident },
    );
}

test "lex: full-line comment doesn't produce a newline token before the next line" {
    try expectKinds(
        "-- header comment\nlet x",
        &.{ .kw_let, .ident },
    );
}

// ---------- identifiers + keywords ----------

test "lex: identifier with underscores + digits" {
    try expectKinds("snake_case_42", &.{.ident});
}

test "lex: every reserved keyword maps to its kind" {
    const cases = [_]struct { src: []const u8, kind: Token.Kind }{
        .{ .src = "let", .kind = .kw_let },
        .{ .src = "const", .kind = .kw_const },
        .{ .src = "def", .kind = .kw_def },
        .{ .src = "lambda", .kind = .kw_lambda },
        .{ .src = "return", .kind = .kw_return },
        .{ .src = "if", .kind = .kw_if },
        .{ .src = "then", .kind = .kw_then },
        .{ .src = "else", .kind = .kw_else },
        .{ .src = "elif", .kind = .kw_elif },
        .{ .src = "end", .kind = .kw_end },
        .{ .src = "while", .kind = .kw_while },
        .{ .src = "do", .kind = .kw_do },
        .{ .src = "for", .kind = .kw_for },
        .{ .src = "in", .kind = .kw_in },
        .{ .src = "step", .kind = .kw_step },
        .{ .src = "match", .kind = .kw_match },
        .{ .src = "case", .kind = .kw_case },
        .{ .src = "when", .kind = .kw_when },
        .{ .src = "class", .kind = .kw_class },
        .{ .src = "extends", .kind = .kw_extends },
        .{ .src = "self", .kind = .kw_self },
        .{ .src = "super", .kind = .kw_super },
        .{ .src = "enum", .kind = .kw_enum },
        .{ .src = "is", .kind = .kw_is },
        .{ .src = "use", .kind = .kw_use },
        .{ .src = "from", .kind = .kw_from },
        .{ .src = "as", .kind = .kw_as },
        .{ .src = "local", .kind = .kw_local },
        .{ .src = "true", .kind = .kw_true },
        .{ .src = "false", .kind = .kw_false },
        .{ .src = "nil", .kind = .kw_nil },
        .{ .src = "and", .kind = .kw_and },
        .{ .src = "or", .kind = .kw_or },
        .{ .src = "not", .kind = .kw_not },
        .{ .src = "break", .kind = .kw_break },
        .{ .src = "continue", .kind = .kw_continue },
        .{ .src = "print", .kind = .kw_print },
    };
    for (cases) |c| {
        var ts = try tokenize(c.src);
        defer ts.deinit();
        try std.testing.expectEqual(@as(usize, 2), ts.tokens.len); // kw + eof
        try std.testing.expectEqual(c.kind, ts.tokens[0].kind);
    }
}

test "lex: keyword prefix in a longer identifier stays an ident" {
    // `letter` shouldn't trigger the `let` keyword.
    try expectKinds("letter ifs return_value", &.{ .ident, .ident, .ident });
}

// ---------- numerics ----------

test "lex: decimal integer literal" {
    var ts = try tokenize("42");
    defer ts.deinit();
    try std.testing.expectEqual(Token.Kind.int_lit, ts.tokens[0].kind);
    try std.testing.expectEqual(@as(i32, 42), ts.tokens[0].value);
}

test "lex: hex integer literal" {
    var ts = try tokenize("0xFF");
    defer ts.deinit();
    try std.testing.expectEqual(Token.Kind.int_lit, ts.tokens[0].kind);
    try std.testing.expectEqual(@as(i32, 255), ts.tokens[0].value);
}

test "lex: binary integer literal with underscore separators" {
    var ts = try tokenize("0b1010_0101");
    defer ts.deinit();
    try std.testing.expectEqual(Token.Kind.int_lit, ts.tokens[0].kind);
    try std.testing.expectEqual(@as(i32, 0xA5), ts.tokens[0].value);
}

test "lex: decimal with underscore separators" {
    var ts = try tokenize("1_000_000");
    defer ts.deinit();
    try std.testing.expectEqual(@as(i32, 1_000_000), ts.tokens[0].value);
}

test "lex: negative literal at operand position is a single token" {
    // After `=`, the `-` is part of the literal.
    var ts = try tokenize("let x = -42");
    defer ts.deinit();
    try std.testing.expectEqual(Token.Kind.int_lit, ts.tokens[3].kind);
    try std.testing.expectEqual(@as(i32, -42), ts.tokens[3].value);
}

test "lex: `-` after an operand-end token is the binary minus operator" {
    // `a - 1` should lex as ident, minus, int_lit(1) — NOT
    // ident + int_lit(-1).
    var ts = try tokenize("a - 1");
    defer ts.deinit();
    try std.testing.expectEqual(Token.Kind.ident, ts.tokens[0].kind);
    try std.testing.expectEqual(Token.Kind.minus, ts.tokens[1].kind);
    try std.testing.expectEqual(Token.Kind.int_lit, ts.tokens[2].kind);
    try std.testing.expectEqual(@as(i32, 1), ts.tokens[2].value);
}

test "lex: malformed `0x` reports an error but still emits a token" {
    var ts = try tokenize("let x = 0x");
    defer ts.deinit();
    try std.testing.expect(ts.hasErrors());
}

// ---------- operators ----------

test "lex: comparison operators" {
    try expectKinds(
        "a == b != c < d <= e > f >= g",
        &.{ .ident, .eq_eq, .ident, .bang_eq, .ident, .lt, .ident, .lt_eq, .ident, .gt, .ident, .gt_eq, .ident },
    );
}

test "lex: bitwise + shift operators" {
    try expectKinds(
        "x & y | z ^ ~w << 2 >> 1",
        &.{ .ident, .amp, .ident, .pipe, .ident, .caret, .tilde, .ident, .shl, .int_lit, .shr, .int_lit },
    );
}

test "lex: arithmetic operators" {
    try expectKinds(
        "a + b * c / d % e",
        &.{ .ident, .plus, .ident, .star, .ident, .slash, .ident, .percent, .ident },
    );
}

test "lex: arrow + range operators" {
    try expectKinds(
        "x -> y; a..b; c..=d",
        &.{ .ident, .arrow, .ident, .semicolon, .ident, .dot_dot, .ident, .semicolon, .ident, .dot_dot_eq, .ident },
    );
}

test "lex: punctuation cluster" {
    // Space-separated so the longest-match operators (`!=`, `==`,
    // etc.) don't accidentally collapse the singles. The dense
    // form is exercised in the dedicated multi-char operator
    // tests above.
    try expectKinds(
        "( ) { } [ ] , . ; : ? ! =",
        &.{ .lparen, .rparen, .lbrace, .rbrace, .lbracket, .rbracket, .comma, .dot, .semicolon, .colon, .question, .bang, .equals },
    );
}

// ---------- annotations ----------

test "lex: annotation marker captures the full `@name`" {
    var ts = try tokenize("@inline");
    defer ts.deinit();
    try std.testing.expectEqual(Token.Kind.annotation, ts.tokens[0].kind);
    try std.testing.expectEqualStrings("@inline", ts.tokens[0].lexeme("@inline"));
}

test "lex: annotation with multi-word identifier" {
    var ts = try tokenize("@zero_page");
    defer ts.deinit();
    try std.testing.expectEqual(Token.Kind.annotation, ts.tokens[0].kind);
    try std.testing.expectEqual(@as(u32, 0), ts.tokens[0].start);
    try std.testing.expectEqual(@as(u32, 10), ts.tokens[0].end);
}

test "lex: `@` without trailing identifier is an error but still emits" {
    var ts = try tokenize("@ no_ident_after");
    defer ts.deinit();
    try std.testing.expect(ts.hasErrors());
}

// ---------- strings + interpolation ----------

test "lex: plain string literal" {
    try expectKinds(
        "\"hello\"",
        &.{ .str_start, .str_part, .str_end },
    );
}

test "lex: string with single interpolation matches AC schema" {
    // "x=$(x + 1)" → str_start, str_part "x=", str_expr_start,
    //                ident x, plus, int_lit 1, str_expr_end,
    //                str_part (empty trailing), str_end.
    var ts = try tokenize("\"x=$(x + 1)\"");
    defer ts.deinit();
    const want = [_]Token.Kind{
        .str_start, // "
        .str_part, // x=
        .str_expr_start, // $(
        .ident, // x
        .plus, //  +
        .int_lit, // 1
        .str_expr_end, // )
        .str_part, // (empty trailing chunk)
        .str_end, // "
    };
    try std.testing.expectEqual(@as(usize, want.len + 1), ts.tokens.len); // +1 for EOF
    for (want, 0..) |k, i| try std.testing.expectEqual(k, ts.tokens[i].kind);
}

test "lex: string with nested parens inside interp tracks depth" {
    // The inner `(` and `)` must NOT close the interpolation.
    var ts = try tokenize("\"$(f(1 + 2))\"");
    defer ts.deinit();
    // Expected: str_start, str_part(empty), str_expr_start, ident
    // f, lparen, int_lit 1, plus, int_lit 2, rparen,
    // str_expr_end, str_part(empty), str_end, eof.
    const want = [_]Token.Kind{
        .str_start, .str_part, .str_expr_start, .ident,  .lparen,
        .int_lit,   .plus,     .int_lit,        .rparen, .str_expr_end,
        .str_part,  .str_end,
    };
    try std.testing.expectEqual(@as(usize, want.len + 1), ts.tokens.len);
    for (want, 0..) |k, i| try std.testing.expectEqual(k, ts.tokens[i].kind);
}

test "lex: `$$` inside string is a literal `$$` in the part" {
    // No interpolation triggered.
    var ts = try tokenize("\"$$ literal\"");
    defer ts.deinit();
    const want = [_]Token.Kind{ .str_start, .str_part, .str_end };
    try std.testing.expectEqual(@as(usize, want.len + 1), ts.tokens.len);
    for (want, 0..) |k, i| try std.testing.expectEqual(k, ts.tokens[i].kind);
}

test "lex: escape sequences inside string survive in the part" {
    // Escapes are span-preserving; semantic decoding is the
    // parser's job.
    var ts = try tokenize("\"a\\nb\\\"c\"");
    defer ts.deinit();
    const want = [_]Token.Kind{ .str_start, .str_part, .str_end };
    try std.testing.expectEqual(@as(usize, want.len + 1), ts.tokens.len);
    for (want, 0..) |k, i| try std.testing.expectEqual(k, ts.tokens[i].kind);
}

test "lex: multiple interps in one string" {
    // "$(x) and $(y)"
    var ts = try tokenize("\"$(x) and $(y)\"");
    defer ts.deinit();
    const want = [_]Token.Kind{
        .str_start, .str_part,       .str_expr_start, .ident,        .str_expr_end,
        .str_part,  .str_expr_start, .ident,          .str_expr_end, .str_part,
        .str_end,
    };
    try std.testing.expectEqual(@as(usize, want.len + 1), ts.tokens.len);
    for (want, 0..) |k, i| try std.testing.expectEqual(k, ts.tokens[i].kind);
}

// ---------- composite sanity ----------

test "lex: small function body" {
    try expectKinds(
        "def add(a, b)\n  return a + b\nend",
        &.{
            .kw_def, .ident,  .lparen,  .ident,     .comma,
            .ident,  .rparen, .newline, .kw_return, .ident,
            .plus,   .ident,  .newline, .kw_end,
        },
    );
}

test "lex: match expression with or-pattern + guard" {
    try expectKinds(
        "match x do\n  case 1 or 2 when x > 0 then a\nend",
        &.{
            .kw_match, .ident,   .kw_do,   .newline,
            .kw_case,  .int_lit, .kw_or,   .int_lit,
            .kw_when,  .ident,   .gt,      .int_lit,
            .kw_then,  .ident,   .newline, .kw_end,
        },
    );
}
