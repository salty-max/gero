const std = @import("std");
const gero = @import("gero");
const Token = gero.asm_.Token;

fn tokenize(source: []const u8) !gero.asm_.TokenStream {
    return gero.asm_.tokenize(std.testing.allocator, source);
}

fn expectKinds(source: []const u8, kinds: []const Token.Kind) !void {
    var ts = try tokenize(source);
    defer ts.deinit();
    if (ts.tokens.len != kinds.len + 1) {
        std.debug.print(
            "expected {d} tokens (+eof), got {d}\n",
            .{ kinds.len, ts.tokens.len - 1 },
        );
        return error.TestUnexpectedTokenCount;
    }
    for (kinds, 0..) |expected, i| {
        try std.testing.expectEqual(expected, ts.tokens[i].kind);
    }
    try std.testing.expectEqual(Token.Kind.eof, ts.tokens[kinds.len].kind);
}

// ---------- whitespace + comments ----------

test "lex: empty source emits only EOF" {
    var ts = try tokenize("");
    defer ts.deinit();
    try std.testing.expectEqual(@as(usize, 1), ts.tokens.len);
    try std.testing.expectEqual(Token.Kind.eof, ts.tokens[0].kind);
    try std.testing.expect(!ts.hasErrors());
}

test "lex: spaces + tabs alone produce no tokens" {
    try expectKinds("    \t  ", &.{});
}

test "lex: comment to end of line eats nothing else" {
    try expectKinds("; full line\n", &.{.newline});
}

test "lex: inline comment doesn't eat the newline" {
    try expectKinds("hlt ; trailing\n", &.{ .ident, .newline });
}

test "lex: LF newline emitted as one token" {
    try expectKinds("\n", &.{.newline});
}

test "lex: CRLF accepted, single newline token" {
    try expectKinds("\r\n", &.{.newline});
}

test "lex: bare CR errors with lexical kind, no token emitted" {
    var ts = try tokenize("\r");
    defer ts.deinit();
    try std.testing.expectEqual(@as(usize, 1), ts.tokens.len); // just EOF
    try std.testing.expect(ts.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), ts.errors.len);
    const e = ts.errors[0];
    try std.testing.expectEqualStrings("newline", e.parser);
    try std.testing.expect(e.kind == .lexical);
}

// ---------- numeric literals ----------

test "lex: $FF hex literal carries the parsed value" {
    var ts = try tokenize("$FF");
    defer ts.deinit();
    try std.testing.expectEqual(Token.Kind.hex, ts.tokens[0].kind);
    try std.testing.expectEqual(@as(u16, 0xFF), ts.tokens[0].value);
    try std.testing.expect(!ts.hasErrors());
}

test "lex: $ABCD hex max width" {
    var ts = try tokenize("$ABCD");
    defer ts.deinit();
    try std.testing.expectEqual(@as(u16, 0xABCD), ts.tokens[0].value);
}

test "lex: hex literal with 5+ digits is rejected" {
    var ts = try tokenize("$ABCDE");
    defer ts.deinit();
    try std.testing.expect(ts.hasErrors());
    try std.testing.expectEqualStrings("hexLiteral", ts.errors[0].parser);
}

test "lex: bare $ rejected" {
    var ts = try tokenize("$");
    defer ts.deinit();
    try std.testing.expect(ts.hasErrors());
}

test "lex: lowercase hex digits accepted" {
    var ts = try tokenize("$fe");
    defer ts.deinit();
    try std.testing.expectEqual(@as(u16, 0xFE), ts.tokens[0].value);
}

test "lex: &FFFF address literal" {
    var ts = try tokenize("&8000");
    defer ts.deinit();
    try std.testing.expectEqual(Token.Kind.addr, ts.tokens[0].kind);
    try std.testing.expectEqual(@as(u16, 0x8000), ts.tokens[0].value);
}

test "lex: addr literal 5+ digits rejected" {
    var ts = try tokenize("&12345");
    defer ts.deinit();
    try std.testing.expect(ts.hasErrors());
    try std.testing.expectEqualStrings("addrLiteral", ts.errors[0].parser);
}

// ---------- identifiers + sym refs ----------

test "lex: bare identifier" {
    var ts = try tokenize("start");
    defer ts.deinit();
    try std.testing.expectEqual(Token.Kind.ident, ts.tokens[0].kind);
    try std.testing.expectEqualStrings("start", ts.tokens[0].lexeme("start"));
}

test "lex: identifier with digits and underscores" {
    var ts = try tokenize("_r1_label2");
    defer ts.deinit();
    try std.testing.expectEqual(Token.Kind.ident, ts.tokens[0].kind);
    try std.testing.expectEqual(@as(usize, 10), ts.tokens[0].end - ts.tokens[0].start);
}

test "lex: identifier can't start with a digit — emits an error then resumes" {
    var ts = try tokenize("9bad");
    defer ts.deinit();
    try std.testing.expect(ts.hasErrors());
    // Recovery: after the bad '9', the rest lexes as ident "bad".
    try std.testing.expectEqual(Token.Kind.ident, ts.tokens[0].kind);
    try std.testing.expectEqualStrings("bad", ts.tokens[0].lexeme("9bad"));
}

