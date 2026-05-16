/// Gero-lang parser — consumes the `TokenStream` produced by
/// `lexer.tokenize` and emits an `ast.Program`. Token-stream-based
/// (not knit byte-combinators — those operate on raw bytes; the
/// lang side runs the lexer first then walks tokens).
///
/// Architecture:
///
/// - Statement-level dispatch is hand-rolled — a switch on the
///   current token's kind plus a handful of look-ahead checks.
/// - Expression parsing is Pratt-style: `parseExpression(min_prec)`
///   loops, eating binary operators whose precedence is at least
///   `min_prec`, recursing for the RHS at one tier higher. Unary
///   prefix, function-call postfix, field/index postfix all live in
///   the leaf path. Precedence table sourced from
///   `docs/gero-lang.md` §3.3.
/// - Errors append to `errors` but never abort parsing — the parser
///   skips to the next statement boundary (a `.newline` token) and
///   resumes. A single drive surfaces every problem at once.
///
/// Annotation attachment: the parser keeps a pending-annotation
/// buffer. When it parses `@name(args)`, it pushes to the buffer.
/// When it parses a decl that accepts annotations (`def`, `let`,
/// `const`, `class`, `struct`, `enum`, class-level field/method),
/// it drains the buffer into the decl's `annotations` slice.
/// Annotations followed by non-decl statements are reported as a
/// diagnostic and discarded.
const std = @import("std");
const knit = @import("knit");
const core = knit.core;
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");

const Kind = lexer.Token.Kind;

/// Output of `parse` — the program AST plus diagnostics. Errors
/// don't abort parsing; the parser recovers to the next statement
/// boundary so a single run drains every problem at once.
pub const ParseTree = struct {
    program: ast.Program,
    errors: []core.ParseError,
    allocator: std.mem.Allocator,

    /// Release the owned statement list and the diagnostics buffer.
    pub fn deinit(self: *ParseTree) void {
        self.program.deinit();
        self.allocator.free(self.errors);
    }

    /// `true` when at least one diagnostic was recorded.
    pub fn hasErrors(self: ParseTree) bool {
        return self.errors.len > 0;
    }
};

/// Parse a tokenized source into an `ast.Program` + diagnostics.
/// Only error path is OOM. Grammar errors land in `errors`.
pub fn parse(
    allocator: std.mem.Allocator,
    source: []const u8,
    stream: lexer.TokenStream,
) !ParseTree {
    var statements: std.ArrayList(ast.Statement) = .empty;
    errdefer cleanupStatements(allocator, &statements);

    var errors: std.ArrayList(core.ParseError) = .empty;
    errdefer errors.deinit(allocator);

    // Propagate lexer-level diagnostics so callers see a unified
    // error stream (mirrors how `asm.parse` surfaces include-pass
    // diagnostics).
    for (stream.errors) |err| try errors.append(allocator, err);

    var pending_annotations: std.ArrayList(ast.Annotation) = .empty;
    // The buffer holds duped Annotation entries between encountering
    // `@…` and attaching them to a decl. On the success path the
    // entries are drained (`takePendingAnnotations`), but the
    // ArrayList's backing capacity still needs releasing — hence the
    // unconditional `defer` rather than relying on `errdefer`.
    defer pending_annotations.deinit(allocator);
    errdefer for (pending_annotations.items) |a| {
        for (a.args) |arg| ast.freeExpr(allocator, arg);
        allocator.free(a.args);
    };

    var p: Parser = .{
        .source = source,
        .tokens = stream.tokens,
        .pos = 0,
        .allocator = allocator,
        .errors = &errors,
        .pending_annotations = &pending_annotations,
    };

    p.skipNewlines();
    while (!p.atEnd()) {
        try parseTopLevel(&p, &statements);
        p.skipNewlines();
    }

    // Any unattached pending annotations at EOF — emit one diagnostic
    // and free their inner allocations. The buffer itself (capacity)
    // is released by the `defer pending_annotations.deinit` above.
    if (pending_annotations.items.len > 0) {
        try errors.append(allocator, core.parseError(
            "lang_parser",
            pending_annotations.items[0].span.start,
            "annotation at EOF has no following declaration to attach to",
            .{ .expected = "declaration after annotation", .kind = .semantic },
        ));
        for (pending_annotations.items) |a| {
            for (a.args) |arg| ast.freeExpr(allocator, arg);
            allocator.free(a.args);
        }
        pending_annotations.clearRetainingCapacity();
    }

    return .{
        .program = .{
            .statements = try statements.toOwnedSlice(allocator),
            .allocator = allocator,
        },
        .errors = try errors.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Cleanup partial state when an OOM path triggers `errdefer`.
fn cleanupStatements(
    allocator: std.mem.Allocator,
    statements: *std.ArrayList(ast.Statement),
) void {
    for (statements.items) |*s| ast.freeStatement(allocator, s);
    statements.deinit(allocator);
}

fn cleanupAnnotations(
    allocator: std.mem.Allocator,
    anns: *std.ArrayList(ast.Annotation),
) void {
    for (anns.items) |a| {
        for (a.args) |arg| ast.freeExpr(allocator, arg);
        allocator.free(a.args);
    }
    anns.deinit(allocator);
}

// =====================================================================
// Parser state + cursor helpers.
// =====================================================================

const Parser = struct {
    source: []const u8,
    tokens: []const lexer.Token,
    pos: usize,
    allocator: std.mem.Allocator,
    errors: *std.ArrayList(core.ParseError),
    pending_annotations: *std.ArrayList(ast.Annotation),

    /// Current token. Always defined — the lexer guarantees a
    /// trailing `.eof` token.
    fn peek(self: *const Parser) lexer.Token {
        return self.tokens[self.pos];
    }

    /// Token `n` positions ahead. Safe past EOF: returns the EOF
    /// token (the lexer guarantees one trailing).
    fn peekAt(self: *const Parser, n: usize) lexer.Token {
        const idx = @min(self.pos + n, self.tokens.len - 1);
        return self.tokens[idx];
    }

    fn atEnd(self: *const Parser) bool {
        return self.peek().kind == .eof;
    }

    /// True when the current token matches `kind`.
    fn check(self: *const Parser, kind: Kind) bool {
        return self.peek().kind == kind;
    }

    /// Same as `check` but for a span of allowed kinds.
    fn checkAny(self: *const Parser, kinds: []const Kind) bool {
        const k = self.peek().kind;
        for (kinds) |c| if (k == c) return true;
        return false;
    }

    /// Consume the current token if it matches `kind`. Returns the
    /// consumed token on hit, `null` on miss.
    fn accept(self: *Parser, kind: Kind) ?lexer.Token {
        if (!self.check(kind)) return null;
        const t = self.peek();
        self.pos += 1;
        return t;
    }

    /// Skip newline tokens; they don't carry semantics outside the
    /// statement-boundary role.
    fn skipNewlines(self: *Parser) void {
        while (self.check(.newline)) self.pos += 1;
    }

    /// Skip newlines, return whether we consumed at least one or
    /// reached EOF. Used after a statement is parsed to assert the
    /// caller didn't trail garbage before the next statement.
    fn requireStatementBoundary(self: *Parser) !void {
        if (self.atEnd() or self.check(.newline)) {
            self.skipNewlines();
            return;
        }
        try self.recordError(
            "expected newline or end-of-input after statement",
            "newline",
        );
        try self.recoverToNewline();
    }

    fn currentSpan(self: *const Parser) ast.Span {
        const t = self.peek();
        return .{ .start = t.start, .end = t.end };
    }

    /// Append a diagnostic anchored at the current token. The lexeme
    /// of the actual token is recorded as `actual` so consumers see
    /// what the parser tripped on.
    fn recordError(
        self: *Parser,
        message: []const u8,
        expected: []const u8,
    ) !void {
        const t = self.peek();
        try self.errors.append(self.allocator, core.parseError(
            "lang_parser",
            t.start,
            message,
            .{
                .expected = expected,
                .actual = self.source[t.start..t.end],
                .kind = .syntactic,
            },
        ));
    }

    /// Append a diagnostic at the given token index without
    /// consuming.
    fn recordErrorAt(
        self: *Parser,
        index: u32,
        message: []const u8,
        expected: []const u8,
    ) !void {
        try self.errors.append(self.allocator, core.parseError(
            "lang_parser",
            index,
            message,
            .{ .expected = expected, .kind = .syntactic },
        ));
    }

    /// Advance until the next newline (or EOF). Used for
    /// statement-level error recovery.
    fn recoverToNewline(self: *Parser) !void {
        while (!self.atEnd() and !self.check(.newline)) self.pos += 1;
        self.skipNewlines();
    }

    /// Expect a specific token kind; emit a diagnostic and bail out
    /// of the current production via `error.ParseFailed` if missing.
    /// Successful match returns the consumed token.
    fn expect(self: *Parser, kind: Kind, what: []const u8) ParserError!lexer.Token {
        if (self.accept(kind)) |t| return t;
        try self.recordError("expected token", what);
        return error.ParseFailed;
    }

    /// Allocate and initialize an `*Expr`.
    fn allocExpr(self: *Parser, value: ast.Expr) !*ast.Expr {
        const node = try self.allocator.create(ast.Expr);
        node.* = value;
        return node;
    }

    fn allocPattern(self: *Parser, value: ast.Pattern) !*ast.Pattern {
        const node = try self.allocator.create(ast.Pattern);
        node.* = value;
        return node;
    }

    fn allocTypeAnn(self: *Parser, value: ast.TypeAnn) !*ast.TypeAnn {
        const node = try self.allocator.create(ast.TypeAnn);
        node.* = value;
        return node;
    }

    fn lexeme(self: *const Parser, span: ast.Span) []const u8 {
        return self.source[span.start..span.end];
    }
};

/// Local error set for productions that may bail to the nearest
/// statement-recovery point. `OutOfMemory` propagates to the caller;
/// `ParseFailed` triggers `recoverToNewline` at the statement level.
const ParserError = error{ OutOfMemory, ParseFailed };

// =====================================================================
// Top-level dispatch.
// =====================================================================

fn parseTopLevel(
    p: *Parser,
    statements: *std.ArrayList(ast.Statement),
) !void {
    // Accumulate annotations into the parser's pending buffer.
    while (p.check(.annotation)) {
        const ann = parseAnnotation(p) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseFailed => {
                try p.recoverToNewline();
                return;
            },
        };
        try p.pending_annotations.append(p.allocator, ann);
        p.skipNewlines();
    }

    parseStatement(p, statements) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseFailed => try p.recoverToNewline(),
    };
}

