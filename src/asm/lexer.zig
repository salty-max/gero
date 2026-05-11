/// `.gas` lexer. Eats whitespace / `;` comments, emits one
/// `Token` per syntactic atom, and treats newlines as
/// statement terminators (per asm spec §1). Bad bytes produce
/// `.err` tokens so the lexer recovers and keeps going — the
/// caller drains every error in a single pass.
const std = @import("std");

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
        err,
        eof,
    };

    /// Borrow the raw bytes the token spans in `source`.
    pub fn lexeme(self: Token, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

/// Output of `tokenize`. `tokens` always ends with `.eof`. The
/// caller frees both slices.
pub const TokenStream = struct {
    tokens: []Token,
    allocator: std.mem.Allocator,

    /// Release the underlying token slice.
    pub fn deinit(self: *TokenStream) void {
        self.allocator.free(self.tokens);
    }

    /// `true` if at least one `.err` token appears anywhere in
    /// the stream.
    pub fn hasErrors(self: TokenStream) bool {
        for (self.tokens) |t| if (t.kind == .err) return true;
        return false;
    }
};

/// Tokenize `source`. Always succeeds — bad input produces
/// `.err` tokens (one per offending byte) so the caller can
/// surface every problem in a single pass. The returned slice
/// always ends with an `.eof` token.
pub fn tokenize(allocator: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error!TokenStream {
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(allocator);

    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];
        switch (c) {
            ' ', '\t' => i += 1,
            ';' => {
                while (i < source.len and source[i] != '\n') i += 1;
            },
            '\n' => {
                try tokens.append(allocator, .{ .kind = .newline, .start = u32At(i), .end = u32At(i + 1), .value = 0 });
                i += 1;
            },
            '\r' => {
                if (i + 1 < source.len and source[i + 1] == '\n') {
                    try tokens.append(allocator, .{ .kind = .newline, .start = u32At(i), .end = u32At(i + 2), .value = 0 });
                    i += 2;
                } else {
                    // Bare CR is not a valid line ending per the spec.
                    try tokens.append(allocator, .{ .kind = .err, .start = u32At(i), .end = u32At(i + 1), .value = 0 });
                    i += 1;
                }
            },
            '$' => i = try eatHex(allocator, &tokens, source, i, .hex),
            '&' => i = try eatHex(allocator, &tokens, source, i, .addr),
            '!' => i = try eatSymRef(allocator, &tokens, source, i),
            ':' => i = try emitPunct(allocator, &tokens, .colon, i),
            ',' => i = try emitPunct(allocator, &tokens, .comma, i),
            '=' => i = try emitPunct(allocator, &tokens, .equals, i),
            '{' => i = try emitPunct(allocator, &tokens, .lbrace, i),
            '}' => i = try emitPunct(allocator, &tokens, .rbrace, i),
            '(' => i = try emitPunct(allocator, &tokens, .lparen, i),
            ')' => i = try emitPunct(allocator, &tokens, .rparen, i),
            '[' => i = try emitPunct(allocator, &tokens, .lbracket, i),
            ']' => i = try emitPunct(allocator, &tokens, .rbracket, i),
            '+' => i = try emitPunct(allocator, &tokens, .plus, i),
            else => {
                if (isIdentStart(c)) {
                    i = try eatIdent(allocator, &tokens, source, i);
                } else {
                    try tokens.append(allocator, .{ .kind = .err, .start = u32At(i), .end = u32At(i + 1), .value = 0 });
                    i += 1;
                }
            },
        }
    }

    try tokens.append(allocator, .{ .kind = .eof, .start = u32At(i), .end = u32At(i), .value = 0 });
    return .{ .tokens = try tokens.toOwnedSlice(allocator), .allocator = allocator };
}

fn u32At(i: usize) u32 {
    // @as: byte offsets fit in u32 — sources won't exceed 4 GiB.
    return @as(u32, @intCast(i));
}

fn emitPunct(
    allocator: std.mem.Allocator,
    tokens: *std.ArrayList(Token),
    kind: Token.Kind,
    i: usize,
) std.mem.Allocator.Error!usize {
    try tokens.append(allocator, .{ .kind = kind, .start = u32At(i), .end = u32At(i + 1), .value = 0 });
    return i + 1;
}

fn eatHex(
    allocator: std.mem.Allocator,
    tokens: *std.ArrayList(Token),
    source: []const u8,
    start: usize,
    kind: Token.Kind,
) std.mem.Allocator.Error!usize {
    var j = start + 1;
    while (j < source.len and std.ascii.isHex(source[j])) j += 1;
    const digit_count = j - start - 1;
    if (digit_count == 0 or digit_count > 4) {
        try tokens.append(allocator, .{ .kind = .err, .start = u32At(start), .end = u32At(j), .value = 0 });
        return j;
    }
    const slice = source[start + 1 .. j];
    // allow-strict: 1-4 hex digits always parse into a u16 (digit count checked)
    const parsed = std.fmt.parseInt(u16, slice, 16) catch unreachable;
    try tokens.append(allocator, .{ .kind = kind, .start = u32At(start), .end = u32At(j), .value = parsed });
    return j;
}

fn eatSymRef(
    allocator: std.mem.Allocator,
    tokens: *std.ArrayList(Token),
    source: []const u8,
    start: usize,
) std.mem.Allocator.Error!usize {
    var j = start + 1;
    if (j >= source.len or !isIdentStart(source[j])) {
        try tokens.append(allocator, .{ .kind = .err, .start = u32At(start), .end = u32At(j), .value = 0 });
        return j;
    }
    while (j < source.len and isIdentCont(source[j])) j += 1;
    try tokens.append(allocator, .{ .kind = .sym_ref, .start = u32At(start), .end = u32At(j), .value = 0 });
    return j;
}

fn eatIdent(
    allocator: std.mem.Allocator,
    tokens: *std.ArrayList(Token),
    source: []const u8,
    start: usize,
) std.mem.Allocator.Error!usize {
    var j = start;
    while (j < source.len and isIdentCont(source[j])) j += 1;
    try tokens.append(allocator, .{ .kind = .ident, .start = u32At(start), .end = u32At(j), .value = 0 });
    return j;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentCont(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}
