const std = @import("std");
const knit = @import("knit");
const core = knit.core;
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");
const include = @import("include.zig");
const annotation_mod = @import("annotation.zig");
const decl_mod = @import("decl.zig");
const stmt_mod = @import("stmt.zig");
const expr_mod = @import("expr.zig");

const Kind = lexer.Token.Kind;

/// Output of `parse` — the program AST plus diagnostics. Errors
/// don't abort parsing; the parser recovers to the next statement
/// boundary so a single run drains every problem.
pub const ParseTree = struct {
    program: ast.Program,
    errors: []core.ParseError,
    /// Line comments from the lexer, carried through so the formatter
    /// can re-emit them. Duped into the tree's allocator — the source
    /// `TokenStream` is freed independently of the tree.
    comments: []lexer.Comment,
    /// Owned message strings the parser allocPrint'd for richer
    /// diagnostics (e.g. `expect` building `"expected )"`).
    /// String literals don't land here — only heap-allocated bytes
    /// that need freeing at deinit.
    allocated_messages: [][]const u8,
    allocator: std.mem.Allocator,

    /// Release the owned statement list and the diagnostics buffer.
    pub fn deinit(self: *ParseTree) void {
        for (self.allocated_messages) |m| self.allocator.free(m);
        self.allocator.free(self.allocated_messages);
        self.program.deinit();
        self.allocator.free(self.errors);
        self.allocator.free(self.comments);
    }

    /// `true` when at least one diagnostic was recorded.
    pub fn hasErrors(self: ParseTree) bool {
        return self.errors.len > 0;
    }
};

/// Parse a tokenized source into an `ast.Program` + diagnostics.
/// Only error path is OOM. Grammar errors land in `errors`.
/// One module's parse result: the file it came from and its own tree.
/// Trees are parsed independently — a module's parse sees only its own
/// tokens — while sharing the buffer the token offsets index into, so
/// every span stays absolute and diagnostics keep pointing at the right
/// file.
pub const ModuleTree = struct {
    file_id: u16,
    tree: ParseTree,
};

/// Per-module parse results plus a flat view over all their
/// statements, in module order. The trees own every node; `program`
/// borrows, so it must not be deinit'd on its own.
pub const ModuleParse = struct {
    modules: []ModuleTree,
    program: ast.Program,
    errors: []core.ParseError,
    allocator: std.mem.Allocator,

    /// Release every module's tree, the flat statement view, and the
    /// merged error list.
    pub fn deinit(self: *ModuleParse) void {
        self.allocator.free(self.program.statements);
        for (self.modules) |*m| m.tree.deinit();
        self.allocator.free(self.modules);
        self.allocator.free(self.errors);
    }

    /// `true` when any module reported a parse error.
    pub fn hasErrors(self: ModuleParse) bool {
        return self.errors.len > 0;
    }
};

