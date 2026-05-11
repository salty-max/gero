/// `.gas` lexer — built on `knit` so token errors share the
/// same `ParseError` shape (parser name / expected / actual /
/// kind / context) as the parser stage downstream. Each token
/// kind has its own `Parser(Token)`; the `tokenize` driver
/// composes them through `knit.choice` and surfaces multi-error
/// recovery by advancing one byte past every refusal.
const std = @import("std");
const knit = @import("knit");
const core = knit.core;

/// One syntactic atom. `start..end` are byte offsets into the
/// original source; numeric tokens also carry the parsed value.
pub const Token = struct {
    kind: Kind,
    start: u32,
    end: u32,
    /// `0` for non-numeric tokens; the parsed `u16` for `.hex`
    /// and `.addr`.
    value: u16,

    /// Token classes the lexer emits.
    pub const Kind = enum {
        hex,
        addr,
        sym_ref,
        ident,
        newline,
        colon,
        comma,
        equals,
        lbrace,
        rbrace,
        lparen,
        rparen,
        lbracket,
        rbracket,
        plus,
        minus,
        star,
        lt,
        gt,
        dot,
        /// Bare `&` — emitted when `&` isn't followed by a hex
        /// digit (so the parser sees the building blocks of
        /// `&r1` register-pointer or `&[ ]` address-expression).
        ampersand,
        eof,
    };

    /// Borrow the raw bytes the token spans in `source`.
    pub fn lexeme(self: Token, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

/// Output of `tokenize`. `tokens` always ends with `.eof`. Any
/// `ParseError` the per-token parsers raised is collected in
/// `errors` so the caller can drain every problem in a single
/// pass (`#37` formats them with `knit.formatParseErrorPretty`).
pub const TokenStream = struct {
    tokens: []Token,
    errors: []core.ParseError,
    allocator: std.mem.Allocator,

    /// Release both slices.
    pub fn deinit(self: *TokenStream) void {
        self.allocator.free(self.tokens);
        self.allocator.free(self.errors);
    }

    /// `true` when at least one token-level error was recorded.
    pub fn hasErrors(self: TokenStream) bool {
        return self.errors.len > 0;
    }
};

fn isHex(b: u8) bool {
    return (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f') or (b >= 'A' and b <= 'F');
}

fn hexValue(b: u8) u16 {
    return switch (b) {
        '0'...'9' => b - '0',
        'a'...'f' => b - 'a' + 10,
        'A'...'F' => b - 'A' + 10,
        else => 0,
    };
}

fn isIdentStart(b: u8) bool {
    return std.ascii.isAlphabetic(b) or b == '_';
}

fn isIdentCont(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

fn u32At(i: usize) u32 {
    // @as: byte offsets fit in u32 — `.gas` sources won't reach 4 GiB
    return @as(u32, @intCast(i));
}

// ---------- per-token parsers ----------

fn numericThunk(comptime prefix: u8, comptime parser_name: []const u8, comptime kind: Token.Kind) fn (*core.ParseState) core.ParseResult(Token) {
    return struct {
        fn parse(state: *core.ParseState) core.ParseResult(Token) {
            const start = state.index;
            const rem = state.remaining();
            if (rem.len == 0 or rem[0] != prefix) {
                return .{ .err = core.parseError(parser_name, start, "expected prefix", .{
                    .expected = &[_]u8{prefix},
                    .kind = .syntactic,
                }) };
            }
            var count: usize = 0;
            var value: u16 = 0;
            while (count < 5 and 1 + count < rem.len and isHex(rem[1 + count])) : (count += 1) {
                if (count < 4) value = (value << 4) | hexValue(rem[1 + count]);
            }
            if (count == 0) {
                return .{ .err = core.parseError(parser_name, start + 1, "expected 1-4 hex digits", .{
                    .expected = "hex digit",
                    .kind = .syntactic,
                }) };
            }
            if (count > 4) {
                return .{ .err = core.parseError(parser_name, start + 5, "hex literal exceeds 4 digits", .{
                    .expected = "1-4 hex digits",
                    .kind = .syntactic,
                }) };
            }
            state.advance(1 + count);
            return core.ok(Token{
                .kind = kind,
                .start = u32At(start),
                .end = u32At(state.index),
                .value = value,
            }, state.index);
        }
    }.parse;
}

const hexThunk = numericThunk('$', "hexLiteral", .hex);
const addrThunk = numericThunk('&', "addrLiteral", .addr);

fn symRefThunk(state: *core.ParseState) core.ParseResult(Token) {
    const start = state.index;
    const rem = state.remaining();
    if (rem.len == 0 or rem[0] != '!') {
        return .{ .err = core.parseError("symRef", start, "expected '!'", .{
            .expected = "!",
            .kind = .syntactic,
        }) };
    }
    if (rem.len < 2 or !isIdentStart(rem[1])) {
        return .{ .err = core.parseError("symRef", start + 1, "expected identifier after '!'", .{
            .expected = "letter or '_'",
            .kind = .syntactic,
        }) };
    }
    var j: usize = 2;
    while (j < rem.len and isIdentCont(rem[j])) j += 1;
    state.advance(j);
    return core.ok(Token{
        .kind = .sym_ref,
        .start = u32At(start),
        .end = u32At(state.index),
        .value = 0,
    }, state.index);
}

fn identThunk(state: *core.ParseState) core.ParseResult(Token) {
    const start = state.index;
    const rem = state.remaining();
    if (rem.len == 0 or !isIdentStart(rem[0])) {
        return .{ .err = core.parseError("identifier", start, "expected identifier", .{
            .expected = "letter or '_'",
            .kind = .syntactic,
        }) };
    }
    var j: usize = 1;
    while (j < rem.len and isIdentCont(rem[j])) j += 1;
    state.advance(j);
    return core.ok(Token{
        .kind = .ident,
        .start = u32At(start),
        .end = u32At(state.index),
        .value = 0,
    }, state.index);
}

fn newlineThunk(state: *core.ParseState) core.ParseResult(Token) {
    const start = state.index;
    const rem = state.remaining();
    if (rem.len == 0) {
        return .{ .err = core.parseError("newline", start, "unexpected end of input", .{
            .expected = "\\n or \\r\\n",
            .kind = .incomplete,
        }) };
    }
    if (rem[0] == '\n') {
        state.advance(1);
        return core.ok(Token{ .kind = .newline, .start = u32At(start), .end = u32At(state.index), .value = 0 }, state.index);
    }
    if (rem[0] == '\r') {
        if (rem.len >= 2 and rem[1] == '\n') {
            state.advance(2);
            return core.ok(Token{ .kind = .newline, .start = u32At(start), .end = u32At(state.index), .value = 0 }, state.index);
        }
        return .{ .err = core.parseError("newline", start, "bare CR not a valid line terminator", .{
            .expected = "\\r\\n",
            .actual = "\\r",
            .kind = .lexical,
        }) };
    }
    return .{ .err = core.parseError("newline", start, "expected newline", .{
        .expected = "\\n or \\r\\n",
        .kind = .syntactic,
    }) };
}

fn punctThunk(comptime byte: u8, comptime kind: Token.Kind, comptime name: []const u8) fn (*core.ParseState) core.ParseResult(Token) {
    return struct {
        fn parse(state: *core.ParseState) core.ParseResult(Token) {
            const start = state.index;
            const rem = state.remaining();
            if (rem.len == 0 or rem[0] != byte) {
                return .{ .err = core.parseError(name, start, "expected punctuation", .{
                    .expected = &[_]u8{byte},
                    .kind = .syntactic,
                }) };
            }
            state.advance(1);
            return core.ok(Token{ .kind = kind, .start = u32At(start), .end = u32At(state.index), .value = 0 }, state.index);
        }
    }.parse;
}

/// Wrap a Thunk into a `core.Parser(Token)`.
fn parserOf(comptime thunk: fn (*core.ParseState) core.ParseResult(Token)) core.Parser(Token) {
    return .{ .parseFn = thunk };
}

const hexP = parserOf(hexThunk);
const addrP = parserOf(addrThunk);
const symRefP = parserOf(symRefThunk);
const identP = parserOf(identThunk);
const newlineP = parserOf(newlineThunk);

const colonP = parserOf(punctThunk(':', .colon, "colon"));
const commaP = parserOf(punctThunk(',', .comma, "comma"));
const equalsP = parserOf(punctThunk('=', .equals, "equals"));
const lbraceP = parserOf(punctThunk('{', .lbrace, "lbrace"));
const rbraceP = parserOf(punctThunk('}', .rbrace, "rbrace"));
const lparenP = parserOf(punctThunk('(', .lparen, "lparen"));
const rparenP = parserOf(punctThunk(')', .rparen, "rparen"));
const lbracketP = parserOf(punctThunk('[', .lbracket, "lbracket"));
const rbracketP = parserOf(punctThunk(']', .rbracket, "rbracket"));
const plusP = parserOf(punctThunk('+', .plus, "plus"));
const minusP = parserOf(punctThunk('-', .minus, "minus"));
const starP = parserOf(punctThunk('*', .star, "star"));
const ltP = parserOf(punctThunk('<', .lt, "lt"));
const gtP = parserOf(punctThunk('>', .gt, "gt"));
const dotP = parserOf(punctThunk('.', .dot, "dot"));
/// Bare `&` only — refuses when followed by a hex digit so the
/// `addrLiteral` parser (which DOES want hex digits) handles
/// `&FFFF` and any over-length-but-still-hex variants like
/// `&12345` (those get the structured "too many digits"
/// error instead of a stream of garbage tokens).
fn ampersandThunk(state: *core.ParseState) core.ParseResult(Token) {
    const start = state.index;
    const rem = state.remaining();
    if (rem.len == 0 or rem[0] != '&') {
        return .{ .err = core.parseError("ampersand", start, "expected '&'", .{
            .expected = "&",
            .kind = .syntactic,
        }) };
    }
    if (rem.len >= 2 and isHex(rem[1])) {
        return .{ .err = core.parseError("ampersand", start, "ambiguous '&' (digit follows — let addrLiteral handle it)", .{
            .expected = "non-hex after '&'",
            .kind = .syntactic,
        }) };
    }
    state.advance(1);
    return core.ok(Token{
        .kind = .ampersand,
        .start = u32At(start),
        .end = u32At(state.index),
        .value = 0,
    }, state.index);
}

const ampersandP = parserOf(ampersandThunk);

// Order matters when every alternative refuses at the same byte:
// `knit.choice` picks the *furthest-progress* error, and ties fall
// back to the first alternative. Putting `newlineP` at the front
// makes bare `\r` surface as a "newline" lexical error instead of
// whatever the first prefix-checker would have said.
// Order matters: `addrP` must come before `ampersandP` so
// `&FFFF` is recognized as an address literal before the bare
// `&` punct gets a chance.
const oneToken = knit.choice(Token, &[_]core.Parser(Token){
    newlineP,   hexP,    addrP,     symRefP,   identP,
    colonP,     commaP,  equalsP,   lbraceP,   rbraceP,
    lparenP,    rparenP, lbracketP, rbracketP, plusP,
    minusP,     starP,   ltP,       gtP,       dotP,
    ampersandP,
});

// ---------- whitespace + comment skipping (between tokens) ----------

fn skipBlanks(state: *core.ParseState) void {
    while (state.index < state.input.len) {
        const b = state.input[state.index];
        if (b == ' ' or b == '\t') {
            state.advance(1);
        } else if (b == ';') {
            // Comment to end of line — but the newline itself is a
            // separate token, so stop before it.
            while (state.index < state.input.len and state.input[state.index] != '\n' and state.input[state.index] != '\r') {
                state.advance(1);
            }
        } else {
            break;
        }
    }
}

// ---------- driver ----------

/// Tokenize `source`. Always succeeds; lexical refusals are
/// collected into `errors` (each carries the full knit
/// `ParseError` shape — parser name, expected/actual, kind).
/// The returned token slice always ends with `.eof`.
pub fn tokenize(allocator: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error!TokenStream {
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(allocator);
    var errors: std.ArrayList(core.ParseError) = .empty;
    errdefer errors.deinit(allocator);

    var state = core.ParseState.init(source, allocator);

    while (true) {
        skipBlanks(&state);
        if (state.index >= state.input.len) break;
        const before = state.index;

        const result = oneToken.parseFn(&state);
        switch (result) {
            .ok => |ok| try tokens.append(allocator, ok.value),
            .err => |e| {
                try errors.append(allocator, e);
                // Resume at the position knit reported the error
                // (skipping every byte the winning alternative
                // already consumed), but guarantee forward
                // progress so a stuck parser can't infinite-loop.
                const target = @max(before + 1, e.index + 1);
                state.index = @min(target, state.input.len);
            },
        }
    }

    try tokens.append(allocator, .{
        .kind = .eof,
        .start = u32At(state.index),
        .end = u32At(state.index),
        .value = 0,
    });

    return .{
        .tokens = try tokens.toOwnedSlice(allocator),
        .errors = try errors.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}
