/// Compile-time expression parser + evaluator. Used by every
/// directive that wants an integer value at parse time:
///
/// - `const NAME = <expr>` — the canonical consumer (this PR)
/// - `org $ADDR` — the address is itself an expression
/// - `&[ <expr> ]` — address-expression form a
/// - `data8` / `data16` value-list entries
///
/// All four feed `parseExpression` to build an `ast.Expr` tree
/// and then `evalExpr` to fold to a `u16`. Symbol references
/// (`@sym`) are NOT supported here — they go through the symbol
/// table pass (#35). Bare identifiers refer to previously
/// defined `const`s via a `ConstantTable` the caller maintains.
const std = @import("std");
const knit = @import("knit");
const core = knit.core;
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");
const include = @import("include.zig");

// ---------- ConstantTable ----------

/// Name → u16 lookup for compile-time constants visible at this
/// point in parsing. The parser maintains one of these as it
/// walks statements top-to-bottom; each `const` declaration adds
/// an entry, subsequent expressions resolve against it.
///
/// Two kinds of keys live here:
/// - **Borrowed** — slices into the fused source (the common
///   case for top-level `const` names).
/// - **Owned** — allocated strings (used for synthetic keys like
///   `Player.hp` from struct directives). Tracked in
///   `owned_keys` so deinit can free them.
pub const ConstantTable = struct {
    entries: std.StringHashMap(u16),
    owned_keys: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    /// Build an empty table backed by `allocator`.
    pub fn init(allocator: std.mem.Allocator) ConstantTable {
        return .{
            .entries = std.StringHashMap(u16).init(allocator),
            .owned_keys = .empty,
            .allocator = allocator,
        };
    }

    /// Release the backing map and any allocator-owned keys.
    /// Borrowed keys (slices into the source) aren't freed.
    pub fn deinit(self: *ConstantTable) void {
        for (self.owned_keys.items) |k| self.allocator.free(k);
        self.owned_keys.deinit(self.allocator);
        self.entries.deinit();
    }

    /// Bind `name` to `value` with a **borrowed** key (caller
    /// guarantees the slice outlives the table). Overwrites
    /// silently — duplicate detection is the parser's job.
    pub fn put(self: *ConstantTable, name: []const u8, value: u16) !void {
        try self.entries.put(name, value);
    }

    /// Bind `name` to `value` and take ownership of the `name`
    /// buffer — it will be freed by `deinit`. Used for synthetic
    /// keys (e.g., `Player.hp`) that don't live in the source.
    pub fn putOwned(self: *ConstantTable, name: []const u8, value: u16) !void {
        try self.owned_keys.append(self.allocator, name);
        try self.entries.put(name, value);
    }

    /// Lookup; `null` if not bound.
    pub fn get(self: ConstantTable, name: []const u8) ?u16 {
        return self.entries.get(name);
    }
};

// ---------- parser (precedence climbing) ----------

/// Reasons an expression sub-parse can fail. Wraps a `core.ParseError`
/// because that's the shape the rest of the pipeline already speaks.
pub const ParseError = error{
    OutOfMemory,
    ParseFailed,
};

/// Build an expression AST starting at the current `state.index`.
/// Skips ASCII blanks/comments between tokens. Stops at the first
/// token that doesn't continue the expression (typically `newline`
/// or `,`). Caller holds onto `errors` for diagnostic accumulation.
///
/// Returns an owned `*Expr` on success, or `null` + a diagnostic
/// appended to `errors`. On error, any partial allocation is freed.
pub fn parseExpression(
    state: *core.ParseState,
    allocator: std.mem.Allocator,
    errors: *std.ArrayList(include.Diagnostic),
) ParseError!*ast.Expr {
    return parseBitOr(state, allocator, errors);
}

// Precedence ladder (lowest → highest precedence):
//   bit_or   ← bit_xor   (`|`)
//   bit_xor  ← bit_and   (`^`)
//   bit_and  ← shift     (`&`)
//   shift    ← add       (`<<`, `>>`)
//   add      ← mul       (`+`, `-`)
//   mul      ← unary     (`*`, `/`, `%`)
//   unary    ← primary   (`~`, `-`)
//   primary  = literal | ident | `(` expr `)`