/// Parse every module, then present one flat statement view for the
/// stages that still walk the program as a whole.
pub fn parseAllModules(
    allocator: std.mem.Allocator,
    source: []const u8,
    stream: lexer.TokenStream,
    source_map: *const include.SourceMap,
) !ModuleParse {
    const modules = try parseModules(allocator, source, stream, source_map);
    errdefer {
        for (modules) |*m| m.tree.deinit();
        allocator.free(modules);
    }

    var flat: std.ArrayList(ast.Statement) = .empty;
    errdefer flat.deinit(allocator);
    var errs: std.ArrayList(core.ParseError) = .empty;
    errdefer errs.deinit(allocator);
    for (modules) |m| {
        try flat.appendSlice(allocator, m.tree.program.statements);
        try errs.appendSlice(allocator, m.tree.errors);
    }

    return .{
        .modules = modules,
        .program = .{
            .statements = try flat.toOwnedSlice(allocator),
            .allocator = allocator,
        },
        .errors = try errs.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Parse each module separately from the token stream, splitting it by
/// the file each token belongs to. A token whose offset maps to no
/// region — a synthesized span — falls to the first module.
pub fn parseModules(
    allocator: std.mem.Allocator,
    source: []const u8,
    stream: lexer.TokenStream,
    source_map: *const include.SourceMap,
) ![]ModuleTree {
    var out: std.ArrayList(ModuleTree) = .empty;
    errdefer {
        for (out.items) |*m| m.tree.deinit();
        out.deinit(allocator);
    }

    const module_count = @max(source_map.files.items.len, 1);
    var id: u16 = 0;
    while (id < module_count) : (id += 1) {
        var toks: std.ArrayList(lexer.Token) = .empty;
        defer toks.deinit(allocator);
        for (stream.tokens) |t| {
            if (t.kind == .eof) continue;
            const o = source_map.fileIdAt(t.start) orelse 0;
            if (o == id) try toks.append(allocator, t);
        }
        if (toks.items.len == 0) continue;

        // Every parse needs its own terminator; the shared stream's
        // single `.eof` belongs to the last module only.
        const last_end = toks.items[toks.items.len - 1].end;
        try toks.append(allocator, .{ .kind = .eof, .start = last_end, .end = last_end, .value = 0 });

        const sub: lexer.TokenStream = .{
            .tokens = toks.items,
            .errors = &.{},
            .comments = &.{},
            .allocator = allocator,
        };
        try out.append(allocator, .{ .file_id = id, .tree = try parse(allocator, source, sub) });
    }
    return out.toOwnedSlice(allocator);
}

/// Parse one token stream into a tree. Collects every recoverable
/// parse error rather than stopping at the first, so a single run
/// reports as much as it can.
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

    var allocated_messages: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (allocated_messages.items) |m| allocator.free(m);
        allocated_messages.deinit(allocator);
    }

    var p: Parser = .{
        .source = source,
        .tokens = stream.tokens,
        .pos = 0,
        .allocator = allocator,
        .errors = &errors,
        .pending_annotations = &pending_annotations,
        .allocated_messages = &allocated_messages,
        .bracket_depth = 0,
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
            .{ .expected = "E_SYNTAX_ANNOTATION_PLACEMENT", .kind = .semantic },
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
        .comments = try allocator.dupe(lexer.Comment, stream.comments),
        .allocated_messages = try allocated_messages.toOwnedSlice(allocator),
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
    /// Heap-allocated message strings (`expect`'s formatted
    /// "expected X"). Stashed here so `ParseTree.deinit` can free
    /// them. String literals don't land here.
    allocated_messages: *std.ArrayList([]const u8),

    /// How many bracket groups the expression parser currently has
    /// open. Newlines inside a group are insignificant (§2.1), so an
    /// expression may wrap across lines; `parseStatement` zeroes this
    /// for a block body nested inside one, where statements still
    /// terminate at a newline as usual.
    bracket_depth: u32,

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

    /// Skip newlines that fall inside an open bracket group (§2.1).
    /// A no-op at depth zero, where a newline ends the statement.
    pub fn skipNewlinesInBrackets(self: *Parser) void {
        if (self.bracket_depth > 0) self.skipNewlines();
    }

    /// Enter a bracket group opened by the expression parser.
    pub fn openBracket(self: *Parser) void {
        self.bracket_depth += 1;
    }

    /// Leave one. Saturating, so a malformed program that recovers
    /// past a closing bracket cannot underflow.
    pub fn closeBracket(self: *Parser) void {
        if (self.bracket_depth > 0) self.bracket_depth -= 1;
    }

    /// Keywords that close the enclosing block. A statement may end
    /// against one of these with no newline, which is what lets a
    /// whole block sit on one line (`if x print 1 end`).
    const block_close = [_]lexer.Token.Kind{
        .kw_end,
        .kw_else,
        .kw_elif,
        .kw_until,
        .kw_case,
    };

    /// Diagnostic raised when a statement runs into the next one with
    /// no boundary between them. Named so consumers can recognize it
    /// without matching on its prose — the REPL rewrites one-liners by
    /// injecting newlines wherever this fires.
    pub const missing_boundary_message =
        "expected a newline, end-of-input, or a block-closing keyword after statement";

    /// Assert the next token is a statement boundary — a `.newline`,
    /// EOF, or a keyword closing the enclosing block; otherwise emit a
    /// diagnostic and recover.
    pub fn requireStatementBoundary(self: *Parser) !void {
        if (self.atEnd() or self.check(.newline)) {
            self.skipNewlines();
            return;
        }
        for (block_close) |kind| {
            if (self.check(kind)) return;
        }
        try self.recordError(missing_boundary_message, "E_SYNTAX_MISSING_TOKEN");
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
    /// hit; on miss, emits a `E_SYNTAX_MISSING_TOKEN` diagnostic and
    /// bails with `error.ParseFailed` (caller recovers to the next
    /// newline). The `what` string is folded into the message body so
    /// the user sees what was expected.
    pub fn expect(self: *Parser, kind: Kind, what: []const u8) ParserError!lexer.Token {
        if (self.accept(kind)) |t| return t;
        const msg = try std.fmt.allocPrint(self.allocator, "expected {s}", .{what});
        try self.allocated_messages.append(self.allocator, msg);
        try self.recordError(msg, "E_SYNTAX_MISSING_TOKEN");
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
    parseStatement(p, statements) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseFailed => try p.recoverToNewline(),
    };
}

/// `bake def …` or `bake do … end` at statement position (§3.8).
/// The `bake` prefix marks the construct for compile-time
/// evaluation; codegen later runs the bake interpreter and lowers
/// the result to static data.
fn parseBakeStatement(p: *Parser) ParserError!ast.Statement {
    const bake_tok = p.peek();
    p.pos += 1; // consume `bake`
    p.skipNewlines();

    switch (p.peek().kind) {
        .kw_def => {
            // `parseDefDeclInner` already calls `requireStatementBoundary`
            // after consuming the closing `end` — don't double-call it
            // here or the parser trips on the next statement.
            var decl = try decl_mod.parseDefDeclInner(p, false);
            decl.is_bake = true;
            decl.span = .{ .start = bake_tok.start, .end = decl.span.end };
            return .{ .def_decl = decl };
        },
        .kw_do => {
            // `bake do … end` at statement position — evaluate the
            // block at compile time and discard the result. Wrap
            // in an `expr_stmt` carrying the bake-flagged DoExpr.
            const do_expr = try expr_mod.parseBakeDoExpr(p, bake_tok.start);
            try p.requireStatementBoundary();
            return .{ .expr_stmt = .{
                .expr = do_expr,
                .span = do_expr.span(),
            } };
        },
        else => {
            try p.recordError(
                "`bake` must prefix a `def` or `do` block",
                "E_SYNTAX_UNEXPECTED_TOKEN",
            );
            return error.ParseFailed;
        },
    }
}

/// Parse an optional `:label` suffix on a loop head or
/// `break` / `continue`. Returns `null` when the next token is not
/// a colon — that's the unlabeled form. Identifiers after `:` must
/// be plain `[a-z_][a-zA-Z0-9_]*`; the lexer already enforces the
/// lexical shape.
pub fn parseOptionalJumpLabel(p: *Parser) ParserError!?ast.Span {
    if (!p.check(.colon)) return null;
    p.pos += 1; // consume `:`
    const tok = try p.expect(.ident, "label identifier");
    return .{ .start = tok.start, .end = tok.end };
}

/// Builtin `asm "<instruction>"` statement (§4.11). One instruction
/// per `asm` statement; the body is captured as a byte span and the
/// codegen pass performs `{name}` operand substitution. Interpolation
/// `$(…)` inside the asm body is rejected — the syntax is reserved
/// for runtime string interpolation, not asm substitution.
fn emitAsmKeywordStmt(
    p: *Parser,
    statements: *std.ArrayList(ast.Statement),
) ParserError!void {
    const asm_tok = p.peek();
    p.pos += 1; // consume `asm`

    if (!p.check(.str_start)) {
        try p.recordError(
            "`asm` expects a string literal with the instruction body",
            "E_SYNTAX_MISSING_TOKEN",
        );
        return error.ParseFailed;
    }
    const open_tok = p.peek();
    p.pos += 1; // consume `str_start`

    // Body: consume parts up to `str_end`; reject interpolation.
    while (true) {
        const t = p.peek();
        switch (t.kind) {
            .str_part => p.pos += 1,
            .str_expr_start => {
                try p.recordError(
                    "`$(...)` interpolation is not allowed inside `asm`; use `{name}` operand substitution instead",
                    "E_SYNTAX_UNEXPECTED_TOKEN",
                );
                return error.ParseFailed;
            },
            .str_end => {
                p.pos += 1;
                try statements.append(p.allocator, .{ .asm_stmt = .{
                    .body = .{ .start = open_tok.start, .end = t.end },
                    .span = .{ .start = asm_tok.start, .end = t.end },
                } });
                try p.requireStatementBoundary();
                return;
            },
            else => {
                try p.recordError("malformed asm body", "E_SYNTAX_MALFORMED_LITERAL");
                return error.ParseFailed;
            },
        }
    }
}

/// Dispatch on the leading token kind. Public so sibling modules
/// (`expr.zig` for `do`/`if`/`lambda` bodies, `stmt.zig` for `if`/
/// `while`/`for`/`match` bodies) can recurse back through the same
/// statement-kind switch.
///
/// Annotations push into the pending buffer and the parser recurses
/// to consume the following decl that will drain it. (`asm` is now
/// a builtin statement — see §4.11 — not an annotation.)
pub fn parseStatement(
    p: *Parser,
    statements: *std.ArrayList(ast.Statement),
) ParserError!void {
    // A statement always begins outside any bracket group, even when
    // the block holding it sits inside one — `(do … end)` still needs
    // its statements on separate lines.
    const enclosing_depth = p.bracket_depth;
    p.bracket_depth = 0;
    defer p.bracket_depth = enclosing_depth;

    switch (p.peek().kind) {
        .annotation => {
            const tok = p.peek();
            const name = p.source[tok.start + 1 .. tok.end];
            if (std.mem.eql(u8, name, "asm")) {
                try p.recordError(
                    "`@asm(\"...\")` is no longer accepted; use the `asm \"...\"` statement (§4.11)",
                    "E_SYNTAX_ANNOTATION_PLACEMENT",
                );
                return error.ParseFailed;
            }
            const ann = try annotation_mod.parseAnnotation(p);
            try p.pending_annotations.append(p.allocator, ann);
            p.skipNewlines();
            try parseStatement(p, statements);
            return;
        },
        .kw_let => try statements.append(p.allocator, try decl_mod.parseLetDecl(p, false)),
        .kw_const => try statements.append(p.allocator, try decl_mod.parseConstDecl(p, false)),
        .kw_def => try statements.append(p.allocator, try decl_mod.parseDefDecl(p, false)),
        .kw_bake => try statements.append(p.allocator, try parseBakeStatement(p)),
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
        .kw_repeat => try statements.append(p.allocator, try stmt_mod.parseRepeatStatement(p)),
        .kw_match => try statements.append(p.allocator, try stmt_mod.parseMatchStatement(p)),
        .kw_do => try statements.append(p.allocator, try stmt_mod.parseBlockStatement(p)),
        .kw_return => try statements.append(p.allocator, try stmt_mod.parseReturnStatement(p)),
        .kw_break => {
            const t = p.peek();
            p.pos += 1;
            const label = try parseOptionalJumpLabel(p);
            const end: u32 = if (label) |lbl| lbl.end else t.end;
            try statements.append(p.allocator, .{ .break_stmt = .{
                .label = label,
                .span = .{ .start = t.start, .end = end },
            } });
            try p.requireStatementBoundary();
        },
        .kw_continue => {
            const t = p.peek();
            p.pos += 1;
            const label = try parseOptionalJumpLabel(p);
            const end: u32 = if (label) |lbl| lbl.end else t.end;
            try statements.append(p.allocator, .{ .continue_stmt = .{
                .label = label,
                .span = .{ .start = t.start, .end = end },
            } });
            try p.requireStatementBoundary();
        },
        .kw_print => try statements.append(p.allocator, try stmt_mod.parsePrintStatement(p)),
        .kw_defer => try statements.append(p.allocator, try stmt_mod.parseDeferStatement(p)),
        .kw_asm => try emitAsmKeywordStmt(p, statements),
        .eof => return,
        else => try stmt_mod.parseExprOrAssignStatement(p, statements),
    }
}
