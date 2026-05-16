/// Gero-lang parser — driver. Consumes the lexer's `TokenStream`,
/// runs a hand-rolled statement-kind dispatch, and hands off to
/// sibling modules for each language sub-surface:
///
///   - `expr.zig`       — Pratt expressions + primaries
///   - `pattern.zig`    — `match` / `let` destructuring patterns
///   - `type_ann.zig`   — type annotations
///   - `annotation.zig` — `@name(...)` decorators
///   - `decl.zig`       — `let` / `const` / `def` / `class` /
///                        `struct` / `enum` / `use`
///   - `stmt.zig`       — `if` / `while` / `for` / `match` /
///                        `do` / `return` / `print` / expr-stmts
///
/// Errors append to `errors` but never abort parsing — the parser
/// recovers to the next newline so one drive surfaces every problem.
///
/// `Parser`, `ParserError`, and the helpers below are `pub` so the
/// sibling modules can compose against them. They aren't part of
/// the `gero.lang` public API surface (`src/lang.zig` re-exports
/// only `parse`, `ParseTree`, and the `ast` barrel).
const std = @import("std");
const knit = @import("knit");
const core = knit.core;
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");
const annotation_mod = @import("annotation.zig");
const decl_mod = @import("decl.zig");
const stmt_mod = @import("stmt.zig");

const Kind = lexer.Token.Kind;

/// Output of `parse` — the program AST plus diagnostics. Errors
/// don't abort parsing; the parser recovers to the next statement
/// boundary so a single run drains every problem.
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
    errdefer cleanupStatementList(allocator, &statements);

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
    // is released by the `defer` above.
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

/// Cleanup helper used by `parse`'s `errdefer` and by sibling
/// modules for body lists (`do`/`if`/`match` arms, function bodies).
pub fn cleanupStatements(
    allocator: std.mem.Allocator,
    statements: *std.ArrayList(ast.Statement),
) void {
    cleanupStatementList(allocator, statements);
}

fn cleanupStatementList(
    allocator: std.mem.Allocator,
    statements: *std.ArrayList(ast.Statement),
) void {
    for (statements.items) |*s| ast.freeStatement(allocator, s);
    statements.deinit(allocator);
}

/// Release an annotation slice (and the expression args owned by
/// each entry). Shared between `decl.zig` and the cleanup helpers
/// here.
pub fn freeAnnSlice(allocator: std.mem.Allocator, anns: []ast.Annotation) void {
    for (anns) |a| {
        for (a.args) |arg| ast.freeExpr(allocator, arg);
        allocator.free(a.args);
    }
    allocator.free(anns);
}

/// Drain pending annotations into a fresh owned slice. The buffer
/// is reset so subsequent decls don't inherit stale entries.
pub fn takePendingAnnotations(p: *Parser) ![]ast.Annotation {
    const slice = try p.allocator.dupe(ast.Annotation, p.pending_annotations.items);
    p.pending_annotations.clearRetainingCapacity();
    return slice;
}

// =====================================================================
// Parser state + cursor helpers.
// =====================================================================