fn parseBitOr(
    state: *core.ParseState,
    allocator: std.mem.Allocator,
    errors: *std.ArrayList(include.Diagnostic),
) ParseError!*ast.Expr {
    var lhs = try parseBitXor(state, allocator, errors);
    while (peekKind(state, .pipe)) {
        consume(state, .pipe);
        const rhs = parseBitXor(state, allocator, errors) catch |err| {
            ast.freeExpr(allocator, lhs);
            return err;
        };
        lhs = try buildBinary(allocator, .bit_or, lhs, rhs);
    }
    return lhs;
}

fn parseBitXor(
    state: *core.ParseState,
    allocator: std.mem.Allocator,
    errors: *std.ArrayList(include.Diagnostic),
) ParseError!*ast.Expr {
    var lhs = try parseBitAnd(state, allocator, errors);
    while (peekKind(state, .caret)) {
        consume(state, .caret);
        const rhs = parseBitAnd(state, allocator, errors) catch |err| {
            ast.freeExpr(allocator, lhs);
            return err;
        };
        lhs = try buildBinary(allocator, .bit_xor, lhs, rhs);
    }
    return lhs;
}

fn parseBitAnd(
    state: *core.ParseState,
    allocator: std.mem.Allocator,
    errors: *std.ArrayList(include.Diagnostic),
) ParseError!*ast.Expr {
    var lhs = try parseShift(state, allocator, errors);
    while (peekKind(state, .ampersand)) {
        consume(state, .ampersand);
        const rhs = parseShift(state, allocator, errors) catch |err| {
            ast.freeExpr(allocator, lhs);
            return err;
        };
        lhs = try buildBinary(allocator, .bit_and, lhs, rhs);
    }
    return lhs;
}

fn parseShift(
    state: *core.ParseState,
    allocator: std.mem.Allocator,
    errors: *std.ArrayList(include.Diagnostic),
) ParseError!*ast.Expr {
    var lhs = try parseAdd(state, allocator, errors);
    while (true) {
        const m = matchOp(state, &.{
            .{ .kind = .shl, .op = .shl },
            .{ .kind = .shr, .op = .shr },
        });
        if (m == null) break;
        consume(state, m.?.kind);
        const rhs = parseAdd(state, allocator, errors) catch |err| {
            ast.freeExpr(allocator, lhs);
            return err;
        };
        lhs = try buildBinary(allocator, m.?.op, lhs, rhs);
    }
    return lhs;
}

fn parseAdd(
    state: *core.ParseState,
    allocator: std.mem.Allocator,
    errors: *std.ArrayList(include.Diagnostic),
) ParseError!*ast.Expr {
    var lhs = try parseMul(state, allocator, errors);
    while (true) {
        const m = matchOp(state, &.{
            .{ .kind = .plus, .op = .add },
            .{ .kind = .minus, .op = .sub },
        });
        if (m == null) break;
        consume(state, m.?.kind);
        const rhs = parseMul(state, allocator, errors) catch |err| {
            ast.freeExpr(allocator, lhs);
            return err;
        };
        lhs = try buildBinary(allocator, m.?.op, lhs, rhs);
    }
    return lhs;
}

fn parseMul(
    state: *core.ParseState,
    allocator: std.mem.Allocator,
    errors: *std.ArrayList(include.Diagnostic),
) ParseError!*ast.Expr {
    var lhs = try parseUnary(state, allocator, errors);
    while (true) {
        const m = matchOp(state, &.{
            .{ .kind = .star, .op = .mul },
            .{ .kind = .slash, .op = .div },
            .{ .kind = .percent, .op = .mod },
        });
        if (m == null) break;
        consume(state, m.?.kind);
        const rhs = parseUnary(state, allocator, errors) catch |err| {
            ast.freeExpr(allocator, lhs);
            return err;
        };
        lhs = try buildBinary(allocator, m.?.op, lhs, rhs);
    }
    return lhs;
}

fn parseUnary(
    state: *core.ParseState,
    allocator: std.mem.Allocator,
    errors: *std.ArrayList(include.Diagnostic),
) ParseError!*ast.Expr {
    skipBlanks(state);
    if (peekKind(state, .tilde)) {
        const start = state.index;
        consume(state, .tilde);
        const operand = try parseUnary(state, allocator, errors);
        return buildUnary(allocator, .bit_not, operand, spanFrom(start, operand.span().end));
    }
    if (peekKind(state, .minus)) {
        const start = state.index;
        consume(state, .minus);
        const operand = try parseUnary(state, allocator, errors);
        return buildUnary(allocator, .neg, operand, spanFrom(start, operand.span().end));
    }
    return parsePrimary(state, allocator, errors);
}