fn parseStatement(
    p: *Parser,
    statements: *std.ArrayList(ast.Statement),
) ParserError!void {
    const start = p.peek().start;
    const k = p.peek().kind;

    switch (k) {
        .kw_let => {
            const stmt = try parseLetDecl(p, false);
            try statements.append(p.allocator, stmt);
        },
        .kw_const => {
            const stmt = try parseConstDecl(p, false);
            try statements.append(p.allocator, stmt);
        },
        .kw_def => {
            const stmt = try parseDefDecl(p, false);
            try statements.append(p.allocator, stmt);
        },
        .kw_class => {
            const stmt = try parseClassDecl(p, false);
            try statements.append(p.allocator, stmt);
        },
        .kw_enum => {
            const stmt = try parseEnumDecl(p, false);
            try statements.append(p.allocator, stmt);
        },
        .kw_local => {
            try parseLocalDecl(p, statements);
        },
        .kw_use => {
            const stmt = try parseUseDecl(p, false);
            try statements.append(p.allocator, stmt);
        },
        .ident => {
            // `struct Foo ... end` uses a bare identifier — `struct`
            // is not a reserved keyword in the lexer so type-name
            // lookups like `let Stats = ...` stay unambiguous. Look
            // ahead for the dispatch shape.
            const lex = p.source[p.peek().start..p.peek().end];
            if (std.mem.eql(u8, lex, "struct")) {
                const stmt = try parseStructDecl(p, false);
                try statements.append(p.allocator, stmt);
                return;
            }
            // Otherwise fall through to expression-or-assignment.
            try parseExprOrAssignStatement(p, statements);
        },
        .kw_if => {
            const stmt = try parseIfStatement(p);
            try statements.append(p.allocator, stmt);
        },
        .kw_while => {
            const stmt = try parseWhileStatement(p);
            try statements.append(p.allocator, stmt);
        },
        .kw_for => {
            const stmt = try parseForStatement(p);
            try statements.append(p.allocator, stmt);
        },
        .kw_match => {
            const stmt = try parseMatchStatement(p);
            try statements.append(p.allocator, stmt);
        },
        .kw_do => {
            const stmt = try parseBlockStatement(p);
            try statements.append(p.allocator, stmt);
        },
        .kw_return => {
            const stmt = try parseReturnStatement(p);
            try statements.append(p.allocator, stmt);
        },
        .kw_break => {
            const t = p.peek();
            p.pos += 1;
            try statements.append(p.allocator, .{ .break_stmt = .{
                .span = .{ .start = t.start, .end = t.end },
            } });
            try p.requireStatementBoundary();
        },
        .kw_continue => {
            const t = p.peek();
            p.pos += 1;
            try statements.append(p.allocator, .{ .continue_stmt = .{
                .span = .{ .start = t.start, .end = t.end },
            } });
            try p.requireStatementBoundary();
        },
        .kw_print => {
            const stmt = try parsePrintStatement(p);
            try statements.append(p.allocator, stmt);
        },
        .eof => return,
        else => {
            // `_ = expr` discard — `_` is a bare identifier in the
            // lexer; the `kw_let`-style match above doesn't catch
            // it. `.ident` branch handles the general case too;
            // this fallthrough handles anything else that can
            // start an expression (literals, parens, etc.).
            try parseExprOrAssignStatement(p, statements);
        },
    }

    _ = start;
}

/// `local <decl>` — visibility shim. The keyword must be followed
/// by a `let` / `const` / `def` / `class` / `struct` / `enum` /
/// `use` decl. The parser sets the inner decl's `is_local` field.
fn parseLocalDecl(
    p: *Parser,
    statements: *std.ArrayList(ast.Statement),
) !void {
    const local_tok = p.peek();
    p.pos += 1; // consume `local`
    const start = local_tok.start;

    const k = p.peek().kind;
    switch (k) {
        .kw_let => {
            const stmt = try parseLetDecl(p, true);
            try statements.append(p.allocator, stmt);
        },
        .kw_const => {
            const stmt = try parseConstDecl(p, true);
            try statements.append(p.allocator, stmt);
        },
        .kw_def => {
            const stmt = try parseDefDecl(p, true);
            try statements.append(p.allocator, stmt);
        },
        .kw_class => {
            const stmt = try parseClassDecl(p, true);
            try statements.append(p.allocator, stmt);
        },
        .kw_enum => {
            const stmt = try parseEnumDecl(p, true);
            try statements.append(p.allocator, stmt);
        },
        .kw_use => {
            const stmt = try parseUseDecl(p, true);
            try statements.append(p.allocator, stmt);
        },
        .ident => {
            const lex = p.source[p.peek().start..p.peek().end];
            if (std.mem.eql(u8, lex, "struct")) {
                const stmt = try parseStructDecl(p, true);
                try statements.append(p.allocator, stmt);
                return;
            }
            try p.recordError(
                "expected declaration after `local`",
                "let / const / def / class / struct / enum / use",
            );
            try p.recoverToNewline();
            try statements.append(p.allocator, .{ .local_decl = .{
                .span = .{ .start = start, .end = p.peek().start },
            } });
        },
        else => {
            try p.recordError(
                "expected declaration after `local`",
                "let / const / def / class / struct / enum / use",
            );
            try p.recoverToNewline();
            try statements.append(p.allocator, .{ .local_decl = .{
                .span = .{ .start = start, .end = p.peek().start },
            } });
        },
    }
}

// =====================================================================
// Annotations.
// =====================================================================