/// Working state of a single `parse` invocation. `pos` cursors
/// `tokens`; sibling modules call the methods below to advance it
/// and accumulate diagnostics.
pub const Parser = struct {
    source: []const u8,
    tokens: []const lexer.Token,
    pos: usize,
    allocator: std.mem.Allocator,
    errors: *std.ArrayList(core.ParseError),
    pending_annotations: *std.ArrayList(ast.Annotation),

    /// Current token. Always defined — the lexer guarantees a
    /// trailing `.eof` token.
    pub fn peek(self: *const Parser) lexer.Token {
        return self.tokens[self.pos];
    }

    /// Token `n` positions ahead. Safe past EOF: returns the EOF
    /// token (the lexer guarantees one trailing).
    pub fn peekAt(self: *const Parser, n: usize) lexer.Token {
        const idx = @min(self.pos + n, self.tokens.len - 1);
        return self.tokens[idx];
    }

    /// True when the current token is `.eof`.
    pub fn atEnd(self: *const Parser) bool {
        return self.peek().kind == .eof;
    }

    /// True when the current token matches `kind`.
    pub fn check(self: *const Parser, kind: Kind) bool {
        return self.peek().kind == kind;
    }

    /// Consume the current token if it matches `kind`. Returns the
    /// consumed token on hit, `null` on miss.
    pub fn accept(self: *Parser, kind: Kind) ?lexer.Token {
        if (!self.check(kind)) return null;
        const t = self.peek();
        self.pos += 1;
        return t;
    }

    /// Skip newline tokens; they're only meaningful as statement
    /// boundaries.
    pub fn skipNewlines(self: *Parser) void {
        while (self.check(.newline)) self.pos += 1;
    }

    /// Assert the next token is a statement boundary (`.newline`
    /// or EOF); otherwise emit a diagnostic and recover.
    pub fn requireStatementBoundary(self: *Parser) !void {
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

    /// Append a diagnostic anchored at the current token. Records
    /// the actual lexeme so the consumer sees what tripped the
    /// parser.
    pub fn recordError(
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

    /// Advance until the next newline (or EOF). Used for
    /// statement-level error recovery.
    pub fn recoverToNewline(self: *Parser) !void {
        while (!self.atEnd() and !self.check(.newline)) self.pos += 1;
        self.skipNewlines();
    }

    /// Expect a specific token kind. Returns the consumed token on
    /// hit; on miss, emits a diagnostic and bails with
    /// `error.ParseFailed` (caller recovers to the next newline).
    pub fn expect(self: *Parser, kind: Kind, what: []const u8) ParserError!lexer.Token {
        if (self.accept(kind)) |t| return t;
        try self.recordError("expected token", what);
        return error.ParseFailed;
    }

    /// Allocate + initialize an `*Expr`.
    pub fn allocExpr(self: *Parser, value: ast.Expr) !*ast.Expr {
        const node = try self.allocator.create(ast.Expr);
        node.* = value;
        return node;
    }

    /// Allocate + initialize a `*Pattern`.
    pub fn allocPattern(self: *Parser, value: ast.Pattern) !*ast.Pattern {
        const node = try self.allocator.create(ast.Pattern);
        node.* = value;
        return node;
    }

    /// Allocate + initialize a `*TypeAnn`.
    pub fn allocTypeAnn(self: *Parser, value: ast.TypeAnn) !*ast.TypeAnn {
        const node = try self.allocator.create(ast.TypeAnn);
        node.* = value;
        return node;
    }

    /// Borrow the source bytes covered by `span`.
    pub fn lexeme(self: *const Parser, span: ast.Span) []const u8 {
        return self.source[span.start..span.end];
    }
};

/// Local error set for productions that may bail to the nearest
/// statement-recovery point. `OutOfMemory` propagates to the
/// caller; `ParseFailed` triggers `recoverToNewline` at the
/// statement level.
pub const ParserError = error{ OutOfMemory, ParseFailed };

// =====================================================================
// Top-level dispatch.
// =====================================================================

fn parseTopLevel(
    p: *Parser,
    statements: *std.ArrayList(ast.Statement),
) !void {
    // Accumulate annotations into the parser's pending buffer.
    while (p.check(.annotation)) {
        const ann = annotation_mod.parseAnnotation(p) catch |err| switch (err) {
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

/// Dispatch on the leading token kind. Public so sibling modules
/// (`expr.zig` for `do`/`if`/`lambda` bodies, `stmt.zig` for `if`/
/// `while`/`for`/`match` bodies) can recurse back through the same
/// statement-kind switch.
pub fn parseStatement(
    p: *Parser,
    statements: *std.ArrayList(ast.Statement),
) ParserError!void {
    switch (p.peek().kind) {
        .kw_let => try statements.append(p.allocator, try decl_mod.parseLetDecl(p, false)),
        .kw_const => try statements.append(p.allocator, try decl_mod.parseConstDecl(p, false)),
        .kw_def => try statements.append(p.allocator, try decl_mod.parseDefDecl(p, false)),
        .kw_class => try statements.append(p.allocator, try decl_mod.parseClassDecl(p, false)),
        .kw_enum => try statements.append(p.allocator, try decl_mod.parseEnumDecl(p, false)),
        .kw_local => try decl_mod.parseLocalDecl(p, statements),
        .kw_use => try statements.append(p.allocator, try decl_mod.parseUseDecl(p, false)),
        .ident => {
            // `struct Foo ... end` uses a bare identifier (not a
            // reserved keyword), so type-name lookups like
            // `let Stats = ...` stay unambiguous. Look ahead for
            // the dispatch shape.
            const lex = p.source[p.peek().start..p.peek().end];
            if (std.mem.eql(u8, lex, "struct")) {
                try statements.append(p.allocator, try decl_mod.parseStructDecl(p, false));
                return;
            }
            try stmt_mod.parseExprOrAssignStatement(p, statements);
        },
        .kw_if => try statements.append(p.allocator, try stmt_mod.parseIfStatement(p)),
        .kw_while => try statements.append(p.allocator, try stmt_mod.parseWhileStatement(p)),
        .kw_for => try statements.append(p.allocator, try stmt_mod.parseForStatement(p)),
        .kw_match => try statements.append(p.allocator, try stmt_mod.parseMatchStatement(p)),
        .kw_do => try statements.append(p.allocator, try stmt_mod.parseBlockStatement(p)),
        .kw_return => try statements.append(p.allocator, try stmt_mod.parseReturnStatement(p)),
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
        .kw_print => try statements.append(p.allocator, try stmt_mod.parsePrintStatement(p)),
        .eof => return,
        else => try stmt_mod.parseExprOrAssignStatement(p, statements),
    }
}