fn parsePrimary(
    state: *core.ParseState,
    allocator: std.mem.Allocator,
    errors: *std.ArrayList(include.Diagnostic),
) ParseError!*ast.Expr {
    skipBlanks(state);
    const start = state.index;

    // Parenthesized sub-expression.
    if (peekByte(state, '(')) {
        state.advance(1);
        const inner = try parseExpression(state, allocator, errors);
        skipBlanks(state);
        if (!peekByte(state, ')')) {
            try errors.append(state.allocator, .{
                .parse_error = core.parseError(
                    "expression",
                    state.index,
                    "expected ')' to close grouped expression",
                    .{ .expected = ")", .kind = .syntactic },
                ),
            });
            ast.freeExpr(allocator, inner);
            return error.ParseFailed;
        }
        state.advance(1);
        const expr = try allocator.create(ast.Expr);
        expr.* = .{ .paren = .{
            .inner = inner,
            .span = spanFrom(start, state.index),
        } };
        return expr;
    }

    // Dispatch by the first non-blank byte. The lexer's leaf
    // parsers leave `state.index` unchanged on `.err`, so a
    // single attempt is enough — no double-parse needed.
    const next = if (state.index < state.input.len) state.input[state.index] else 0;

    if (next == '$') {
        const r = lexer.hexP.parseFn(state);
        if (r == .ok) {
            const tok = r.ok.value;
            const expr = try allocator.create(ast.Expr);
            expr.* = .{ .hex = .{
                .value = tok.value,
                .span = .{ .start = tok.start, .end = tok.end },
            } };
            return expr;
        }
        // The leading byte was `$` — anything past that is a
        // malformed hex literal, never "this isn't hex at all".
        // Surface the lexer's specific message + map it to an
        // E-code per asm spec §7.
        try errors.append(state.allocator, .{
            .code = include.ErrorCode.fromLexerMessage(r.err.message),
            .parse_error = r.err,
        });
        return error.ParseFailed;
    } else if (next == '\'') {
        const r = lexer.charP.parseFn(state);
        if (r == .ok) {
            const tok = r.ok.value;
            const expr = try allocator.create(ast.Expr);
            expr.* = .{ .char = .{
                .value = tok.value,
                .span = .{ .start = tok.start, .end = tok.end },
            } };
            return expr;
        }
        try errors.append(state.allocator, .{
            .code = include.ErrorCode.fromLexerMessage(r.err.message),
            .parse_error = r.err,
        });
        return error.ParseFailed;
    } else if (next == '&') {
        // `&FFFF` address literal as expression primary. The
        // wider `&[...]` form lives at the operand layer; it
        // doesn't show up inside expressions directly.
        const r = lexer.addrP.parseFn(state);
        if (r == .ok) {
            const tok = r.ok.value;
            const expr = try allocator.create(ast.Expr);
            expr.* = .{ .addr_lit = .{
                .value = tok.value,
                .span = .{ .start = tok.start, .end = tok.end },
            } };
            return expr;
        }
        try errors.append(state.allocator, .{
            .code = include.ErrorCode.fromLexerMessage(r.err.message),
            .parse_error = r.err,
        });
        return error.ParseFailed;
    } else if (next == '@') {
        const r = lexer.symRefP.parseFn(state);
        if (r == .ok) {
            const tok = r.ok.value;
            const expr = try allocator.create(ast.Expr);
            expr.* = .{ .sym_ref = .{
                .span = .{ .start = tok.start, .end = tok.end },
            } };
            return expr;
        }
    } else if (isIdentStart(next)) {
        const r = lexer.identP.parseFn(state);
        if (r == .ok) {
            const first_tok = r.ok.value;
            // Check for a dotted continuation: `Name.field` is a
            // qualified ident referring to struct-field offsets
            // (asm spec §2.2). Evaluator looks up the full
            // `Name.field` lexeme as one key in the
            // ConstantTable.
            var end_offset: u32 = first_tok.end;
            if (state.index < state.input.len and state.input[state.index] == '.') {
                state.advance(1);
                const second = lexer.identP.parseFn(state);
                if (second != .ok) {
                    try errors.append(state.allocator, .{
                        .parse_error = core.parseError(
                            "expression",
                            state.index,
                            "expected field name after `.`",
                            .{ .expected = "identifier", .kind = .syntactic },
                        ),
                    });
                    return error.ParseFailed;
                }
                end_offset = second.ok.value.end;
            }
            const expr = try allocator.create(ast.Expr);
            expr.* = .{ .ident = .{
                .span = .{ .start = first_tok.start, .end = end_offset },
            } };
            return expr;
        }
    }

    // Nothing matched — or a leaf parser refused with a more
    // structured error (e.g., "hex literal exceeds 4 digits").
    // Either way, surface the position so the user can see where
    // we got stuck.
    try errors.append(state.allocator, .{
        .parse_error = core.parseError(
            "expression",
            state.index,
            "expected a hex literal, char literal, identifier, or '('",
            .{ .expected = "primary expression", .kind = .syntactic },
        ),
    });
    return error.ParseFailed;
}

