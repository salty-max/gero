/// `.gr` lexer — same shape as `src/asm/lexer.zig` (knit-driven,
/// per-token combinator thunks, error recovery via byte-advance)
/// but tuned to the gero-lang surface: newline-significant,
/// 28+ keywords, symbolic operator set, hex/decimal/binary
/// numerics with underscores, string literals with interpolation
/// (`"$(expr)"`) and a small format-spec sublanguage.
///
/// Per gero-lang spec §2 (see `docs/gero-lang.md`). The parser
/// downstream consumes `TokenStream` and reuses knit's diagnostic
/// shape so error reporting stays unified across asm + lang.
const std = @import("std");
const knit = @import("knit");
const core = knit.core;

/// One syntactic atom emitted by `tokenize`. `start..end` are
/// byte offsets into the source string; numeric tokens also carry
/// the parsed signed value.
pub const Token = struct {
    kind: Kind,
    start: u32,
    end: u32,
    /// For `.int_lit`, the parsed value (sign extended into i32 so
    /// `-32768` fits cleanly). `0` for non-numeric tokens.
    value: i32,

    /// Token classes the lexer emits. Kept dense so a future
    /// keyword bump just appends.
    pub const Kind = enum {
        // -- literals + identifiers ---------------------------
        ident,
        /// Integer literal — decimal, hex (`0x…`), or binary
        /// (`0b…`). Underscores allowed as digit separators
        /// (`1_000`, `0b1010_0101`). Optional leading `-` is
        /// captured into the token when the lexer is at an
        /// operand position (see `is_operand_position` in the
        /// implementation); otherwise emitted as `.minus`.
        int_lit,
        /// `@`-prefixed annotation marker. `start` covers the
        /// `@`; `end` covers the trailing identifier. The parser
        /// reads the identifier from the lexeme.
        annotation,

        // -- string family (interpolation) ---------------------
        /// `"` — opens a string literal. The string body emits
        /// `str_part` / `str_expr_start` / `str_expr_end` /
        /// `str_end` until the closing `"`.
        str_start,
        /// A chunk of literal characters inside a string (escapes
        /// already resolved at parse time per the parser's needs;
        /// the lexer records raw byte ranges only). Empty parts
        /// (e.g. when `"$(x)"` opens right with an interp) are
        /// still emitted so the parser can drive a uniform
        /// `(str_part (str_expr_start … str_expr_end)?)+` loop.
        str_part,
        /// `$(` — switches the lexer into expression mode inside
        /// a string literal. Paren-depth-tracked so nested `(…)`
        /// inside the expression don't end the interpolation
        /// prematurely.
        str_expr_start,
        /// `)` matching the `str_expr_start`'s opening `$(`.
        str_expr_end,
        /// `"` — closes the string literal.
        str_end,

        // -- keywords (28+ per spec §2.6) ---------------------
        kw_let,
        kw_const,
        kw_def,
        kw_lambda,
        kw_return,
        kw_if,
        kw_then,
        kw_else,
        kw_elif,
        kw_end,
        kw_while,
        kw_do,
        kw_for,
        kw_in,
        kw_step,
        kw_match,
        kw_case,
        kw_when,
        kw_class,
        kw_extends,
        kw_self,
        kw_super,
        kw_enum,
        kw_is,
        kw_use,
        kw_from,
        kw_as,
        kw_local,
        kw_true,
        kw_false,
        kw_nil,
        kw_and,
        kw_or,
        kw_not,
        kw_break,
        kw_continue,
        kw_print,

        // -- punctuation --------------------------------------
        newline,
        lparen,
        rparen,
        lbrace,
        rbrace,
        lbracket,
        rbracket,
        comma,
        dot,
        colon,
        semicolon,
        question,
        bang,

        // -- assignment ---------------------------------------
        equals,
        /// `+=` — compound add-assign.
        plus_eq,
        /// `-=` — compound sub-assign.
        minus_eq,
        /// `*=` — compound mul-assign.
        star_eq,
        /// `/=` — compound div-assign.
        slash_eq,
        /// `%=` — compound mod-assign.
        percent_eq,
        /// `&=` — compound bitwise-AND-assign.
        amp_eq,
        /// `|=` — compound bitwise-OR-assign.
        pipe_eq,
        /// `^=` — compound bitwise-XOR-assign.
        caret_eq,
        /// `<<=` — compound shift-left-assign.
        shl_eq,
        /// `>>=` — compound shift-right-assign.
        shr_eq,

        // -- arithmetic ---------------------------------------
        plus,
        minus,
        star,
        slash,
        percent,
        /// `++` — statement-only increment, sugar for `x += 1`.
        plus_plus,
        /// `--` — statement-only decrement, sugar for `x -= 1`.
        minus_minus,

        // -- comparisons --------------------------------------
        eq_eq,
        bang_eq,
        lt,
        lt_eq,
        gt,
        gt_eq,

        // -- bitwise + shift ---------------------------------
        amp,
        pipe,
        caret,
        tilde,
        shl,
        shr,

        // -- arrows + range ---------------------------------
        /// `->` — lambda + function-return arrows.
        arrow,
        /// `..` — exclusive range.
        dot_dot,
        /// `..=` — inclusive range.
        dot_dot_eq,

        // -- end of stream -----------------------------------
        eof,
    };

    /// Borrow the raw bytes the token spans in `source`.
    pub fn lexeme(self: Token, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

/// Output of `tokenize`. `tokens` always ends with `.eof`. Any
/// `ParseError` raised during lexing is collected in `errors` so
/// the caller can drain every problem in a single pass.
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

// ---------- keyword table ----------

const KeywordEntry = struct { lex: []const u8, kind: Token.Kind };

const keyword_table = [_]KeywordEntry{
    .{ .lex = "let", .kind = .kw_let },
    .{ .lex = "const", .kind = .kw_const },
    .{ .lex = "def", .kind = .kw_def },
    .{ .lex = "lambda", .kind = .kw_lambda },
    .{ .lex = "return", .kind = .kw_return },
    .{ .lex = "if", .kind = .kw_if },
    .{ .lex = "then", .kind = .kw_then },
    .{ .lex = "else", .kind = .kw_else },
    .{ .lex = "elif", .kind = .kw_elif },
    .{ .lex = "end", .kind = .kw_end },
    .{ .lex = "while", .kind = .kw_while },
    .{ .lex = "do", .kind = .kw_do },
    .{ .lex = "for", .kind = .kw_for },
    .{ .lex = "in", .kind = .kw_in },
    .{ .lex = "step", .kind = .kw_step },
    .{ .lex = "match", .kind = .kw_match },
    .{ .lex = "case", .kind = .kw_case },
    .{ .lex = "when", .kind = .kw_when },
    .{ .lex = "class", .kind = .kw_class },
    .{ .lex = "extends", .kind = .kw_extends },
    .{ .lex = "self", .kind = .kw_self },
    .{ .lex = "super", .kind = .kw_super },
    .{ .lex = "enum", .kind = .kw_enum },
    .{ .lex = "is", .kind = .kw_is },
    .{ .lex = "use", .kind = .kw_use },
    .{ .lex = "from", .kind = .kw_from },
    .{ .lex = "as", .kind = .kw_as },
    .{ .lex = "local", .kind = .kw_local },
    .{ .lex = "true", .kind = .kw_true },
    .{ .lex = "false", .kind = .kw_false },
    .{ .lex = "nil", .kind = .kw_nil },
    .{ .lex = "and", .kind = .kw_and },
    .{ .lex = "or", .kind = .kw_or },
    .{ .lex = "not", .kind = .kw_not },
    .{ .lex = "break", .kind = .kw_break },
    .{ .lex = "continue", .kind = .kw_continue },
    .{ .lex = "print", .kind = .kw_print },
};

/// Lookup `name` (already lowercase per the identifier rule) in
/// the keyword table. Returns the matching kind, or `null` for a
/// bare identifier. Linear scan — 37 entries; switching to a
/// perfect-hash isn't worth the ceremony at this scale.
fn keywordKind(name: []const u8) ?Token.Kind {
    for (keyword_table) |kw| {
        if (std.mem.eql(u8, kw.lex, name)) return kw.kind;
    }
    return null;
}

// ---------- byte-class helpers ----------

fn isDigit(b: u8) bool {
    return b >= '0' and b <= '9';
}

fn isHexDigit(b: u8) bool {
    return isDigit(b) or (b >= 'a' and b <= 'f') or (b >= 'A' and b <= 'F');
}

fn isBinDigit(b: u8) bool {
    return b == '0' or b == '1';
}

fn isIdentStart(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or b == '_';
}

fn isIdentCont(b: u8) bool {
    return isIdentStart(b) or isDigit(b);
}

fn hexValue(b: u8) i32 {
    const raw: u8 = switch (b) {
        '0'...'9' => b - '0',
        'a'...'f' => b - 'a' + 10,
        'A'...'F' => b - 'A' + 10,
        // safety: caller pre-checks isHexDigit, so non-hex bytes
        //         never reach this branch.
        else => unreachable,
    };
    // @as: widen u8 hex digit (0..15) → i32 for the running-value math.
    return @as(i32, raw);
}

// ---------- lexer state ----------

/// `-` is part of an integer literal when emitted at an operand
/// position; otherwise it's the binary subtraction operator.
/// We track the most recently emitted token kind to drive this
/// disambiguation — same trick JavaScript and several real-world
/// lexers use for regex `/`. The set of "operand-end" kinds
/// below is what flips `-` to a standalone operator; everything
/// else falls back to "expecting an operand".
fn isOperandEnd(kind: Token.Kind) bool {
    return switch (kind) {
        .ident,
        .int_lit,
        .rparen,
        .rbrace,
        .rbracket,
        .kw_self,
        .kw_super,
        .kw_true,
        .kw_false,
        .kw_nil,
        .str_end,
        => true,
        else => false,
    };
}

/// Lexer driving state. The string-mode stack carries one
/// `StringFrame` per active string-with-interpolation context —
/// nested interpolation is allowed (`"a $( "b $(c)" )"`).
const State = struct {
    source: []const u8,
    index: u32,
    tokens: std.ArrayList(Token),
    errors: std.ArrayList(core.ParseError),
    /// Most-recent emitted kind, used by `-` disambiguation +
    /// trailing-newline collapsing.
    last_kind: ?Token.Kind,
    /// Active string-with-interpolation contexts. When non-empty,
    /// the top frame's `expr_depth` tracks the `(` / `)` balance
    /// inside `$( … )` so the matching `)` closes the interp.
    str_stack: std.ArrayList(StringFrame),
    allocator: std.mem.Allocator,

    const StringFrame = struct {
        /// When `0`, the lexer is in string-body mode (reading
        /// literal chars until `$(` or `"`). When `>= 1`, it's in
        /// expression mode and counting parens.
        expr_depth: u16,
    };
};

fn pushToken(state: *State, kind: Token.Kind, start: u32, end: u32, value: i32) !void {
    try state.tokens.append(state.allocator, .{
        .kind = kind,
        .start = start,
        .end = end,
        .value = value,
    });
    state.last_kind = kind;
}

fn pushError(state: *State, index: u32, message: []const u8, actual: []const u8) !void {
    try state.errors.append(state.allocator, .{
        .parser = "lang_lexer",
        .index = index,
        .message = message,
        .expected = "",
        .actual = actual,
        .kind = .syntactic,
    });
}

fn peekByte(state: *State, offset: usize) ?u8 {
    // @as: widen u32 cursor → usize so the offset add can't overflow.
    const i = @as(usize, state.index) + offset;
    if (i >= state.source.len) return null;
    return state.source[i];
}

fn advance(state: *State, n: u32) void {
    state.index += n;
}

fn inExprMode(state: *State) bool {
    if (state.str_stack.items.len == 0) return false;
    const top = state.str_stack.items[state.str_stack.items.len - 1];
    return top.expr_depth > 0;
}

fn inStringBody(state: *State) bool {
    if (state.str_stack.items.len == 0) return false;
    const top = state.str_stack.items[state.str_stack.items.len - 1];
    return top.expr_depth == 0;
}

// ---------- per-token lexers ----------

fn lexIdent(state: *State) !void {
    const start = state.index;
    state.index += 1; // already validated isIdentStart
    while (state.index < state.source.len and isIdentCont(state.source[state.index])) : (state.index += 1) {}
    const name = state.source[start..state.index];
    if (keywordKind(name)) |kw| {
        try pushToken(state, kw, start, state.index, 0);
    } else {
        try pushToken(state, .ident, start, state.index, 0);
    }
}

fn lexAnnotation(state: *State) !void {
    const start = state.index;
    state.index += 1; // consume `@`
    if (state.index >= state.source.len or !isIdentStart(state.source[state.index])) {
        try pushError(state, start, "expected identifier after `@`", "annotation");
        // Best-effort: emit the bare `@` with zero-width ident so
        // the parser sees something it can skip.
        try pushToken(state, .annotation, start, state.index, 0);
        return;
    }
    while (state.index < state.source.len and isIdentCont(state.source[state.index])) : (state.index += 1) {}
    try pushToken(state, .annotation, start, state.index, 0);
}

fn lexInteger(state: *State, negative: bool) !void {
    const start = if (negative) state.index - 1 else state.index;
    var value: i32 = 0;

    if (state.index + 1 < state.source.len and state.source[state.index] == '0' and
        (state.source[state.index + 1] == 'x' or state.source[state.index + 1] == 'X'))
    {
        // Hex form.
        state.index += 2;
        const digits_start = state.index;
        while (state.index < state.source.len) : (state.index += 1) {
            const b = state.source[state.index];
            if (b == '_') continue;
            if (!isHexDigit(b)) break;
            value = value * 16 + hexValue(b);
        }
        if (state.index == digits_start) {
            try pushError(state, start, "expected hex digit after `0x`", "0x");
        }
    } else if (state.index + 1 < state.source.len and state.source[state.index] == '0' and
        (state.source[state.index + 1] == 'b' or state.source[state.index + 1] == 'B'))
    {
        // Binary form.
        state.index += 2;
        const digits_start = state.index;
        while (state.index < state.source.len) : (state.index += 1) {
            const b = state.source[state.index];
            if (b == '_') continue;
            if (!isBinDigit(b)) break;
            value = value * 2 + (b - '0');
        }
        if (state.index == digits_start) {
            try pushError(state, start, "expected binary digit after `0b`", "0b");
        }
    } else {
        // Decimal form.
        while (state.index < state.source.len) : (state.index += 1) {
            const b = state.source[state.index];
            if (b == '_') continue;
            if (!isDigit(b)) break;
            // @as: widen u8 digit → i32 to keep the multiply-add signed.
            value = value * 10 + @as(i32, b - '0');
        }
    }

    if (negative) value = -value;
    try pushToken(state, .int_lit, start, state.index, value);
}

/// Decode a single byte from inside a char or string literal,
/// stepping `state.index` past whatever bytes the escape consumes.
/// Returns the resolved byte value, or `null` on a malformed
/// escape (caller pushes the error).
fn decodeOneByte(state: *State) ?u8 {
    const b = state.source[state.index];
    if (b != '\\') {
        state.index += 1;
        return b;
    }
    // Escape sequence — at least one more byte required.
    if (state.index + 1 >= state.source.len) return null;
    const esc = state.source[state.index + 1];
    state.index += 2;
    return switch (esc) {
        'n' => 0x0A,
        't' => 0x09,
        'r' => 0x0D,
        '0' => 0x00,
        '\\' => 0x5C,
        '\'' => 0x27,
        '"' => 0x22,
        'x' => blk: {
            // `\xHH` — exactly two hex digits.
            if (state.index + 1 >= state.source.len) break :blk null;
            const h1 = state.source[state.index];
            const h2 = state.source[state.index + 1];
            if (!isHexDigit(h1) or !isHexDigit(h2)) break :blk null;
            state.index += 2;
            // @as: hexValue returns 0..15 — narrows cleanly to u8.
            const hi = @as(u8, @intCast(hexValue(h1)));
            // @as: hexValue returns 0..15 — narrows cleanly to u8.
            const lo = @as(u8, @intCast(hexValue(h2)));
            break :blk hi * 16 + lo;
        },
        else => null,
    };
}

/// Lex a `'A'` single-byte char literal. Emits as `int_lit` (the
/// byte's u8 value, widened to i32). Mirrors the asm spec's
/// `'A'` semantics so byte literals look the same across both
/// languages.
fn lexCharLit(state: *State) !void {
    const start = state.index;
    state.index += 1; // consume opening `'`
    if (state.index >= state.source.len) {
        try pushError(state, start, "unterminated char literal", "'");
        try pushToken(state, .int_lit, start, state.index, 0);
        return;
    }
    const byte_opt = decodeOneByte(state);
    if (byte_opt == null) {
        try pushError(state, start, "malformed escape in char literal", "");
        // Recover by skipping to the next `'` or newline.
        while (state.index < state.source.len and state.source[state.index] != '\'' and
            state.source[state.index] != '\n') : (state.index += 1)
        {}
        if (state.index < state.source.len and state.source[state.index] == '\'') state.index += 1;
        try pushToken(state, .int_lit, start, state.index, 0);
        return;
    }
    if (state.index >= state.source.len or state.source[state.index] != '\'') {
        try pushError(state, start, "unterminated char literal — expected closing `'`", "");
        try pushToken(state, .int_lit, start, state.index, byte_opt.?);
        return;
    }
    state.index += 1; // consume closing `'`
    // @as: widen u8 byte → i32 so it shares the int_lit value slot.
    try pushToken(state, .int_lit, start, state.index, @as(i32, byte_opt.?));
}

/// Lex a chunk of string-body bytes up to (but not including) the
/// next `$(`, `"`, or end-of-source. Always emits a `.str_part`
/// even if empty so the parser sees a uniform shape.
fn lexStringPart(state: *State) !void {
    const start = state.index;
    while (state.index < state.source.len) {
        const b = state.source[state.index];
        if (b == '"') break;
        if (b == '$' and state.index + 1 < state.source.len) {
            const next = state.source[state.index + 1];
            if (next == '(') break;
            if (next == '$') {
                // `$$` literal — consume both bytes as part of
                // the literal run.
                state.index += 2;
                continue;
            }
        }
        if (b == '\\' and state.index + 1 < state.source.len) {
            // Step past the escape byte too — semantic decoding
            // lives in the parser; the lexer just preserves the
            // byte range.
            state.index += 2;
            continue;
        }
        state.index += 1;
    }
    try pushToken(state, .str_part, start, state.index, 0);
}

/// Enter string mode at the leading `"`. Drives the body loop
/// (alternating `str_part` and `str_expr_start … str_expr_end`)
/// until the closing `"` is found or EOF.
fn lexString(state: *State) !void {
    const start = state.index;
    state.index += 1; // consume `"`
    try pushToken(state, .str_start, start, state.index, 0);
    try state.str_stack.append(state.allocator, .{ .expr_depth = 0 });
}

// ---------- driver ----------

/// Lex `source` into a `TokenStream`. Never returns an error to
/// the caller; lex-level problems accumulate in `errors` so a
/// single drive surfaces every problem at once.
pub fn tokenize(allocator: std.mem.Allocator, source: []const u8) !TokenStream {
    var state: State = .{
        .source = source,
        .index = 0,
        .tokens = .empty,
        .errors = .empty,
        .last_kind = null,
        .str_stack = .empty,
        .allocator = allocator,
    };
    defer state.str_stack.deinit(allocator);
    errdefer state.tokens.deinit(allocator);
    errdefer state.errors.deinit(allocator);

    while (state.index < source.len) {
        // --- string-body mode ---
        if (inStringBody(&state)) {
            // Always emit a `str_part` for the chunk up to the
            // next delimiter (`"` / `$(` / EOF) — even when the
            // chunk is empty. This gives the parser a uniform
            // shape: every `str_expr_start … str_expr_end` is
            // bracketed by `str_part`s on both sides.
            try lexStringPart(&state);
            if (state.index >= source.len) {
                // Unterminated literal — surface as an error,
                // close the frame so the rest of the stream
                // tokenizes sanely, and exit the loop.
                try pushError(&state, state.index, "unterminated string literal", "");
                _ = state.str_stack.pop();
                break;
            }
            const b = source[state.index];
            if (b == '"') {
                const start = state.index;
                state.index += 1;
                try pushToken(&state, .str_end, start, state.index, 0);
                _ = state.str_stack.pop();
                continue;
            }
            if (b == '$' and state.index + 1 < source.len and source[state.index + 1] == '(') {
                const start = state.index;
                state.index += 2;
                try pushToken(&state, .str_expr_start, start, state.index, 0);
                state.str_stack.items[state.str_stack.items.len - 1].expr_depth = 1;
                continue;
            }
            // Defensive — `lexStringPart` only stops at the
            // delimiters above. Reaching another byte means a
            // bug in the scan loop. Skip the byte and continue.
            state.index += 1;
            continue;
        }

        // --- normal / expr-inside-string mode ---
        const b = source[state.index];

        // Whitespace (excluding newlines).
        if (b == ' ' or b == '\t' or b == '\r') {
            state.index += 1;
            continue;
        }

        // Newlines — significant. Collapse runs into a single
        // `.newline` token to keep the parser's stream tidy.
        if (b == '\n') {
            const start = state.index;
            while (state.index < source.len and
                (source[state.index] == '\n' or source[state.index] == '\r' or
                    source[state.index] == ' ' or source[state.index] == '\t')) : (state.index += 1)
            {}
            // Suppress a leading newline (no real token before it)
            // and suppress consecutive newlines (already collapsed
            // via `last_kind == .newline`).
            if (state.last_kind != null and state.last_kind.? != .newline) {
                try pushToken(&state, .newline, start, state.index, 0);
            }
            continue;
        }

        // Comment vs `--` decrement disambiguation:
        //   - At start-of-line (or preceded by whitespace), `--`
        //     opens a line comment (Lua-style).
        //   - Directly attached to an operand-end token (e.g.
        //     `x--`), `--` is the decrement statement operator.
        // Two-byte windows only — `---` is just "comment, starts
        // with -" since once we know it's a comment we eat to EOL.
        if (b == '-' and state.index + 1 < source.len and source[state.index + 1] == '-') {
            const preceded_by_ws = state.index == 0 or blk: {
                const prev = source[state.index - 1];
                break :blk prev == ' ' or prev == '\t' or prev == '\n' or prev == '\r';
            };
            if (preceded_by_ws) {
                while (state.index < source.len and source[state.index] != '\n') : (state.index += 1) {}
                continue;
            }
            // Directly attached → decrement.
            const start = state.index;
            state.index += 2;
            try pushToken(&state, .minus_minus, start, state.index, 0);
            continue;
        }

        // Integer literal — bare digit, or `-` followed by a
        // digit at an operand position.
        if (isDigit(b)) {
            try lexInteger(&state, false);
            continue;
        }
        if (b == '-' and state.index + 1 < source.len and isDigit(source[state.index + 1])) {
            // `-` joins the literal only when the previous token
            // is "expecting an operand" (i.e. not after an
            // operand-end token). This is the JavaScript-regex
            // trick.
            const last = state.last_kind orelse Token.Kind.newline;
            if (!isOperandEnd(last)) {
                advance(&state, 1); // consume the `-`
                try lexInteger(&state, true);
                continue;
            }
        }

        // String literal.
        if (b == '"') {
            try lexString(&state);
            continue;
        }

        // Char literal — `'A'`, `'\n'`, `'\x41'`. Resolves to a
        // `u8` value packaged as `int_lit`, same as a numeric
        // literal of the same byte. Matches the asm spec.
        if (b == '\'') {
            try lexCharLit(&state);
            continue;
        }

        // Identifiers + keywords.
        if (isIdentStart(b)) {
            try lexIdent(&state);
            continue;
        }

        // Annotations.
        if (b == '@') {
            try lexAnnotation(&state);
            continue;
        }

        // Multi-char operators (longest-match first).
        if (b == '-' and state.index + 1 < source.len and source[state.index + 1] == '>') {
            const start = state.index;
            state.index += 2;
            try pushToken(&state, .arrow, start, state.index, 0);
            continue;
        }
        if (b == '.' and state.index + 1 < source.len and source[state.index + 1] == '.') {
            const start = state.index;
            state.index += 2;
            if (state.index < source.len and source[state.index] == '=') {
                state.index += 1;
                try pushToken(&state, .dot_dot_eq, start, state.index, 0);
            } else {
                try pushToken(&state, .dot_dot, start, state.index, 0);
            }
            continue;
        }
        if (b == '=' and state.index + 1 < source.len and source[state.index + 1] == '=') {
            const start = state.index;
            state.index += 2;
            try pushToken(&state, .eq_eq, start, state.index, 0);
            continue;
        }
        if (b == '!' and state.index + 1 < source.len and source[state.index + 1] == '=') {
            const start = state.index;
            state.index += 2;
            try pushToken(&state, .bang_eq, start, state.index, 0);
            continue;
        }
        if (b == '<' and state.index + 1 < source.len and source[state.index + 1] == '=') {
            const start = state.index;
            state.index += 2;
            try pushToken(&state, .lt_eq, start, state.index, 0);
            continue;
        }
        if (b == '>' and state.index + 1 < source.len and source[state.index + 1] == '=') {
            const start = state.index;
            state.index += 2;
            try pushToken(&state, .gt_eq, start, state.index, 0);
            continue;
        }
        // `<<=` / `>>=` — compound shift-assign. Longest match wins,
        // so check the 3-byte form before `<<` / `>>` / `<=` / `>=`.
        if (b == '<' and state.index + 2 < source.len and
            source[state.index + 1] == '<' and source[state.index + 2] == '=')
        {
            const start = state.index;
            state.index += 3;
            try pushToken(&state, .shl_eq, start, state.index, 0);
            continue;
        }
        if (b == '>' and state.index + 2 < source.len and
            source[state.index + 1] == '>' and source[state.index + 2] == '=')
        {
            const start = state.index;
            state.index += 3;
            try pushToken(&state, .shr_eq, start, state.index, 0);
            continue;
        }
        if (b == '<' and state.index + 1 < source.len and source[state.index + 1] == '<') {
            const start = state.index;
            state.index += 2;
            try pushToken(&state, .shl, start, state.index, 0);
            continue;
        }
        if (b == '>' and state.index + 1 < source.len and source[state.index + 1] == '>') {
            const start = state.index;
            state.index += 2;
            try pushToken(&state, .shr, start, state.index, 0);
            continue;
        }
        // Compound-assign forms `<op>=` — single-char op followed
        // by `=`. The `++` / `--` / `==` / `!=` / `<=` / `>=` /
        // `<<` / `>>` cases above already short-circuit out, so by
        // the time we reach here the `=` must be a compound-assign
        // for one of the arithmetic / bitwise ops.
        if (state.index + 1 < source.len and source[state.index + 1] == '=') {
            const ck: ?Token.Kind = switch (b) {
                '+' => .plus_eq,
                '-' => .minus_eq,
                '*' => .star_eq,
                '/' => .slash_eq,
                '%' => .percent_eq,
                '&' => .amp_eq,
                '|' => .pipe_eq,
                '^' => .caret_eq,
                else => null,
            };
            if (ck) |k| {
                const start = state.index;
                state.index += 2;
                try pushToken(&state, k, start, state.index, 0);
                continue;
            }
        }
        if (b == '+' and state.index + 1 < source.len and source[state.index + 1] == '+') {
            const start = state.index;
            state.index += 2;
            try pushToken(&state, .plus_plus, start, state.index, 0);
            continue;
        }

        // Single-char punctuation + operators.
        const start = state.index;
        const single_kind: ?Token.Kind = switch (b) {
            '(' => blk: {
                if (inExprMode(&state)) {
                    state.str_stack.items[state.str_stack.items.len - 1].expr_depth += 1;
                }
                break :blk .lparen;
            },
            ')' => blk: {
                if (inExprMode(&state)) {
                    var top = &state.str_stack.items[state.str_stack.items.len - 1];
                    top.expr_depth -= 1;
                    if (top.expr_depth == 0) {
                        // This `)` matches the interp's `$(` —
                        // emit `str_expr_end` instead of a plain
                        // `rparen` and return to string mode.
                        state.index += 1;
                        try pushToken(&state, .str_expr_end, start, state.index, 0);
                        continue;
                    }
                }
                break :blk .rparen;
            },
            '{' => .lbrace,
            '}' => .rbrace,
            '[' => .lbracket,
            ']' => .rbracket,
            ',' => .comma,
            '.' => .dot,
            ':' => .colon,
            ';' => .semicolon,
            '?' => .question,
            '!' => .bang,
            '=' => .equals,
            '+' => .plus,
            '-' => .minus,
            '*' => .star,
            '/' => .slash,
            '%' => .percent,
            '<' => .lt,
            '>' => .gt,
            '&' => .amp,
            '|' => .pipe,
            '^' => .caret,
            '~' => .tilde,
            else => null,
        };

        if (single_kind) |k| {
            state.index += 1;
            try pushToken(&state, k, start, state.index, 0);
            continue;
        }

        // Unknown byte — record and advance one.
        try pushError(&state, state.index, "unknown byte in source", source[state.index .. state.index + 1]);
        state.index += 1;
    }

    try pushToken(&state, .eof, state.index, state.index, 0);
    return .{
        .tokens = try state.tokens.toOwnedSlice(allocator),
        .errors = try state.errors.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}
