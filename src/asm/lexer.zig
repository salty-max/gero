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
        slash,
        percent,
        pipe,
        caret,
        tilde,
        /// `<<` — two bytes, longest-match before `lt`.
        shl,
        /// `>>` — two bytes, longest-match before `gt`.
        shr,
        lt,
        gt,
        dot,
        /// Bare `&` — emitted when `&` isn't followed by a hex
        /// digit (so the parser sees the building blocks of
        /// `&r1` register-pointer or `&[ ]` address-expression).
        ampersand,
        /// `"..."` literal with C-style escapes per asm spec §1.5.
        string,
        /// `'A'` literal — single byte with C-style escapes per
        /// asm spec §1.4. `value` carries the resolved byte.
        char,
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
    if (rem.len == 0 or rem[0] != '@') {
        return .{ .err = core.parseError("symRef", start, "expected '@'", .{
            .expected = "@",
            .kind = .syntactic,
        }) };
    }
    if (rem.len < 2 or !isIdentStart(rem[1])) {
        return .{ .err = core.parseError("symRef", start + 1, "expected identifier after '@'", .{
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
const slashP = parserOf(punctThunk('/', .slash, "slash"));
const percentP = parserOf(punctThunk('%', .percent, "percent"));
const pipeP = parserOf(punctThunk('|', .pipe, "pipe"));
const caretP = parserOf(punctThunk('^', .caret, "caret"));
const tildeP = parserOf(punctThunk('~', .tilde, "tilde"));
const shlP = parserOf(shiftThunk('<', .shl, "shl"));
const shrP = parserOf(shiftThunk('>', .shr, "shr"));
const ltP = parserOf(punctThunk('<', .lt, "lt"));
const gtP = parserOf(punctThunk('>', .gt, "gt"));
const dotP = parserOf(punctThunk('.', .dot, "dot"));
const stringP = parserOf(stringThunk);
const charP = parserOf(charThunk);
fn shiftThunk(comptime byte: u8, comptime kind: Token.Kind, comptime name: []const u8) fn (*core.ParseState) core.ParseResult(Token) {
    return struct {
        fn parse(state: *core.ParseState) core.ParseResult(Token) {
            const start = state.index;
            const rem = state.remaining();
            if (rem.len < 2 or rem[0] != byte or rem[1] != byte) {
                return .{ .err = core.parseError(name, start, "expected shift operator", .{
                    .expected = &[_]u8{ byte, byte },
                    .kind = .syntactic,
                }) };
            }
            state.advance(2);
            return core.ok(Token{ .kind = kind, .start = u32At(start), .end = u32At(state.index), .value = 0 }, state.index);
        }
    }.parse;
}

const decodedEscapeMissing: u16 = 0xFFFF;

fn decodeEscape(b: u8) u16 {
    return switch (b) {
        '0' => 0x00,
        'n' => 0x0A,
        'r' => 0x0D,
        't' => 0x09,
        '\\' => 0x5C,
        '"' => 0x22,
        '\'' => 0x27,
        else => decodedEscapeMissing,
    };
}

/// Match a double-quoted string literal with C-style escapes.
/// The token's span covers from the opening `"` to the closing
/// `"` (inclusive). Body decoding lives at codegen time; the
/// lexer only validates that every escape is legal and that the
/// literal closes before EOF / newline.
fn stringThunk(state: *core.ParseState) core.ParseResult(Token) {
    const start = state.index;
    const rem = state.remaining();
    if (rem.len == 0 or rem[0] != '"') {
        return .{ .err = core.parseError("string", start, "expected '\"'", .{
            .expected = "\"",
            .kind = .syntactic,
        }) };
    }
    var j: usize = 1;
    while (j < rem.len) {
        const b = rem[j];
        if (b == '"') {
            j += 1;
            state.advance(j);
            return core.ok(Token{
                .kind = .string,
                .start = u32At(start),
                .end = u32At(state.index),
                .value = 0,
            }, state.index);
        }
        if (b == '\n' or b == '\r') {
            return .{ .err = core.parseError("string", start + j, "unterminated string literal (newline before closing '\"')", .{
                .expected = "\"",
                .kind = .incomplete,
            }) };
        }
        if (b == '\\') {
            if (j + 1 >= rem.len) {
                return .{ .err = core.parseError("string", start + j, "unterminated escape at end of input", .{
                    .expected = "escape character",
                    .kind = .incomplete,
                }) };
            }
            if (decodeEscape(rem[j + 1]) == decodedEscapeMissing) {
                return .{ .err = core.parseError("string", start + j, "unknown escape sequence", .{
                    .expected = "\\0 \\n \\r \\t \\\\ \\\"",
                    .kind = .lexical,
                }) };
            }
            j += 2;
            continue;
        }
        j += 1;
    }
    return .{ .err = core.parseError("string", start + j, "unterminated string literal (EOF before closing '\"')", .{
        .expected = "\"",
        .kind = .incomplete,
    }) };
}

/// Match a single-quoted character literal per asm spec §1.4 —
/// exactly one byte (raw or backslash-escaped via the §1.5 table
/// plus `\'`), then a closing `'`. The resolved byte lives in
/// `Token.value`. Empty `''` or multi-byte `'AB'` is `E016`-shape;
/// unterminated is `.incomplete`; bad escape is `.lexical`.
fn charThunk(state: *core.ParseState) core.ParseResult(Token) {
    const start = state.index;
    const rem = state.remaining();
    if (rem.len == 0 or rem[0] != '\'') {
        return .{ .err = core.parseError("char", start, "expected '\\''", .{
            .expected = "'",
            .kind = .syntactic,
        }) };
    }
    if (rem.len < 2) {
        return .{ .err = core.parseError("char", start + 1, "unterminated char literal at end of input", .{
            .expected = "byte then '",
            .kind = .incomplete,
        }) };
    }
    if (rem[1] == '\'') {
        // Error index past the opening quote so this beats every
        // other parser's index-0 refusal in `choice()`'s
        // furthest-progress comparison — otherwise `newlineP` (first
        // in the table) wins the tie and we report a misleading
        // "newline" error for an empty char literal.
        return .{ .err = core.parseError("char", start + 1, "empty char literal", .{
            .expected = "exactly one byte between the quotes",
            .kind = .lexical,
        }) };
    }
    if (rem[1] == '\n' or rem[1] == '\r') {
        return .{ .err = core.parseError("char", start + 1, "unterminated char literal (newline before closing ')", .{
            .expected = "'",
            .kind = .incomplete,
        }) };
    }

    var value: u16 = 0;
    var body_len: usize = 0;
    if (rem[1] == '\\') {
        if (rem.len < 3) {
            return .{ .err = core.parseError("char", start + 1, "unterminated escape at end of input", .{
                .expected = "escape character",
                .kind = .incomplete,
            }) };
        }
        const decoded = decodeEscape(rem[2]);
        if (decoded == decodedEscapeMissing) {
            return .{ .err = core.parseError("char", start + 1, "unknown escape sequence", .{
                .expected = "\\0 \\n \\r \\t \\\\ \\\" \\'",
                .kind = .lexical,
            }) };
        }
        value = decoded;
        body_len = 2;
    } else {
        value = rem[1];
        body_len = 1;
    }

    const closing = 1 + body_len;
    if (rem.len <= closing) {
        return .{ .err = core.parseError("char", start + closing, "unterminated char literal at end of input", .{
            .expected = "'",
            .kind = .incomplete,
        }) };
    }
    if (rem[closing] != '\'') {
        if (rem[closing] == '\n' or rem[closing] == '\r') {
            return .{ .err = core.parseError("char", start + closing, "unterminated char literal (newline before closing ')", .{
                .expected = "'",
                .kind = .incomplete,
            }) };
        }
        return .{ .err = core.parseError("char", start + closing, "char literal must be exactly one byte", .{
            .expected = "'",
            .kind = .lexical,
        }) };
    }

    state.advance(closing + 1);
    return core.ok(Token{
        .kind = .char,
        .start = u32At(start),
        .end = u32At(state.index),
        .value = value,
    }, state.index);
}

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
// Order also matters in two longest-match cases:
//   - `addrP` before `ampersandP` so `&FFFF` is an address literal
//     before the bare `&` punct gets a chance.
//   - `shlP` / `shrP` (`<<` / `>>`) before `ltP` / `gtP` (`<` / `>`)
//     so the two-byte shift operators win over the single-byte
//     comparisons.
const oneToken = knit.choice(Token, &[_]core.Parser(Token){
    newlineP,  hexP,    addrP,   symRefP, identP,
    stringP,   charP,   colonP,  commaP,  equalsP,
    lbraceP,   rbraceP, lparenP, rparenP, lbracketP,
    rbracketP, plusP,   minusP,  starP,   slashP,
    percentP,  pipeP,   caretP,  tildeP,  shlP,
    shrP,      ltP,     gtP,     dotP,    ampersandP,
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