fn isIdentStart(b: u8) bool {
    return (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z') or b == '_';
}

// ---------- evaluator ----------

/// Outcome of `evalExpr` — either a folded `u16` or a diagnostic
/// describing why folding failed (unknown ident, div-by-zero, etc.).
pub const EvalResult = union(enum) {
    ok: u16,
    err: include.Diagnostic,
};

/// Fold an expression tree to a `u16` using the visible
/// `ConstantTable` for identifier references. Errors short-circuit
/// out as `EvalResult.err`; the caller decides whether to surface
/// them as `ParseTree` diagnostics or swallow.
///
/// `source` is the fused source buffer — needed so identifier
/// nodes can resolve their lexeme bytes back to a name string for
/// the table lookup.
pub fn evalExpr(expr: *const ast.Expr, source: []const u8, consts: ConstantTable) EvalResult {
    return switch (expr.*) {
        .hex => |h| .{ .ok = h.value },
        .char => |c| .{ .ok = c.value },
        .addr_lit => |a| .{ .ok = a.value },
        .sym_ref => |s| symRefLookup(s, source, consts),
        .ident => |i| identLookup(i, source, consts),
        .paren => |p| evalExpr(p.inner, source, consts),
        .unary => |u| evalUnary(u, source, consts),
        .binary => |b| evalBinary(b, source, consts),
    };
}

/// Resolve a `@sym` reference. The lexeme span includes the
/// leading `@`; we look up the name part (after the `@`) in the
/// table. Returns "unknown identifier" if not bound — the
/// codegen pass (#36) re-evaluates with a fuller symbol table.
fn symRefLookup(s: ast.SymRef, source: []const u8, consts: ConstantTable) EvalResult {
    // Strip the leading `@` byte to match how `const` and struct
    // field offsets are keyed in the table.
    const lex = source[s.span.start..s.span.end];
    const name = if (lex.len > 0 and lex[0] == '@') lex[1..] else lex;
    if (consts.get(name)) |value| return .{ .ok = value };
    return .{ .err = .{
        .code = .undefined_symbol,
        .parse_error = core.parseError(
            "expression",
            s.span.start,
            "unresolved symbol reference (symbol-table pass will retry)",
            .{ .expected = "a defined label or const", .kind = .semantic },
        ),
    } };
}

fn identLookup(i: ast.IdentRef, source: []const u8, consts: ConstantTable) EvalResult {
    const name = source[i.span.start..i.span.end];
    if (consts.get(name)) |value| return .{ .ok = value };
    return .{ .err = .{
        .code = .undefined_symbol,
        .parse_error = core.parseError(
            "expression",
            i.span.start,
            "unknown identifier in compile-time expression",
            .{ .expected = "a previously-defined `const` name", .kind = .semantic },
        ),
    } };
}

fn evalUnary(u: ast.Unary, source: []const u8, consts: ConstantTable) EvalResult {
    const inner = evalExpr(u.operand, source, consts);
    switch (inner) {
        .err => return inner,
        .ok => |v| return .{ .ok = switch (u.op) {
            .bit_not => ~v,
            .neg => 0 -% v,
        } },
    }
}

fn evalBinary(b: ast.Binary, source: []const u8, consts: ConstantTable) EvalResult {
    const lhs = evalExpr(b.lhs, source, consts);
    if (lhs == .err) return lhs;
    const rhs = evalExpr(b.rhs, source, consts);
    if (rhs == .err) return rhs;
    const l = lhs.ok;
    const r = rhs.ok;
    return switch (b.op) {
        .add => .{ .ok = l +% r },
        .sub => .{ .ok = l -% r },
        .mul => .{ .ok = l *% r },
        .div => if (r == 0) divByZero(b.span) else .{ .ok = l / r },
        .mod => if (r == 0) divByZero(b.span) else .{ .ok = l % r },
        .shl => .{ .ok = shiftLeft(l, r) },
        .shr => .{ .ok = shiftRight(l, r) },
        .bit_and => .{ .ok = l & r },
        .bit_or => .{ .ok = l | r },
        .bit_xor => .{ .ok = l ^ r },
    };
}

fn divByZero(span: ast.Span) EvalResult {
    return .{ .err = .{
        .code = .div_by_zero,
        .parse_error = core.parseError(
            "expression",
            span.start,
            "division by zero in compile-time expression",
            .{ .expected = "non-zero divisor", .kind = .semantic },
        ),
    } };
}

// ---------- helpers ----------

fn buildBinary(allocator: std.mem.Allocator, op: ast.BinaryOp, lhs: *ast.Expr, rhs: *ast.Expr) ParseError!*ast.Expr {
    const expr = try allocator.create(ast.Expr);
    expr.* = .{ .binary = .{
        .op = op,
        .lhs = lhs,
        .rhs = rhs,
        .span = ast.Span.join(lhs.span(), rhs.span()),
    } };
    return expr;
}

fn buildUnary(allocator: std.mem.Allocator, op: ast.UnaryOp, operand: *ast.Expr, span: ast.Span) ParseError!*ast.Expr {
    const expr = try allocator.create(ast.Expr);
    expr.* = .{ .unary = .{
        .op = op,
        .operand = operand,
        .span = span,
    } };
    return expr;
}

fn spanFrom(start: usize, end: usize) ast.Span {
    // safety: source offsets bounded by max_file_size (16 MiB) per include.zig.
    return .{ .start = @intCast(start), .end = @intCast(end) };
}

/// Skip ASCII whitespace. Stops at `;` so the caller's outer
/// loop can capture trailing comments as first-class `Comment`
/// statements (the parser surfaces them for the pretty-printer
/// to round-trip).
fn skipBlanks(state: *core.ParseState) void {
    while (state.index < state.input.len) {
        const b = state.input[state.index];
        if (b == ' ' or b == '\t') {
            state.advance(1);
        } else {
            break;
        }
    }
}

/// Check whether the next non-blank byte starts a token of `kind`.
/// Stateless (rewinds the state on return) so the caller can
/// commit by re-running the relevant lexer parser.
fn peekKind(state: *core.ParseState, kind: lexer.Token.Kind) bool {
    skipBlanks(state);
    const saved = state.index;
    defer state.index = saved;
    const p = parserFor(kind) orelse return false;
    return p.parseFn(state) == .ok;
}

fn parserFor(kind: lexer.Token.Kind) ?core.Parser(lexer.Token) {
    return switch (kind) {
        .pipe => lexer.pipeP,
        .caret => lexer.caretP,
        .ampersand => lexer.ampersandP,
        .shl => lexer.shlP,
        .shr => lexer.shrP,
        .plus => lexer.plusP,
        .minus => lexer.minusP,
        .star => lexer.starP,
        .slash => lexer.slashP,
        .percent => lexer.percentP,
        .tilde => lexer.tildeP,
        else => null,
    };
}

fn consume(state: *core.ParseState, kind: lexer.Token.Kind) void {
    skipBlanks(state);
    const p = parserFor(kind) orelse return;
    _ = p.parseFn(state);
}

/// Lightweight byte peek (no lexer round-trip). Used for `(` and `)`
/// which the expression grammar deals with directly.
fn peekByte(state: *core.ParseState, b: u8) bool {
    skipBlanks(state);
    return state.index < state.input.len and state.input[state.index] == b;
}

const OpMatch = struct {
    kind: lexer.Token.Kind,
    op: ast.BinaryOp,
};

/// Try the candidates in order; return the first one whose token
/// is the next thing in the stream. Doesn't consume — caller
/// calls `consume(state, m.kind)` after committing.
fn matchOp(state: *core.ParseState, candidates: []const OpMatch) ?OpMatch {
    for (candidates) |c| {
        if (peekKind(state, c.kind)) return c;
    }
    return null;
}

fn shiftLeft(l: u16, r: u16) u16 {
    if (r >= 16) return 0;
    // safety: r < 16 by the check above, so the cast to u4 is safe
    const c: u4 = @intCast(r);
    return l << c;
}

fn shiftRight(l: u16, r: u16) u16 {
    if (r >= 16) return 0;
    // safety: r < 16 by the check above, so the cast to u4 is safe
    const c: u4 = @intCast(r);
    return l >> c;
}
