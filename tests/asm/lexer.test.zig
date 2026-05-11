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
        std.debug.print("expected {d} tokens (+eof), got {d}\n", .{ kinds.len, ts.tokens.len - 1 });
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

test "lex: bare CR rejected as err" {
    try expectKinds("\r", &.{.err});
}

// ---------- numeric literals ----------

test "lex: $FF hex literal carries the parsed value" {
    var ts = try tokenize("$FF");
    defer ts.deinit();
    try std.testing.expectEqual(Token.Kind.hex, ts.tokens[0].kind);
    try std.testing.expectEqual(@as(u16, 0xFF), ts.tokens[0].value);
}

test "lex: $ABCD hex max width" {
    var ts = try tokenize("$ABCD");
    defer ts.deinit();
    try std.testing.expectEqual(@as(u16, 0xABCD), ts.tokens[0].value);
}

test "lex: hex literal with 5+ digits is rejected" {
    try expectKinds("$ABCDE", &.{.err});
}

test "lex: bare $ rejected as err" {
    try expectKinds("$", &.{.err});
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
    try expectKinds("&12345", &.{.err});
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

test "lex: identifier can't start with a digit (digit is err, rest is ident)" {
    try expectKinds("9bad", &.{ .err, .ident });
}

test "lex: !sym_ref" {
    var ts = try tokenize("!hasFrame");
    defer ts.deinit();
    try std.testing.expectEqual(Token.Kind.sym_ref, ts.tokens[0].kind);
    try std.testing.expectEqualStrings("!hasFrame", ts.tokens[0].lexeme("!hasFrame"));
}

test "lex: bare ! rejected" {
    try expectKinds("!", &.{.err});
}

test "lex: ! followed by digit rejected — both bytes flagged" {
    try expectKinds("!9", &.{ .err, .err });
}

// ---------- punctuation ----------

test "lex: all punctuation tokens" {
    try expectKinds(":,={}()[]+", &.{
        .colon, .comma, .equals, .lbrace, .rbrace, .lparen, .rparen, .lbracket, .rbracket, .plus,
    });
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

// ---------- error recovery ----------

test "lex: two errors in one line both surface" {
    var ts = try tokenize("hlt @ # foo");
    defer ts.deinit();
    var err_count: usize = 0;
    for (ts.tokens) |t| {
        if (t.kind == .err) err_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), err_count);
    try std.testing.expect(ts.hasErrors());
}

test "lex: bad token doesn't poison the rest of the stream" {
    var ts = try tokenize("@ hlt\n");
    defer ts.deinit();
    try std.testing.expectEqual(Token.Kind.err, ts.tokens[0].kind);
    try std.testing.expectEqual(Token.Kind.ident, ts.tokens[1].kind);
    try std.testing.expectEqual(Token.Kind.newline, ts.tokens[2].kind);
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