test "lex: !sym_ref" {
    var ts = try tokenize("!hasFrame");
    defer ts.deinit();
    try std.testing.expectEqual(Token.Kind.sym_ref, ts.tokens[0].kind);
    try std.testing.expectEqualStrings("!hasFrame", ts.tokens[0].lexeme("!hasFrame"));
}

test "lex: bare ! rejected" {
    var ts = try tokenize("!");
    defer ts.deinit();
    try std.testing.expect(ts.hasErrors());
    try std.testing.expectEqualStrings("symRef", ts.errors[0].parser);
}

test "lex: ! followed by digit rejected — both bytes flagged" {
    var ts = try tokenize("!9");
    defer ts.deinit();
    try std.testing.expect(ts.hasErrors());
    // The '!' errors via symRef; then '9' errors via the fall-through.
    try std.testing.expect(ts.errors.len >= 1);
}

// ---------- punctuation ----------

test "lex: all punctuation tokens" {
    try expectKinds(":,={}()[]+-*<>.", &.{
        .colon,  .comma,    .equals,
        .lbrace, .rbrace,   .lparen,
        .rparen, .lbracket, .rbracket,
        .plus,   .minus,    .star,
        .lt,     .gt,       .dot,
    });
}

test "lex: arithmetic expression inside &[ ]" {
    const src = "mov &[!t + r1 * STRIDE - $02], acu";
    try expectKinds(src, &.{
        .ident,   .ampersand, .lbracket,
        .sym_ref, .plus,      .ident,
        .star,    .ident,     .minus,
        .hex,     .rbracket,  .comma,
        .ident,
    });
}

test "lex: cast syntax <Type> obj.field" {
    const src = "<Player> p.hp";
    try expectKinds(src, &.{
        .lt, .ident, .gt, .ident, .dot, .ident,
    });
}

test "lex: field access in addr expression" {
    const src = "mov acu, &[!player + Player.mp]";
    try expectKinds(src, &.{
        .ident,     .ident,    .comma,
        .ampersand, .lbracket, .sym_ref,
        .plus,      .ident,    .dot,
        .ident,     .rbracket,
    });
}

test "lex: &r1 register pointer = ampersand + ident" {
    try expectKinds("&r1", &.{ .ampersand, .ident });
}

test "lex: &FFFF stays as addr literal (addr wins over ampersand)" {
    var ts = try tokenize("&FFFF");
    defer ts.deinit();
    try std.testing.expectEqual(Token.Kind.addr, ts.tokens[0].kind);
    try std.testing.expectEqual(@as(u16, 0xFFFF), ts.tokens[0].value);
}

// ---------- realistic programs ----------

test "lex: labelled instruction with operands and comment" {
    const src = "loop:\n  mov $01, r1  ; load 1\n  jne loop\n";
    try expectKinds(src, &.{
        .ident, .colon,   .newline,
        .ident, .hex,     .comma,
        .ident, .newline, .ident,
        .ident, .newline,
    });
}

test "lex: directive with brace-bound data" {
    const src = "data8 hello = { $48, $69 }\n";
    try expectKinds(src, &.{
        .ident, .ident, .equals, .lbrace, .hex, .comma, .hex, .rbrace, .newline,
    });
}

test "lex: indirect addressing [r1]" {
    const src = "mov r1, [r2]";
    try expectKinds(src, &.{
        .ident, .ident, .comma, .lbracket, .ident, .rbracket,
    });
}

test "lex: exported constant directive" {
    const src = "+const NAME = $1234\n";
    try expectKinds(src, &.{
        .plus, .ident, .ident, .equals, .hex, .newline,
    });
}

// ---------- error recovery + multi-error ----------

test "lex: two unknown bytes in one line surface as two errors" {
    var ts = try tokenize("hlt @ # foo");
    defer ts.deinit();
    try std.testing.expectEqual(@as(usize, 2), ts.errors.len);
    // The valid tokens around the bad bytes still made it through.
    try std.testing.expectEqual(Token.Kind.ident, ts.tokens[0].kind); // hlt
    try std.testing.expectEqual(Token.Kind.ident, ts.tokens[1].kind); // foo
}

test "lex: bad byte doesn't poison the rest of the stream" {
    var ts = try tokenize("@ hlt\n");
    defer ts.deinit();
    try std.testing.expect(ts.hasErrors());
    try std.testing.expectEqual(Token.Kind.ident, ts.tokens[0].kind); // hlt
    try std.testing.expectEqual(Token.Kind.newline, ts.tokens[1].kind);
}

test "lex: errors carry the knit ParseError shape" {
    var ts = try tokenize("$ABCDE");
    defer ts.deinit();
    try std.testing.expect(ts.errors.len >= 1);
    const e = ts.errors[0];
    try std.testing.expectEqualStrings("hexLiteral", e.parser);
    try std.testing.expect(e.expected != null);
    try std.testing.expect(e.kind == .syntactic);
}

// ---------- token spans ----------

test "lex: token spans cover the exact bytes" {
    var ts = try tokenize("mov $1234");
    defer ts.deinit();
    try std.testing.expectEqual(@as(u32, 0), ts.tokens[0].start);
    try std.testing.expectEqual(@as(u32, 3), ts.tokens[0].end);
    try std.testing.expectEqual(@as(u32, 4), ts.tokens[1].start);
    try std.testing.expectEqual(@as(u32, 9), ts.tokens[1].end);
}