/// Parse `@name` or `@name(args...)`. The leading `@` is a single
/// `.annotation` token covering both the `@` and the trailing
/// identifier (see `lexer.zig`).
fn parseAnnotation(p: *Parser) ParserError!ast.Annotation {
    const at_tok = p.peek();
    p.pos += 1;

    // The lexer emits `.annotation` as a single token whose span
    // covers `@name` end-to-end. The leading `@` is one byte.
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

    // `(arg, arg, ...)` is optional. `@bank N` is the rare arg-
    // without-parens form spec §3.7.1 documents — accept a single
    // following expression of "literal-or-ident" shape on the same
    // line as a sugar.
    if (p.accept(.lparen)) |_| {
        if (!p.check(.rparen)) {
            while (true) {
                const arg = try parseExpression(p, 0);
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
        const arg = try parseExpression(p, 0);
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

/// Drain pending annotations into a fresh owned slice. The buffer
/// is reset so subsequent decls don't inherit stale entries.
fn takePendingAnnotations(p: *Parser) ![]ast.Annotation {
    const slice = try p.allocator.dupe(ast.Annotation, p.pending_annotations.items);
    p.pending_annotations.clearRetainingCapacity();
    return slice;
}

// =====================================================================
// `let` / `const` declarations.
// =====================================================================

fn parseLetDecl(p: *Parser, is_local: bool) ParserError!ast.Statement {
    const let_tok = p.peek();
    p.pos += 1; // consume `let`

    const start = let_tok.start;

    // The bound shape can be a single ident OR a destructuring
    // pattern. The pattern parser handles both uniformly.
    const pattern = try parsePattern(p);

    var type_ann: ?*ast.TypeAnn = null;
    if (p.accept(.colon)) |_| {
        type_ann = try parseTypeAnn(p);
    }

    var init: ?*ast.Expr = null;
    if (p.accept(.equals)) |_| {
        init = try parseExpression(p, 0);
    } else if (type_ann == null) {
        // `let x` with no type and no init is invalid.
        try p.recordError(
            "expected `=` or `: T` after `let` binding",
            "= or : T",
        );
    }

    const end = if (init) |e| e.span().end else if (type_ann) |t| t.span().end else pattern.span().end;
    try p.requireStatementBoundary();
    return .{ .let_decl = .{
        .pattern = pattern,
        .type_ann = type_ann,
        .init = init,
        .is_local = is_local,
        .span = .{ .start = start, .end = end },
    } };
}

fn parseConstDecl(p: *Parser, is_local: bool) ParserError!ast.Statement {
    const const_tok = p.peek();
    p.pos += 1;
    const start = const_tok.start;

    const name_tok = try p.expect(.ident, "identifier");
    const name_span = ast.Span.fromToken(name_tok);

    var type_ann: ?*ast.TypeAnn = null;
    if (p.accept(.colon)) |_| {
        type_ann = try parseTypeAnn(p);
    }

    _ = try p.expect(.equals, "=");

    const init = try parseExpression(p, 0);
    const end = init.span().end;
    try p.requireStatementBoundary();

    return .{ .const_decl = .{
        .name = name_span,
        .type_ann = type_ann,
        .init = init,
        .is_local = is_local,
        .span = .{ .start = start, .end = end },
    } };
}

// =====================================================================
// `def` — function declaration.
// =====================================================================

fn parseDefDecl(p: *Parser, is_local: bool) ParserError!ast.Statement {
    const decl = try parseDefDeclInner(p, is_local);
    return .{ .def_decl = decl };
}

fn parseDefDeclInner(p: *Parser, is_local: bool) ParserError!ast.DefDecl {
    const def_tok = p.peek();
    p.pos += 1; // consume `def`
    const start = def_tok.start;

    const annotations = try takePendingAnnotations(p);
    errdefer freeAnnSlice(p.allocator, annotations);

    const name_tok = try p.expect(.ident, "function name");
    const name_span = ast.Span.fromToken(name_tok);

    _ = try p.expect(.lparen, "(");
    const params = try parseParamList(p);
    errdefer freeParams(p.allocator, params);

    var ret_type: ?*ast.TypeAnn = null;
    if (p.accept(.arrow)) |_| {
        ret_type = try parseTypeAnn(p);
    }
    errdefer if (ret_type) |r| ast.freeTypeAnn(p.allocator, r);

    p.skipNewlines();
    var body: std.ArrayList(ast.Statement) = .empty;
    errdefer cleanupStatements(p.allocator, &body);

    while (!p.atEnd() and !p.check(.kw_end)) {
        try parseStatement(p, &body);
        p.skipNewlines();
    }

    const end_tok = try p.expect(.kw_end, "end");
    try p.requireStatementBoundary();

    return .{
        .annotations = annotations,
        .name = name_span,
        .params = params,
        .ret_type = ret_type,
        .body = try body.toOwnedSlice(p.allocator),
        .is_local = is_local,
        .span = .{ .start = start, .end = end_tok.end },
    };
}

fn freeAnnSlice(allocator: std.mem.Allocator, anns: []ast.Annotation) void {
    for (anns) |a| {
        for (a.args) |arg| ast.freeExpr(allocator, arg);
        allocator.free(a.args);
    }
    allocator.free(anns);
}

fn freeParams(allocator: std.mem.Allocator, params: []ast.Param) void {
    for (params) |p| if (p.type_ann) |t| ast.freeTypeAnn(allocator, t);
    allocator.free(params);
}

fn parseParamList(p: *Parser) ParserError![]ast.Param {
    var params: std.ArrayList(ast.Param) = .empty;
    errdefer {
        freeParams(p.allocator, params.items);
        params.deinit(p.allocator);
    }

    if (p.check(.rparen)) {
        _ = p.accept(.rparen);
        return try params.toOwnedSlice(p.allocator);
    }

    while (true) {
        // `self` is a parameter shape too — it gets a `kw_self`
        // token, not an ident, but the parser treats it as a named
        // param so methods can be written `def m(self, ...)`.
        const tok = p.peek();
        const name_span: ast.Span = switch (tok.kind) {
            .ident, .kw_self => blk: {
                p.pos += 1;
                break :blk .{ .start = tok.start, .end = tok.end };
            },
            else => {
                try p.recordError("expected parameter name", "identifier");
                return error.ParseFailed;
            },
        };

        var type_ann: ?*ast.TypeAnn = null;
        if (p.accept(.colon)) |_| {
            type_ann = try parseTypeAnn(p);
        }

        const param_end: u32 = if (type_ann) |t| t.span().end else name_span.end;
        try params.append(p.allocator, .{
            .name = name_span,
            .type_ann = type_ann,
            .span = .{ .start = name_span.start, .end = param_end },
        });

        if (p.accept(.comma) == null) break;
    }

    _ = try p.expect(.rparen, ")");
    return try params.toOwnedSlice(p.allocator);
}

// =====================================================================
// `class` declaration.
// =====================================================================

fn parseClassDecl(p: *Parser, is_local: bool) ParserError!ast.Statement {
    const class_tok = p.peek();
    p.pos += 1;
    const start = class_tok.start;

    const annotations = try takePendingAnnotations(p);
    errdefer freeAnnSlice(p.allocator, annotations);

    const name_tok = try p.expect(.ident, "class name");
    const name_span = ast.Span.fromToken(name_tok);

    var extends: ?ast.Span = null;
    if (p.accept(.kw_extends)) |_| {
        const parent_tok = try p.expect(.ident, "parent class name");
        extends = ast.Span.fromToken(parent_tok);
    }

    // Body delimiter: spec §6 examples use `{ ... }` for class body.
    _ = try p.expect(.lbrace, "{");
    p.skipNewlines();

    var fields: std.ArrayList(ast.ClassField) = .empty;
    errdefer cleanupClassFields(p.allocator, &fields);
    var methods: std.ArrayList(ast.DefDecl) = .empty;
    errdefer cleanupMethods(p.allocator, &methods);

    while (!p.atEnd() and !p.check(.rbrace)) {
        // Accumulate annotations inside the class body, same as
        // file-level. They attach to the next field or method.
        while (p.check(.annotation)) {
            const ann = try parseAnnotation(p);
            try p.pending_annotations.append(p.allocator, ann);
            p.skipNewlines();
        }

        switch (p.peek().kind) {
            .kw_let => {
                const field = try parseClassField(p);
                try fields.append(p.allocator, field);
            },
            .kw_def => {
                const m = try parseDefDeclInner(p, false);
                try methods.append(p.allocator, m);
            },
            .rbrace => break,
            else => {
                try p.recordError(
                    "expected field (`let`) or method (`def`) in class body",
                    "let or def",
                );
                try p.recoverToNewline();
            },
        }
        p.skipNewlines();
    }

    const close_tok = try p.expect(.rbrace, "}");
    try p.requireStatementBoundary();

    return .{ .class_decl = .{
        .annotations = annotations,
        .name = name_span,
        .extends = extends,
        .fields = try fields.toOwnedSlice(p.allocator),
        .methods = try methods.toOwnedSlice(p.allocator),
        .is_local = is_local,
        .span = .{ .start = start, .end = close_tok.end },
    } };
}

fn parseClassField(p: *Parser) ParserError!ast.ClassField {
    // `let name: T [= init]` — annotations were accumulated before
    // entering here.
    const let_tok = p.peek();
    p.pos += 1;

    const annotations = try takePendingAnnotations(p);
    errdefer freeAnnSlice(p.allocator, annotations);

    const name_tok = try p.expect(.ident, "field name");
    const name_span = ast.Span.fromToken(name_tok);

    var type_ann: ?*ast.TypeAnn = null;
    if (p.accept(.colon)) |_| {
        type_ann = try parseTypeAnn(p);
    }

    var init: ?*ast.Expr = null;
    var end_idx: u32 = if (type_ann) |t| t.span().end else name_span.end;
    if (p.accept(.equals)) |_| {
        const e = try parseExpression(p, 0);
        end_idx = e.span().end;
        init = e;
    }

    try p.requireStatementBoundary();
    return .{
        .annotations = annotations,
        .name = name_span,
        .type_ann = type_ann,
        .init = init,
        .span = .{ .start = let_tok.start, .end = end_idx },
    };
}

fn cleanupClassFields(
    allocator: std.mem.Allocator,
    fields: *std.ArrayList(ast.ClassField),
) void {
    for (fields.items) |f| {
        freeAnnSlice(allocator, f.annotations);
        if (f.type_ann) |t| ast.freeTypeAnn(allocator, t);
        if (f.init) |e| ast.freeExpr(allocator, e);
    }
    fields.deinit(allocator);
}

fn cleanupMethods(
    allocator: std.mem.Allocator,
    methods: *std.ArrayList(ast.DefDecl),
) void {
    for (methods.items) |m| {
        freeAnnSlice(allocator, m.annotations);
        freeParams(allocator, m.params);
        if (m.ret_type) |r| ast.freeTypeAnn(allocator, r);
        for (m.body) |*s| ast.freeStatement(allocator, s);
        allocator.free(m.body);
    }
    methods.deinit(allocator);
}

// =====================================================================
// `struct` declaration.
// =====================================================================

fn parseStructDecl(p: *Parser, is_local: bool) ParserError!ast.Statement {
    const struct_tok = p.peek();
    p.pos += 1; // consume `struct` (it's an ident token, not a kw)
    const start = struct_tok.start;

    const annotations = try takePendingAnnotations(p);
    errdefer freeAnnSlice(p.allocator, annotations);

    const name_tok = try p.expect(.ident, "struct name");
    const name_span = ast.Span.fromToken(name_tok);

    p.skipNewlines();

    var fields: std.ArrayList(ast.StructField) = .empty;
    errdefer {
        for (fields.items) |f| ast.freeTypeAnn(p.allocator, f.type_ann);
        fields.deinit(p.allocator);
    }

    while (!p.atEnd() and !p.check(.kw_end)) {
        const fname_tok = try p.expect(.ident, "field name");
        _ = try p.expect(.colon, ":");
        const ftype = try parseTypeAnn(p);
        const fend = ftype.span().end;
        try fields.append(p.allocator, .{
            .name = ast.Span.fromToken(fname_tok),
            .type_ann = ftype,
            .span = .{ .start = fname_tok.start, .end = fend },
        });
        // Comma between fields is optional (matches spec examples).
        _ = p.accept(.comma);
        p.skipNewlines();
    }

    const end_tok = try p.expect(.kw_end, "end");
    try p.requireStatementBoundary();

    return .{ .struct_decl = .{
        .annotations = annotations,
        .name = name_span,
        .fields = try fields.toOwnedSlice(p.allocator),
        .is_local = is_local,
        .span = .{ .start = start, .end = end_tok.end },
    } };
}

// =====================================================================
// `enum` declaration.
// =====================================================================

fn parseEnumDecl(p: *Parser, is_local: bool) ParserError!ast.Statement {
    const enum_tok = p.peek();
    p.pos += 1;
    const start = enum_tok.start;

    const annotations = try takePendingAnnotations(p);
    errdefer freeAnnSlice(p.allocator, annotations);

    const name_tok = try p.expect(.ident, "enum name");
    const name_span = ast.Span.fromToken(name_tok);

    p.skipNewlines();

    var variants: std.ArrayList(ast.EnumVariant) = .empty;
    errdefer cleanupEnumVariants(p.allocator, &variants);

    while (!p.atEnd() and !p.check(.kw_end)) {
        _ = try p.expect(.kw_case, "case");
        const v_name_tok = try p.expect(.ident, "variant name");
        const v_name_span = ast.Span.fromToken(v_name_tok);

        var payload: std.ArrayList(ast.EnumPayloadField) = .empty;
        errdefer {
            for (payload.items) |pf| ast.freeTypeAnn(p.allocator, pf.type_ann);
            payload.deinit(p.allocator);
        }

        var v_end: u32 = v_name_tok.end;
        if (p.accept(.lparen)) |_| {
            if (!p.check(.rparen)) {
                while (true) {
                    // Two shapes:
                    //   - `name: type` — named payload field
                    //   - `type`       — anonymous (zero-width name span)
                    const tok0 = p.peek();
                    const tok1 = p.peekAt(1);
                    if (tok0.kind == .ident and tok1.kind == .colon) {
                        const fname_tok = p.peek();
                        p.pos += 2; // consume name + colon
                        const ftype = try parseTypeAnn(p);
                        try payload.append(p.allocator, .{
                            .name = ast.Span.fromToken(fname_tok),
                            .type_ann = ftype,
                            .span = .{ .start = fname_tok.start, .end = ftype.span().end },
                        });
                    } else {
                        const ftype = try parseTypeAnn(p);
                        const ts = ftype.span();
                        try payload.append(p.allocator, .{
                            .name = .{ .start = ts.start, .end = ts.start },
                            .type_ann = ftype,
                            .span = ts,
                        });
                    }
                    if (p.accept(.comma) == null) break;
                }
            }
            const close = try p.expect(.rparen, ")");
            v_end = close.end;
        }

        try variants.append(p.allocator, .{
            .name = v_name_span,
            .payload = try payload.toOwnedSlice(p.allocator),
            .span = .{ .start = v_name_span.start, .end = v_end },
        });

        p.skipNewlines();
    }

    const end_tok = try p.expect(.kw_end, "end");
    try p.requireStatementBoundary();

    return .{ .enum_decl = .{
        .annotations = annotations,
        .name = name_span,
        .variants = try variants.toOwnedSlice(p.allocator),
        .is_local = is_local,
        .span = .{ .start = start, .end = end_tok.end },
    } };
}

fn cleanupEnumVariants(
    allocator: std.mem.Allocator,
    variants: *std.ArrayList(ast.EnumVariant),
) void {
    for (variants.items) |v| {
        for (v.payload) |pf| ast.freeTypeAnn(allocator, pf.type_ann);
        allocator.free(v.payload);
    }
    variants.deinit(allocator);
}

// =====================================================================
// `use` declaration.
// =====================================================================

fn parseUseDecl(p: *Parser, is_local: bool) ParserError!ast.Statement {
    const use_tok = p.peek();
    p.pos += 1;
    const start = use_tok.start;

    // Forms (spec §5.2):
    //   use math
    //   use "./physics"
    //   use abs from math
    //   use abs as absolute from math
    //   use abs, sqrt from math
    //   use math as m
    var items: std.ArrayList(ast.UseItem) = .empty;
    errdefer items.deinit(p.allocator);

    var module_span: ast.Span = undefined;
    var quoted_path = false;
    var alias: ?ast.Span = null;

    // Snapshot for restart: distinguish `use math` from `use abs from math`.
    // We peek the first identifier; if `from` follows (after possibly more
    // identifiers), parse the selective shape; else parse the whole-module
    // form.
    const start_pos = p.pos;
    if (try lookaheadHasFromClause(p)) {
        // Selective: `use name [as alias] (, name [as alias])* from module`
        while (true) {
            const n_tok = try p.expect(.ident, "import name");
            var item_alias: ?ast.Span = null;
            var item_end = n_tok.end;
            if (p.accept(.kw_as)) |_| {
                const a_tok = try p.expect(.ident, "alias");
                item_alias = ast.Span.fromToken(a_tok);
                item_end = a_tok.end;
            }
            try items.append(p.allocator, .{
                .name = ast.Span.fromToken(n_tok),
                .alias = item_alias,
                .span = .{ .start = n_tok.start, .end = item_end },
            });
            if (p.accept(.comma) == null) break;
        }
        _ = try p.expect(.kw_from, "from");
        module_span = try parseUseModuleSpec(p, &quoted_path);
    } else {
        // Whole-module: `use module [as alias]`.
        p.pos = start_pos;
        module_span = try parseUseModuleSpec(p, &quoted_path);
        if (p.accept(.kw_as)) |_| {
            const a_tok = try p.expect(.ident, "alias");
            alias = ast.Span.fromToken(a_tok);
        }
    }

    const end: u32 = if (alias) |a| a.end else module_span.end;
    try p.requireStatementBoundary();

    return .{ .use_decl = .{
        .module = module_span,
        .quoted_path = quoted_path,
        .items = try items.toOwnedSlice(p.allocator),
        .alias = alias,
        .is_local = is_local,
        .span = .{ .start = start, .end = end },
    } };
}

/// Module spec is either a bare ident or a quoted-path string literal.
fn parseUseModuleSpec(p: *Parser, quoted: *bool) ParserError!ast.Span {
    if (p.check(.str_start)) {
        return try parseQuotedPath(p, quoted);
    }
    quoted.* = false;
    const tok = try p.expect(.ident, "module name");
    return ast.Span.fromToken(tok);
}

fn parseQuotedPath(p: *Parser, quoted: *bool) ParserError!ast.Span {
    quoted.* = true;
    const start_tok = try p.expect(.str_start, "\"");
    // Eat the body parts until str_end.
    var end_idx: u32 = start_tok.end;
    while (true) {
        const t = p.peek();
        switch (t.kind) {
            .str_part => {
                p.pos += 1;
                end_idx = t.end;
            },
            .str_end => {
                p.pos += 1;
                end_idx = t.end;
                break;
            },
            .str_expr_start => {
                // Interpolation inside an import path isn't useful;
                // record + recover.
                try p.recordError(
                    "string interpolation not allowed in `use` path",
                    "literal path",
                );
                return error.ParseFailed;
            },
            else => return error.ParseFailed,
        }
    }
    return .{ .start = start_tok.start, .end = end_idx };
}

fn lookaheadHasFromClause(p: *Parser) ParserError!bool {
    // Save position; walk through `ident [as ident] (, ident [as ident])*`
    // and check whether the next token after that prefix is `kw_from`.
    var i = p.pos;
    if (i >= p.tokens.len) return false;
    if (p.tokens[i].kind != .ident) return false;
    while (true) {
        if (i >= p.tokens.len or p.tokens[i].kind != .ident) return false;
        i += 1;
        if (i < p.tokens.len and p.tokens[i].kind == .kw_as) {
            i += 1;
            if (i >= p.tokens.len or p.tokens[i].kind != .ident) return false;
            i += 1;
        }
        if (i < p.tokens.len and p.tokens[i].kind == .comma) {
            i += 1;
            continue;
        }
        break;
    }
    return i < p.tokens.len and p.tokens[i].kind == .kw_from;
}

// =====================================================================
// Control flow.
// =====================================================================

fn parseIfStatement(p: *Parser) ParserError!ast.Statement {
    const start_tok = p.peek();
    const result = try parseIfChain(p);
    try p.requireStatementBoundary();
    return .{ .if_stmt = .{
        .arms = result.arms,
        .else_body = result.else_body,
        .span = .{ .start = start_tok.start, .end = result.end },
    } };
}

const IfChain = struct {
    arms: []ast.IfArm,
    else_body: ?[]ast.Statement,
    end: u32,
};

fn parseIfChain(p: *Parser) ParserError!IfChain {
    _ = try p.expect(.kw_if, "if");

    var arms: std.ArrayList(ast.IfArm) = .empty;
    errdefer cleanupIfArms(p.allocator, &arms);
    var else_body: ?[]ast.Statement = null;
    errdefer if (else_body) |b| {
        for (b) |*s| ast.freeStatement(p.allocator, s);
        p.allocator.free(b);
    };

    try parseIfArm(p, &arms);
    var end: u32 = 0;

    while (true) {
        if (p.accept(.kw_elif)) |_| {
            try parseIfArm(p, &arms);
            continue;
        }
        if (p.accept(.kw_else)) |else_tok| {
            // `else if cond then ...` flattens into another arm; the
            // spec lists both `elif` and `else if` (§4.4).
            if (p.check(.kw_if)) {
                p.pos += 1;
                try parseIfArm(p, &arms);
                continue;
            }
            // Plain `else` body.
            p.skipNewlines();
            var body: std.ArrayList(ast.Statement) = .empty;
            errdefer cleanupStatements(p.allocator, &body);
            while (!p.atEnd() and !p.check(.kw_end)) {
                try parseStatement(p, &body);
                p.skipNewlines();
            }
            else_body = try body.toOwnedSlice(p.allocator);
            _ = else_tok;
            break;
        }
        break;
    }

    const end_tok = try p.expect(.kw_end, "end");
    end = end_tok.end;
    return .{
        .arms = try arms.toOwnedSlice(p.allocator),
        .else_body = else_body,
        .end = end,
    };
}

fn parseIfArm(
    p: *Parser,
    arms: *std.ArrayList(ast.IfArm),
) ParserError!void {
    const arm_start = p.peek().start;

    var cond: ?*ast.Expr = null;
    var let_pattern: ?*ast.Pattern = null;
    var let_expr: ?*ast.Expr = null;
    var let_guard: ?*ast.Expr = null;
    errdefer if (cond) |c| ast.freeExpr(p.allocator, c);
    errdefer if (let_pattern) |pp| ast.freePattern(p.allocator, pp);
    errdefer if (let_expr) |e| ast.freeExpr(p.allocator, e);
    errdefer if (let_guard) |g| ast.freeExpr(p.allocator, g);

    // `if let pat = expr [when guard] then ...` — §4.4.1.
    if (p.accept(.kw_let)) |_| {
        let_pattern = try parsePattern(p);
        _ = try p.expect(.equals, "=");
        let_expr = try parseExpression(p, 0);
        if (p.accept(.kw_when)) |_| {
            let_guard = try parseExpression(p, 0);
        }
    } else {
        cond = try parseExpression(p, 0);
    }
    _ = try p.expect(.kw_then, "then");
    p.skipNewlines();

    var body: std.ArrayList(ast.Statement) = .empty;
    errdefer cleanupStatements(p.allocator, &body);

    while (!p.atEnd() and !p.check(.kw_end) and !p.check(.kw_else) and !p.check(.kw_elif)) {
        try parseStatement(p, &body);
        p.skipNewlines();
    }
    const arm_end = p.peek().start;
    try arms.append(p.allocator, .{
        .cond = cond,
        .let_pattern = let_pattern,
        .let_expr = let_expr,
        .let_guard = let_guard,
        .body = try body.toOwnedSlice(p.allocator),
        .span = .{ .start = arm_start, .end = arm_end },
    });
}

fn cleanupIfArms(
    allocator: std.mem.Allocator,
    arms: *std.ArrayList(ast.IfArm),
) void {
    for (arms.items) |arm| {
        if (arm.cond) |c| ast.freeExpr(allocator, c);
        if (arm.let_pattern) |pp| ast.freePattern(allocator, pp);
        if (arm.let_expr) |e| ast.freeExpr(allocator, e);
        if (arm.let_guard) |g| ast.freeExpr(allocator, g);
        for (arm.body) |*s| ast.freeStatement(allocator, s);
        allocator.free(arm.body);
    }
    arms.deinit(allocator);
}

fn parseWhileStatement(p: *Parser) ParserError!ast.Statement {
    const while_tok = p.peek();
    p.pos += 1;
    const start = while_tok.start;

    var cond: ?*ast.Expr = null;
    var let_pattern: ?*ast.Pattern = null;
    var let_expr: ?*ast.Expr = null;
    var let_guard: ?*ast.Expr = null;

    // `while let pat = expr [when guard] do ... end`
    if (p.accept(.kw_let)) |_| {
        let_pattern = try parsePattern(p);
        _ = try p.expect(.equals, "=");
        let_expr = try parseExpression(p, 0);
        if (p.accept(.kw_when)) |_| {
            let_guard = try parseExpression(p, 0);
        }
    } else {
        cond = try parseExpression(p, 0);
    }

    _ = try p.expect(.kw_do, "do");
    p.skipNewlines();

    var body: std.ArrayList(ast.Statement) = .empty;
    errdefer cleanupStatements(p.allocator, &body);
    while (!p.atEnd() and !p.check(.kw_end)) {
        try parseStatement(p, &body);
        p.skipNewlines();
    }
    const end_tok = try p.expect(.kw_end, "end");
    try p.requireStatementBoundary();

    return .{ .while_stmt = .{
        .cond = cond,
        .let_pattern = let_pattern,
        .let_expr = let_expr,
        .let_guard = let_guard,
        .body = try body.toOwnedSlice(p.allocator),
        .span = .{ .start = start, .end = end_tok.end },
    } };
}

fn parseForStatement(p: *Parser) ParserError!ast.Statement {
    const for_tok = p.peek();
    p.pos += 1;
    const start = for_tok.start;

    const binding_tok = try p.expect(.ident, "loop variable name");
    _ = try p.expect(.kw_in, "in");

    const iter = try parseExpression(p, 0);
    errdefer ast.freeExpr(p.allocator, iter);

    var step: ?*ast.Expr = null;
    if (p.accept(.kw_step)) |_| {
        step = try parseExpression(p, 0);
    }
    errdefer if (step) |s| ast.freeExpr(p.allocator, s);

    _ = try p.expect(.kw_do, "do");
    p.skipNewlines();

    var body: std.ArrayList(ast.Statement) = .empty;
    errdefer cleanupStatements(p.allocator, &body);
    while (!p.atEnd() and !p.check(.kw_end)) {
        try parseStatement(p, &body);
        p.skipNewlines();
    }
    const end_tok = try p.expect(.kw_end, "end");
    try p.requireStatementBoundary();

    return .{ .for_stmt = .{
        .binding = ast.Span.fromToken(binding_tok),
        .iter = iter,
        .step = step,
        .body = try body.toOwnedSlice(p.allocator),
        .span = .{ .start = start, .end = end_tok.end },
    } };
}

fn parseMatchStatement(p: *Parser) ParserError!ast.Statement {
    const match_tok = p.peek();
    p.pos += 1;
    const start = match_tok.start;

    const scrutinee = try parseExpression(p, 0);
    errdefer ast.freeExpr(p.allocator, scrutinee);
    p.skipNewlines();

    var arms: std.ArrayList(ast.MatchArm) = .empty;
    errdefer cleanupMatchArms(p.allocator, &arms);

    while (p.accept(.kw_case)) |case_tok| {
        const arm_start = case_tok.start;
        const pattern = try parsePattern(p);
        errdefer ast.freePattern(p.allocator, pattern);

        var guard: ?*ast.Expr = null;
        if (p.accept(.kw_when)) |_| {
            guard = try parseExpression(p, 0);
        }
        errdefer if (guard) |g| ast.freeExpr(p.allocator, g);

        _ = try p.expect(.kw_then, "then");
        p.skipNewlines();

        var body: std.ArrayList(ast.Statement) = .empty;
        errdefer cleanupStatements(p.allocator, &body);
        while (!p.atEnd() and !p.check(.kw_case) and !p.check(.kw_end)) {
            try parseStatement(p, &body);
            p.skipNewlines();
        }
        const arm_end = p.peek().start;
        try arms.append(p.allocator, .{
            .pattern = pattern,
            .guard = guard,
            .body = try body.toOwnedSlice(p.allocator),
            .span = .{ .start = arm_start, .end = arm_end },
        });
    }
    const end_tok = try p.expect(.kw_end, "end");
    try p.requireStatementBoundary();

    return .{ .match_stmt = .{
        .scrutinee = scrutinee,
        .arms = try arms.toOwnedSlice(p.allocator),
        .span = .{ .start = start, .end = end_tok.end },
    } };
}

fn cleanupMatchArms(
    allocator: std.mem.Allocator,
    arms: *std.ArrayList(ast.MatchArm),
) void {
    for (arms.items) |arm| {
        ast.freePattern(allocator, arm.pattern);
        if (arm.guard) |g| ast.freeExpr(allocator, g);
        for (arm.body) |*s| ast.freeStatement(allocator, s);
        allocator.free(arm.body);
    }
    arms.deinit(allocator);
}

fn parseBlockStatement(p: *Parser) ParserError!ast.Statement {
    const do_tok = p.peek();
    p.pos += 1;
    const start = do_tok.start;
    p.skipNewlines();

    var body: std.ArrayList(ast.Statement) = .empty;
    errdefer cleanupStatements(p.allocator, &body);
    while (!p.atEnd() and !p.check(.kw_end)) {
        try parseStatement(p, &body);
        p.skipNewlines();
    }
    const end_tok = try p.expect(.kw_end, "end");
    try p.requireStatementBoundary();

    return .{ .block = .{
        .body = try body.toOwnedSlice(p.allocator),
        .span = .{ .start = start, .end = end_tok.end },
    } };
}

fn parseReturnStatement(p: *Parser) ParserError!ast.Statement {
    const ret_tok = p.peek();
    p.pos += 1;
    const start = ret_tok.start;

    var value: ?*ast.Expr = null;
    var end: u32 = ret_tok.end;
    if (!p.check(.newline) and !p.atEnd() and !p.check(.kw_end)) {
        const v = try parseExpression(p, 0);
        end = v.span().end;
        value = v;
    }
    try p.requireStatementBoundary();

    return .{ .return_stmt = .{
        .value = value,
        .span = .{ .start = start, .end = end },
    } };
}

fn parsePrintStatement(p: *Parser) ParserError!ast.Statement {
    const print_tok = p.peek();
    p.pos += 1;
    const start = print_tok.start;

    var args: std.ArrayList(*ast.Expr) = .empty;
    errdefer {
        for (args.items) |a| ast.freeExpr(p.allocator, a);
        args.deinit(p.allocator);
    }

    // `print` with no following expression on the same line is
    // valid (prints just the newline). The lexer significant
    // newlines make this unambiguous.
    if (!p.check(.newline) and !p.atEnd()) {
        while (true) {
            const a = try parseExpression(p, 0);
            try args.append(p.allocator, a);
            if (p.accept(.comma) == null) break;
        }
    }
    const end: u32 = if (args.items.len > 0) args.items[args.items.len - 1].span().end else print_tok.end;
    try p.requireStatementBoundary();

    return .{ .print_stmt = .{
        .args = try args.toOwnedSlice(p.allocator),
        .span = .{ .start = start, .end = end },
    } };
}

// =====================================================================
// Expression-or-assignment statement.
//
// In statement position, an expression can be:
//   - bare expression (function call, etc.)
//   - assignment: `target = expr` / `target += expr` / ...
//   - increment / decrement: `target++` / `target--`
//   - discard: `_ = expr`
// =====================================================================

fn parseExprOrAssignStatement(
    p: *Parser,
    statements: *std.ArrayList(ast.Statement),
) ParserError!void {
    const start = p.peek().start;
    const first = try parseExpression(p, 0);
    errdefer ast.freeExpr(p.allocator, first);

    // Compound-assign / plain-assign / inc-dec / discard / bare expr
    // are all distinguished by the next token.
    if (matchAssignOp(p.peek().kind)) |op| {
        p.pos += 1;
        // Discard form: `_ = expr` — desugars to `.discard`.
        if (op == .set and isUnderscore(p, first)) {
            const value = try parseExpression(p, 0);
            ast.freeExpr(p.allocator, first);
            try p.requireStatementBoundary();
            try statements.append(p.allocator, .{ .discard = .{
                .expr = value,
                .span = .{ .start = start, .end = value.span().end },
            } });
            return;
        }
        const value = try parseExpression(p, 0);
        try p.requireStatementBoundary();
        try statements.append(p.allocator, .{ .assign = .{
            .target = first,
            .op = op,
            .value = value,
            .span = .{ .start = start, .end = value.span().end },
        } });
        return;
    }

    if (p.accept(.plus_plus)) |t| {
        try p.requireStatementBoundary();
        try statements.append(p.allocator, .{ .inc_dec = .{
            .target = first,
            .inc = true,
            .span = .{ .start = start, .end = t.end },
        } });
        return;
    }
    if (p.accept(.minus_minus)) |t| {
        try p.requireStatementBoundary();
        try statements.append(p.allocator, .{ .inc_dec = .{
            .target = first,
            .inc = false,
            .span = .{ .start = start, .end = t.end },
        } });
        return;
    }

    try p.requireStatementBoundary();
    try statements.append(p.allocator, .{ .expr_stmt = .{
        .expr = first,
        .span = .{ .start = start, .end = first.span().end },
    } });
}

fn isUnderscore(p: *const Parser, e: *const ast.Expr) bool {
    return switch (e.*) {
        .ident => |i| std.mem.eql(u8, p.source[i.span.start..i.span.end], "_"),
        else => false,
    };
}

fn matchAssignOp(k: Kind) ?ast.AssignOp {
    return switch (k) {
        .equals => .set,
        .plus_eq => .add_set,
        .minus_eq => .sub_set,
        .star_eq => .mul_set,
        .slash_eq => .div_set,
        .percent_eq => .mod_set,
        .amp_eq => .bit_and_set,
        .pipe_eq => .bit_or_set,
        .caret_eq => .bit_xor_set,
        .shl_eq => .shl_set,
        .shr_eq => .shr_set,
        else => null,
    };
}

// =====================================================================
// Type-annotation parser.
// =====================================================================

fn parseTypeAnn(p: *Parser) ParserError!*ast.TypeAnn {
    var base = try parseTypeBase(p);
    errdefer ast.freeTypeAnn(p.allocator, base);

    // Postfix `?` — nullable suffix. Loops so `T??` would parse,
    // though that's unusual; typechecker can flag.
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
            // `fn` type — the spec spells `fn(args) -> ret`. `fn` is
            // not a keyword in the lexer; it arrives as a bare
            // ident. The `.ident` branch above handles it through
            // the regular path (since it has a `(` after `fn`, that
            // looks like a generic application — handle here).
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
    const len_expr = try parseExpression(p, 0);
    errdefer ast.freeExpr(p.allocator, len_expr);

    const rb_tok = try p.expect(.rbracket, "]");
    return try p.allocTypeAnn(.{ .array = .{
        .elem = elem,
        .len_expr = len_expr,
        .span = .{ .start = lb_tok.start, .end = rb_tok.end },
    } });
}

/// `(T)` → just T; `(T1, T2, ...)` → tuple.
fn parseTupleOrParenType(p: *Parser) ParserError!*ast.TypeAnn {
    const lp_tok = p.peek();
    p.pos += 1;
    const first = try parseTypeAnn(p);
    errdefer ast.freeTypeAnn(p.allocator, first);

    if (p.accept(.rparen)) |rp| {
        // Single-element grouping isn't reflected in the AST (no
        // `paren` wrapper for types) — return the inner directly,
        // span-extended to cover the parens.
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

    // Tuple shape.
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

    // Plain named type — accumulate `.qualified.path` segments via
    // dot tokens. The AST captures the joined source span; the
    // typechecker re-tokenizes against the lexeme.
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

// =====================================================================
// Pattern parser.
// =====================================================================

fn parsePattern(p: *Parser) ParserError!*ast.Pattern {
    var first = try parseAtomicPattern(p);
    errdefer ast.freePattern(p.allocator, first);

    // Or-pattern: `A | B | C`.
    if (!p.check(.pipe)) return first;

    var alts: std.ArrayList(*ast.Pattern) = .empty;
    errdefer {
        for (alts.items) |a| ast.freePattern(p.allocator, a);
        alts.deinit(p.allocator);
    }
    try alts.append(p.allocator, first);
    var end_span = first.span();

    while (p.accept(.pipe)) |_| {
        const next = try parseAtomicPattern(p);
        end_span = next.span();
        try alts.append(p.allocator, next);
    }
    const start = alts.items[0].span().start;
    return try p.allocPattern(.{ .or_pattern = .{
        .alts = try alts.toOwnedSlice(p.allocator),
        .span = .{ .start = start, .end = end_span.end },
    } });
}

fn parseAtomicPattern(p: *Parser) ParserError!*ast.Pattern {
    const tok = p.peek();
    switch (tok.kind) {
        .int_lit => {
            p.pos += 1;
            // Range pattern: `lo .. hi` or `lo ..= hi`.
            if (p.check(.dot_dot) or p.check(.dot_dot_eq)) {
                return try parseRangePatternFrom(p, intLitExpr(tok), tok.start);
            }
            return try p.allocPattern(.{ .int_lit = .{
                .value = tok.value,
                .span = .{ .start = tok.start, .end = tok.end },
            } });
        },
        .kw_true => {
            p.pos += 1;
            return try p.allocPattern(.{ .bool_lit = .{
                .value = true,
                .span = .{ .start = tok.start, .end = tok.end },
            } });
        },
        .kw_false => {
            p.pos += 1;
            return try p.allocPattern(.{ .bool_lit = .{
                .value = false,
                .span = .{ .start = tok.start, .end = tok.end },
            } });
        },
        .kw_nil => {
            p.pos += 1;
            return try p.allocPattern(.{ .nil_lit = .{
                .span = .{ .start = tok.start, .end = tok.end },
            } });
        },
        .str_start => {
            return try parseStringLitPattern(p);
        },
        .ident => {
            // Wildcard `_`, plain binding, struct pattern, or enum-variant pattern.
            const lex = p.source[tok.start..tok.end];
            if (std.mem.eql(u8, lex, "_")) {
                p.pos += 1;
                return try p.allocPattern(.{ .wildcard = .{
                    .span = .{ .start = tok.start, .end = tok.end },
                } });
            }

            // Lookahead: `Ident { ... }` → struct pattern.
            //            `Ident.Ident(...)` / `Ident.Ident` → variant pattern.
            //            else → plain identifier binding.
            const next = p.peekAt(1).kind;
            if (next == .lbrace) {
                return try parseStructPattern(p);
            }
            if (next == .dot) {
                return try parseVariantPattern(p);
            }
            p.pos += 1;
            return try p.allocPattern(.{ .ident = .{
                .name = .{ .start = tok.start, .end = tok.end },
                .span = .{ .start = tok.start, .end = tok.end },
            } });
        },
        .lparen => {
            return try parseTuplePattern(p);
        },
        else => {
            try p.recordError("expected pattern", "pattern");
            return error.ParseFailed;
        },
    }
}

fn intLitExpr(t: lexer.Token) ast.Expr {
    return .{ .int_lit = .{
        .value = t.value,
        .span = .{ .start = t.start, .end = t.end },
    } };
}

fn parseRangePatternFrom(
    p: *Parser,
    lo_expr_val: ast.Expr,
    start: u32,
) ParserError!*ast.Pattern {
    const inclusive = p.check(.dot_dot_eq);
    p.pos += 1; // consume `..` or `..=`

    const lo = try p.allocExpr(lo_expr_val);
    errdefer ast.freeExpr(p.allocator, lo);

    const hi = try parseExpression(p, 0);

    return try p.allocPattern(.{ .range_pattern = .{
        .start = lo,
        .end = hi,
        .inclusive = inclusive,
        .span = .{ .start = start, .end = hi.span().end },
    } });
}

fn parseStringLitPattern(p: *Parser) ParserError!*ast.Pattern {
    // The lexer emits str_start | str_part | str_end for an
    // un-interpolated literal. Patterns reject interpolation —
    // they're literals only.
    const start_tok = try p.expect(.str_start, "\"");
    var end_idx: u32 = start_tok.end;
    while (true) {
        const t = p.peek();
        switch (t.kind) {
            .str_part => {
                p.pos += 1;
                end_idx = t.end;
            },
            .str_end => {
                p.pos += 1;
                end_idx = t.end;
                break;
            },
            .str_expr_start => {
                try p.recordError(
                    "interpolation not allowed in pattern position",
                    "literal string",
                );
                return error.ParseFailed;
            },
            else => return error.ParseFailed,
        }
    }
    return try p.allocPattern(.{ .str_lit = .{
        .span = .{ .start = start_tok.start, .end = end_idx },
    } });
}

fn parseStructPattern(p: *Parser) ParserError!*ast.Pattern {
    const name_tok = p.peek();
    p.pos += 1;
    _ = try p.expect(.lbrace, "{");

    var fields: std.ArrayList(ast.StructPatternField) = .empty;
    errdefer {
        for (fields.items) |f| ast.freePattern(p.allocator, f.sub);
        fields.deinit(p.allocator);
    }

    if (!p.check(.rbrace)) {
        while (true) {
            const fname_tok = try p.expect(.ident, "field name");
            const fname_span = ast.Span.fromToken(fname_tok);
            var sub: *ast.Pattern = undefined;
            if (p.accept(.colon)) |_| {
                sub = try parsePattern(p);
            } else {
                // Shorthand: `Foo { hp, mp }` → `hp: hp, mp: mp`.
                sub = try p.allocPattern(.{ .ident = .{
                    .name = fname_span,
                    .span = fname_span,
                } });
            }
            try fields.append(p.allocator, .{
                .name = fname_span,
                .sub = sub,
                .span = .{ .start = fname_span.start, .end = sub.span().end },
            });
            if (p.accept(.comma) == null) break;
        }
    }
    const rb = try p.expect(.rbrace, "}");
    return try p.allocPattern(.{ .struct_pattern = .{
        .type_name = ast.Span.fromToken(name_tok),
        .fields = try fields.toOwnedSlice(p.allocator),
        .span = .{ .start = name_tok.start, .end = rb.end },
    } });
}

fn parseVariantPattern(p: *Parser) ParserError!*ast.Pattern {
    const head_tok = p.peek();
    p.pos += 1;
    _ = try p.expect(.dot, ".");
    const variant_tok = try p.expect(.ident, "variant name");
    var end_idx: u32 = variant_tok.end;

    var args: std.ArrayList(*ast.Pattern) = .empty;
    errdefer {
        for (args.items) |a| ast.freePattern(p.allocator, a);
        args.deinit(p.allocator);
    }

    if (p.accept(.lparen)) |_| {
        if (!p.check(.rparen)) {
            while (true) {
                const a = try parsePattern(p);
                try args.append(p.allocator, a);
                if (p.accept(.comma) == null) break;
            }
        }
        const rp = try p.expect(.rparen, ")");
        end_idx = rp.end;
    }
    return try p.allocPattern(.{ .variant_pattern = .{
        .path = .{ .start = head_tok.start, .end = variant_tok.end },
        .args = try args.toOwnedSlice(p.allocator),
        .span = .{ .start = head_tok.start, .end = end_idx },
    } });
}

fn parseTuplePattern(p: *Parser) ParserError!*ast.Pattern {
    const lp = p.peek();
    p.pos += 1;
    var elems: std.ArrayList(*ast.Pattern) = .empty;
    errdefer {
        for (elems.items) |e| ast.freePattern(p.allocator, e);
        elems.deinit(p.allocator);
    }

    if (!p.check(.rparen)) {
        while (true) {
            const e = try parsePattern(p);
            try elems.append(p.allocator, e);
            if (p.accept(.comma) == null) break;
        }
    }
    const rp = try p.expect(.rparen, ")");
    return try p.allocPattern(.{ .tuple_pattern = .{
        .elems = try elems.toOwnedSlice(p.allocator),
        .span = .{ .start = lp.start, .end = rp.end },
    } });
}

// =====================================================================
// Expression parser — Pratt precedence per §3.3.
// =====================================================================

/// Precedence levels — higher binds tighter. Used by the Pratt loop
/// to encode the `docs/gero-lang.md` §3.3 hierarchy. Values are
/// reserved to allow inserting new levels between existing ones
/// without renumbering call sites.
const Prec = struct {
    /// Initial level passed by callers that want the full expression.
    pub const lowest: u8 = 0;
    /// `..` / `..=` — produce range values; bind loosest.
    pub const range: u8 = 1;
    /// `or` — logical OR, short-circuits.
    pub const log_or: u8 = 2;
    /// `and` — logical AND, short-circuits.
    pub const log_and: u8 = 3;
    /// `==` / `!=` / `<` / `<=` / `>` / `>=`.
    pub const compare: u8 = 4;
    /// `|` — bitwise OR.
    pub const bit_or: u8 = 5;
    /// `^` — bitwise XOR.
    pub const bit_xor: u8 = 6;
    /// `&` — bitwise AND.
    pub const bit_and: u8 = 7;
    /// `<<` / `>>` — bit shifts.
    pub const shift: u8 = 8;
    /// `+` / `-` — additive arithmetic.
    pub const add: u8 = 9;
    /// `*` / `/` / `%` — multiplicative arithmetic.
    pub const mul: u8 = 10;
    /// `is` — variant-tag test. Binds tighter than arithmetic.
    pub const is_test: u8 = 11;
    /// Unary prefix: `-x` / `not x` / `~x`.
    pub const unary: u8 = 12;
    /// Postfix: call `( )`, index `[ ]`, field `.`.
    pub const call: u8 = 13;
};

fn parseExpression(p: *Parser, min_prec: u8) ParserError!*ast.Expr {
    var lhs = try parseUnary(p);
    errdefer ast.freeExpr(p.allocator, lhs);

    while (true) {
        const k = p.peek().kind;

        // Range operator — bind tightest at the lowest level so
        // `0..10 + 1` parses as `0 .. (10 + 1)`. §3.3 lists range
        // below assignment.
        if (k == .dot_dot or k == .dot_dot_eq) {
            const prec = Prec.range;
            if (prec < min_prec) break;
            const inclusive = k == .dot_dot_eq;
            p.pos += 1;
            const rhs = try parseExpression(p, prec + 1);
            const new_node = try p.allocExpr(.{ .range = .{
                .start = lhs,
                .end = rhs,
                .inclusive = inclusive,
                .span = .{ .start = lhs.span().start, .end = rhs.span().end },
            } });
            lhs = new_node;
            continue;
        }

        // `is` — variant-tag test (§3.6). Right side is a qualified
        // variant path like `Item.Sword`.
        if (k == .kw_is) {
            const prec = Prec.is_test;
            if (prec < min_prec) break;
            p.pos += 1;
            const head_tok = try p.expect(.ident, "enum name");
            _ = try p.expect(.dot, ".");
            const var_tok = try p.expect(.ident, "variant name");
            const path: ast.Span = .{ .start = head_tok.start, .end = var_tok.end };
            const new_node = try p.allocExpr(.{ .is_test = .{
                .lhs = lhs,
                .variant_path = path,
                .span = .{ .start = lhs.span().start, .end = var_tok.end },
            } });
            lhs = new_node;
            continue;
        }

        // Generic binary operators driven by a precedence table.
        if (binaryOpOf(k)) |info| {
            if (info.prec < min_prec) break;
            p.pos += 1;
            const rhs = try parseExpression(p, info.prec + 1);
            const new_node = try p.allocExpr(.{ .binary = .{
                .op = info.op,
                .lhs = lhs,
                .rhs = rhs,
                .span = .{ .start = lhs.span().start, .end = rhs.span().end },
            } });
            lhs = new_node;
            continue;
        }

        break;
    }
    return lhs;
}

const BinaryInfo = struct {
    op: ast.BinaryOp,
    prec: u8,
};

fn binaryOpOf(k: Kind) ?BinaryInfo {
    return switch (k) {
        .kw_or => .{ .op = .log_or, .prec = Prec.log_or },
        .kw_and => .{ .op = .log_and, .prec = Prec.log_and },
        .eq_eq => .{ .op = .eq, .prec = Prec.compare },
        .bang_eq => .{ .op = .neq, .prec = Prec.compare },
        .lt => .{ .op = .lt, .prec = Prec.compare },
        .lt_eq => .{ .op = .lte, .prec = Prec.compare },
        .gt => .{ .op = .gt, .prec = Prec.compare },
        .gt_eq => .{ .op = .gte, .prec = Prec.compare },
        .pipe => .{ .op = .bit_or, .prec = Prec.bit_or },
        .caret => .{ .op = .bit_xor, .prec = Prec.bit_xor },
        .amp => .{ .op = .bit_and, .prec = Prec.bit_and },
        .shl => .{ .op = .shl, .prec = Prec.shift },
        .shr => .{ .op = .shr, .prec = Prec.shift },
        .plus => .{ .op = .add, .prec = Prec.add },
        .minus => .{ .op = .sub, .prec = Prec.add },
        .star => .{ .op = .mul, .prec = Prec.mul },
        .slash => .{ .op = .div, .prec = Prec.mul },
        .percent => .{ .op = .mod, .prec = Prec.mul },
        else => null,
    };
}

fn parseUnary(p: *Parser) ParserError!*ast.Expr {
    const tok = p.peek();
    switch (tok.kind) {
        .minus => {
            p.pos += 1;
            const operand = try parseUnary(p);
            return try p.allocExpr(.{ .unary = .{
                .op = .neg,
                .operand = operand,
                .span = .{ .start = tok.start, .end = operand.span().end },
            } });
        },
        .kw_not => {
            p.pos += 1;
            const operand = try parseUnary(p);
            return try p.allocExpr(.{ .unary = .{
                .op = .log_not,
                .operand = operand,
                .span = .{ .start = tok.start, .end = operand.span().end },
            } });
        },
        .tilde => {
            p.pos += 1;
            const operand = try parseUnary(p);
            return try p.allocExpr(.{ .unary = .{
                .op = .bit_not,
                .operand = operand,
                .span = .{ .start = tok.start, .end = operand.span().end },
            } });
        },
        else => return try parseCallChain(p),
    }
}

fn parseCallChain(p: *Parser) ParserError!*ast.Expr {
    var e = try parsePrimary(p);
    errdefer ast.freeExpr(p.allocator, e);

    while (true) {
        const k = p.peek().kind;
        switch (k) {
            .lparen => {
                e = try parseCallArgs(p, e);
            },
            .lbracket => {
                e = try parseIndexAccess(p, e);
            },
            .dot => {
                e = try parseFieldOrMethod(p, e);
            },
            else => break,
        }
    }
    return e;
}

fn parseCallArgs(p: *Parser, callee: *ast.Expr) ParserError!*ast.Expr {
    p.pos += 1; // consume `(`
    var args: std.ArrayList(*ast.Expr) = .empty;
    errdefer {
        for (args.items) |a| ast.freeExpr(p.allocator, a);
        args.deinit(p.allocator);
    }
    if (!p.check(.rparen)) {
        while (true) {
            const a = try parseExpression(p, 0);
            try args.append(p.allocator, a);
            if (p.accept(.comma) == null) break;
        }
    }
    const rp = try p.expect(.rparen, ")");
    return try p.allocExpr(.{ .call = .{
        .callee = callee,
        .args = try args.toOwnedSlice(p.allocator),
        .span = .{ .start = callee.span().start, .end = rp.end },
    } });
}

fn parseIndexAccess(p: *Parser, receiver: *ast.Expr) ParserError!*ast.Expr {
    p.pos += 1; // consume `[`
    const idx = try parseExpression(p, 0);
    const rb = try p.expect(.rbracket, "]");
    return try p.allocExpr(.{ .index = .{
        .receiver = receiver,
        .index = idx,
        .span = .{ .start = receiver.span().start, .end = rb.end },
    } });
}

fn parseFieldOrMethod(p: *Parser, receiver: *ast.Expr) ParserError!*ast.Expr {
    p.pos += 1; // consume `.`
    const name_tok = try p.expect(.ident, "field or method name");
    if (p.check(.lparen)) {
        p.pos += 1;
        var args: std.ArrayList(*ast.Expr) = .empty;
        errdefer {
            for (args.items) |a| ast.freeExpr(p.allocator, a);
            args.deinit(p.allocator);
        }
        if (!p.check(.rparen)) {
            while (true) {
                const a = try parseExpression(p, 0);
                try args.append(p.allocator, a);
                if (p.accept(.comma) == null) break;
            }
        }
        const rp = try p.expect(.rparen, ")");
        return try p.allocExpr(.{ .method_call = .{
            .receiver = receiver,
            .method = ast.Span.fromToken(name_tok),
            .args = try args.toOwnedSlice(p.allocator),
            .span = .{ .start = receiver.span().start, .end = rp.end },
        } });
    }
    return try p.allocExpr(.{ .field = .{
        .receiver = receiver,
        .field = ast.Span.fromToken(name_tok),
        .span = .{ .start = receiver.span().start, .end = name_tok.end },
    } });
}

fn parsePrimary(p: *Parser) ParserError!*ast.Expr {
    const tok = p.peek();
    switch (tok.kind) {
        .int_lit => {
            p.pos += 1;
            return try p.allocExpr(.{ .int_lit = .{
                .value = tok.value,
                .span = .{ .start = tok.start, .end = tok.end },
            } });
        },
        .kw_true => {
            p.pos += 1;
            return try p.allocExpr(.{ .bool_lit = .{
                .value = true,
                .span = .{ .start = tok.start, .end = tok.end },
            } });
        },
        .kw_false => {
            p.pos += 1;
            return try p.allocExpr(.{ .bool_lit = .{
                .value = false,
                .span = .{ .start = tok.start, .end = tok.end },
            } });
        },
        .kw_nil => {
            p.pos += 1;
            return try p.allocExpr(.{ .nil_lit = .{
                .span = .{ .start = tok.start, .end = tok.end },
            } });
        },
        .kw_self => {
            p.pos += 1;
            return try p.allocExpr(.{ .self_expr = .{
                .span = .{ .start = tok.start, .end = tok.end },
            } });
        },
        .kw_super => {
            p.pos += 1;
            return try p.allocExpr(.{ .super_expr = .{
                .span = .{ .start = tok.start, .end = tok.end },
            } });
        },
        .ident => {
            // The lang has no separate char-literal token; the lexer
            // doesn't distinguish 'x' at the token level either —
            // chars come through as int_lit with the decoded value
            // attached. So the only ident-driven primaries are
            // variable refs and capitalized-type struct-literal
            // shapes (`Foo { ... }`).
            const next = p.peekAt(1).kind;
            if (next == .lbrace and looksLikeStructLit(p)) {
                return try parseStructLit(p);
            }
            p.pos += 1;
            return try p.allocExpr(.{ .ident = .{
                .span = .{ .start = tok.start, .end = tok.end },
            } });
        },
        .str_start => return try parseStringLit(p),
        .lparen => return try parseParenOrTupleExpr(p),
        .lbracket => return try parseListLit(p),
        .kw_do => return try parseDoExpr(p),
        .kw_if => return try parseIfExpr(p),
        .kw_lambda => return try parseLambda(p),
        else => {
            try p.recordError("expected expression", "expression");
            return error.ParseFailed;
        },
    }
}

/// Conservative heuristic: a struct literal in expression position
/// looks like `TypeName { ... }`. We don't have an unambiguous way
/// to tell `if x { ... }` from a struct lit without keyword
/// disambiguation; the lang uses `then`/`do` to fence those, so
/// `Ident {` in expression position is always a struct literal.
fn looksLikeStructLit(p: *const Parser) bool {
    // First char of the ident must be uppercase OR it must be a
    // known compiler-built-in (`Vec`). The simplest test is "does
    // the ident's first byte look like an ASCII uppercase?"
    const tok = p.peek();
    if (tok.start >= p.source.len) return false;
    const b = p.source[tok.start];
    return b >= 'A' and b <= 'Z';
}

fn parseStructLit(p: *Parser) ParserError!*ast.Expr {
    const name_tok = p.peek();
    p.pos += 1;
    _ = try p.expect(.lbrace, "{");
    p.skipNewlines();

    var fields: std.ArrayList(ast.StructLitField) = .empty;
    errdefer {
        for (fields.items) |f| ast.freeExpr(p.allocator, f.value);
        fields.deinit(p.allocator);
    }

    if (!p.check(.rbrace)) {
        while (true) {
            p.skipNewlines();
            if (p.check(.rbrace)) break;
            const fname_tok = try p.expect(.ident, "field name");
            _ = try p.expect(.colon, ":");
            const value = try parseExpression(p, 0);
            try fields.append(p.allocator, .{
                .name = ast.Span.fromToken(fname_tok),
                .value = value,
                .span = .{ .start = fname_tok.start, .end = value.span().end },
            });
            if (p.accept(.comma) == null) break;
            p.skipNewlines();
        }
    }
    p.skipNewlines();
    const rb = try p.expect(.rbrace, "}");
    return try p.allocExpr(.{ .struct_lit = .{
        .type_name = ast.Span.fromToken(name_tok),
        .fields = try fields.toOwnedSlice(p.allocator),
        .span = .{ .start = name_tok.start, .end = rb.end },
    } });
}

fn parseStringLit(p: *Parser) ParserError!*ast.Expr {
    const start_tok = p.peek();
    p.pos += 1;
    var parts: std.ArrayList(ast.StrPart) = .empty;
    errdefer cleanupStrParts(p.allocator, &parts);

    var end_idx: u32 = start_tok.end;
    while (true) {
        const t = p.peek();
        switch (t.kind) {
            .str_part => {
                p.pos += 1;
                try parts.append(p.allocator, .{ .lit = .{
                    .span = .{ .start = t.start, .end = t.end },
                } });
                end_idx = t.end;
            },
            .str_expr_start => {
                p.pos += 1;
                const inner = try parseExpression(p, 0);
                // Optional format spec — `:fmt` before `)`. The
                // lexer doesn't emit a dedicated `:fmt` token today,
                // so the parser accepts `:` followed by tokens up
                // to the matching `)`. The captured span covers
                // those bytes verbatim.
                var fmt_span: ?ast.Span = null;
                if (p.accept(.colon)) |colon_tok| {
                    const fmt_start = colon_tok.end;
                    var depth: u32 = 0;
                    while (true) {
                        const nt = p.peek();
                        if (nt.kind == .str_expr_end and depth == 0) break;
                        if (nt.kind == .lparen) depth += 1;
                        if (nt.kind == .rparen and depth > 0) depth -= 1;
                        if (nt.kind == .eof) break;
                        p.pos += 1;
                    }
                    const fmt_end = p.peek().start;
                    fmt_span = .{ .start = fmt_start, .end = fmt_end };
                }
                const close = try p.expect(.str_expr_end, ")");
                try parts.append(p.allocator, .{ .interp = .{
                    .expr = inner,
                    .format_spec = fmt_span,
                    .span = .{ .start = t.start, .end = close.end },
                } });
                end_idx = close.end;
            },
            .str_end => {
                p.pos += 1;
                end_idx = t.end;
                break;
            },
            else => {
                try p.recordError("malformed string literal", "string part");
                return error.ParseFailed;
            },
        }
    }
    return try p.allocExpr(.{ .str_lit = .{
        .parts = try parts.toOwnedSlice(p.allocator),
        .span = .{ .start = start_tok.start, .end = end_idx },
    } });
}

fn cleanupStrParts(
    allocator: std.mem.Allocator,
    parts: *std.ArrayList(ast.StrPart),
) void {
    for (parts.items) |p| switch (p) {
        .lit => {},
        .interp => |ip| ast.freeExpr(allocator, ip.expr),
    };
    parts.deinit(allocator);
}

fn parseParenOrTupleExpr(p: *Parser) ParserError!*ast.Expr {
    const lp = p.peek();
    p.pos += 1;
    p.skipNewlines();
    const first = try parseExpression(p, 0);
    errdefer ast.freeExpr(p.allocator, first);

    if (p.accept(.rparen)) |rp| {
        return try p.allocExpr(.{ .paren = .{
            .inner = first,
            .span = .{ .start = lp.start, .end = rp.end },
        } });
    }

    // Tuple: at least one comma.
    var elems: std.ArrayList(*ast.Expr) = .empty;
    errdefer {
        for (elems.items) |e| ast.freeExpr(p.allocator, e);
        elems.deinit(p.allocator);
    }
    try elems.append(p.allocator, first);
    while (p.accept(.comma)) |_| {
        p.skipNewlines();
        if (p.check(.rparen)) break; // trailing comma
        const e = try parseExpression(p, 0);
        try elems.append(p.allocator, e);
    }
    const rp = try p.expect(.rparen, ")");
    return try p.allocExpr(.{ .tuple_lit = .{
        .elems = try elems.toOwnedSlice(p.allocator),
        .span = .{ .start = lp.start, .end = rp.end },
    } });
}

fn parseListLit(p: *Parser) ParserError!*ast.Expr {
    const lb = p.peek();
    p.pos += 1;
    p.skipNewlines();
    var elems: std.ArrayList(*ast.Expr) = .empty;
    errdefer {
        for (elems.items) |e| ast.freeExpr(p.allocator, e);
        elems.deinit(p.allocator);
    }
    if (!p.check(.rbracket)) {
        while (true) {
            p.skipNewlines();
            const e = try parseExpression(p, 0);
            try elems.append(p.allocator, e);
            if (p.accept(.comma) == null) break;
            p.skipNewlines();
            if (p.check(.rbracket)) break;
        }
    }
    p.skipNewlines();
    const rb = try p.expect(.rbracket, "]");
    return try p.allocExpr(.{ .list_lit = .{
        .elems = try elems.toOwnedSlice(p.allocator),
        .span = .{ .start = lb.start, .end = rb.end },
    } });
}

fn parseDoExpr(p: *Parser) ParserError!*ast.Expr {
    const do_tok = p.peek();
    p.pos += 1;
    p.skipNewlines();

    var body: std.ArrayList(ast.Statement) = .empty;
    errdefer cleanupStatements(p.allocator, &body);
    while (!p.atEnd() and !p.check(.kw_end)) {
        try parseStatement(p, &body);
        p.skipNewlines();
    }
    const end_tok = try p.expect(.kw_end, "end");
    return try p.allocExpr(.{ .do_expr = .{
        .body = try body.toOwnedSlice(p.allocator),
        .span = .{ .start = do_tok.start, .end = end_tok.end },
    } });
}

fn parseIfExpr(p: *Parser) ParserError!*ast.Expr {
    const start_tok = p.peek();
    const result = try parseIfChain(p);
    return try p.allocExpr(.{ .if_expr = .{
        .arms = result.arms,
        .else_body = result.else_body,
        .span = .{ .start = start_tok.start, .end = result.end },
    } });
}

fn parseLambda(p: *Parser) ParserError!*ast.Expr {
    const lambda_tok = p.peek();
    p.pos += 1;
    _ = try p.expect(.lparen, "(");
    const params = try parseParamList(p);
    errdefer freeParams(p.allocator, params);

    var ret_type: ?*ast.TypeAnn = null;
    if (p.accept(.arrow)) |_| {
        ret_type = try parseTypeAnn(p);
    }
    errdefer if (ret_type) |r| ast.freeTypeAnn(p.allocator, r);

    p.skipNewlines();
    var body: std.ArrayList(ast.Statement) = .empty;
    errdefer cleanupStatements(p.allocator, &body);
    while (!p.atEnd() and !p.check(.kw_end)) {
        try parseStatement(p, &body);
        p.skipNewlines();
    }
    const end_tok = try p.expect(.kw_end, "end");
    return try p.allocExpr(.{ .lambda = .{
        .params = params,
        .ret_type = ret_type,
        .body = try body.toOwnedSlice(p.allocator),
        .span = .{ .start = lambda_tok.start, .end = end_tok.end },
    } });
}
