/// Asm parser — consumes the fused source string from
/// `include.resolveIncludes` and emits an `ast.Program`.
///
/// Scope so far: top-level loop, label statements, `const`
/// directive with full compile-time expression RHS (per asm spec
/// §1.7 operator set). Remaining directives + instructions land
/// in subsequent PRs.
///
/// Architecture note: the leaf parsers (`hexP`, `identP`,
/// `colonP`, …) are knit byte-parsers reused from `lexer.zig`.
/// Statement-level dispatch is hand-rolled — knit's `choice`
/// composes well over leaves but the directive layer wants
/// `if`-style cascading + threaded state (the `ConstantTable`),
/// which reads cleaner as explicit code.
const std = @import("std");
const knit = @import("knit");
const core = knit.core;
const lexer = @import("lexer.zig");
const include = @import("include.zig");
const ast = @import("ast.zig");
const expr = @import("expr.zig");

/// Output of `parse` — the program AST plus any diagnostics
/// raised while building it. Errors don't abort parsing; the
/// parser recovers to the next statement boundary so a single
/// run drains every problem at once.
pub const ParseTree = struct {
    program: ast.Program,
    errors: []include.Diagnostic,
    allocator: std.mem.Allocator,

    /// Release the owned statements list and the diagnostics buffer.
    pub fn deinit(self: *ParseTree) void {
        self.program.deinit();
        self.allocator.free(self.errors);
    }

    /// `true` when at least one diagnostic was recorded.
    pub fn hasErrors(self: ParseTree) bool {
        return self.errors.len > 0;
    }
};

/// Parse a fused source string into an `ast.Program` + diagnostics.
/// Never fails on grammar errors — those go into `errors` (typically
/// one per misshapen statement). The only error path is OOM.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) !ParseTree {
    var statements: std.ArrayList(ast.Statement) = .empty;
    errdefer cleanupStatements(allocator, &statements);
    var errors: std.ArrayList(include.Diagnostic) = .empty;
    errdefer errors.deinit(allocator);

    var consts = expr.ConstantTable.init(allocator);
    defer consts.deinit();

    var state = core.ParseState.init(source, allocator);

    while (state.index < source.len) {
        skipSeparators(&state);
        if (state.index >= source.len) break;
        try parseStatement(&state, allocator, &statements, &errors, &consts);
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

fn cleanupStatements(allocator: std.mem.Allocator, statements: *std.ArrayList(ast.Statement)) void {
    for (statements.items) |s| switch (s) {
        .const_decl => |c| ast.freeExpr(allocator, c.expr),
        else => {},
    };
    statements.deinit(allocator);
}

// ---------- statement dispatch ----------

fn parseStatement(
    state: *core.ParseState,
    allocator: std.mem.Allocator,
    statements: *std.ArrayList(ast.Statement),
    errors: *std.ArrayList(include.Diagnostic),
    consts: *expr.ConstantTable,
) !void {
    const stmt_start = state.index;

    // `const NAME = <expr>` — must be checked before generic
    // labels, since the bare `const` lexeme would otherwise be
    // taken as a label's identifier.
    if (consumeKeyword(state, "const")) {
        return parseConstDecl(state, allocator, stmt_start, statements, errors, consts);
    }

    // Label: `ident ":"`. The colon distinguishes a label from an
    // instruction line that happens to start with an identifier.
    if (try tryParseLabel(state, allocator, stmt_start, statements)) return;

    // Anything else: record the line as an `unknown` statement,
    // emit a diagnostic, and recover to the next newline.
    try recordUnknown(state, allocator, stmt_start, statements, errors);
}

// ---------- label ----------

fn tryParseLabel(
    state: *core.ParseState,
    allocator: std.mem.Allocator,
    stmt_start: usize,
    statements: *std.ArrayList(ast.Statement),
) !bool {
    const saved = state.index;
    skipBlanksInLine(state);
    const ident_result = lexer.identP.parseFn(state);
    if (ident_result != .ok) {
        state.index = saved;
        return false;
    }
    const ident_token = ident_result.ok.value;
    skipBlanksInLine(state);
    const colon_result = lexer.colonP.parseFn(state);
    if (colon_result != .ok) {
        state.index = saved;
        return false;
    }
    const colon_token = colon_result.ok.value;
    _ = stmt_start;
    try statements.append(allocator, .{ .label = .{
        .name = ast.Span.fromToken(ident_token),
        .span = ast.Span.join(ast.Span.fromToken(ident_token), ast.Span.fromToken(colon_token)),
    } });
    return true;
}

// ---------- const directive ----------

fn parseConstDecl(
    state: *core.ParseState,
    allocator: std.mem.Allocator,
    stmt_start: usize,
    statements: *std.ArrayList(ast.Statement),
    errors: *std.ArrayList(include.Diagnostic),
    consts: *expr.ConstantTable,
) !void {
    skipBlanksInLine(state);

    // Name.
    const name_result = lexer.identP.parseFn(state);
    if (name_result != .ok) {
        try errors.append(allocator, .{
            .parse_error = core.parseError(
                "const",
                state.index,
                "expected identifier after `const` keyword",
                .{ .expected = "identifier", .kind = .syntactic },
            ),
        });
        try recoverToNewline(state);
        try statements.append(allocator, .{ .unknown = .{
            .span = spanFrom(stmt_start, state.index),
        } });
        return;
    }
    const name_token = name_result.ok.value;

    skipBlanksInLine(state);

    // `=`.
    const eq_result = lexer.equalsP.parseFn(state);
    if (eq_result != .ok) {
        try errors.append(allocator, .{
            .parse_error = core.parseError(
                "const",
                state.index,
                "expected `=` after const name",
                .{ .expected = "=", .kind = .syntactic },
            ),
        });
        try recoverToNewline(state);
        try statements.append(allocator, .{ .unknown = .{
            .span = spanFrom(stmt_start, state.index),
        } });
        return;
    }

    // RHS expression.
    const rhs = expr.parseExpression(state, allocator, errors) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseFailed => {
            try recoverToNewline(state);
            try statements.append(allocator, .{ .unknown = .{
                .span = spanFrom(stmt_start, state.index),
            } });
            return;
        },
    };

    // Evaluate against the constants visible so far. Failure
    // becomes a diagnostic but we still keep the AST node — the
    // symbol-table pass can re-walk it later if it wants.
    const eval = expr.evalExpr(rhs, state.input, consts.*);
    switch (eval) {
        .ok => |v| {
            const name_text = state.input[name_token.start..name_token.end];
            try consts.put(name_text, v);
        },
        .err => |diag| try errors.append(allocator, diag),
    }

    try statements.append(allocator, .{ .const_decl = .{
        .name = ast.Span.fromToken(name_token),
        .expr = rhs,
        .span = spanFrom(stmt_start, state.index),
    } });
}

// ---------- unknown / recovery ----------

fn recordUnknown(
    state: *core.ParseState,
    allocator: std.mem.Allocator,
    stmt_start: usize,
    statements: *std.ArrayList(ast.Statement),
    errors: *std.ArrayList(include.Diagnostic),
) !void {
    try errors.append(allocator, .{
        .parse_error = core.parseError(
            "statement",
            stmt_start,
            "unrecognized statement shape (directives + instructions arrive in follow-up PRs)",
            .{ .kind = .syntactic },
        ),
    });
    try recoverToNewline(state);
    try statements.append(allocator, .{ .unknown = .{
        .span = spanFrom(stmt_start, state.index),
    } });
}

fn recoverToNewline(state: *core.ParseState) !void {
    while (state.index < state.input.len and state.input[state.index] != '\n') {
        state.advance(1);
    }
}

// ---------- helpers ----------

fn consumeKeyword(state: *core.ParseState, kw: []const u8) bool {
    const saved = state.index;
    skipBlanksInLine(state);
    const r = lexer.identP.parseFn(state);
    if (r != .ok) {
        state.index = saved;
        return false;
    }
    const token = r.ok.value;
    const lex = state.input[token.start..token.end];
    if (!std.mem.eql(u8, lex, kw)) {
        state.index = saved;
        return false;
    }
    return true;
}

fn skipBlanksInLine(state: *core.ParseState) void {
    while (state.index < state.input.len) {
        const b = state.input[state.index];
        if (b == ' ' or b == '\t') {
            state.advance(1);
        } else if (b == ';') {
            while (state.index < state.input.len and state.input[state.index] != '\n') state.advance(1);
        } else {
            break;
        }
    }
}

fn skipSeparators(state: *core.ParseState) void {
    while (state.index < state.input.len) {
        const b = state.input[state.index];
        if (b == ' ' or b == '\t' or b == '\n') {
            state.advance(1);
        } else if (b == ';') {
            while (state.index < state.input.len and state.input[state.index] != '\n') state.advance(1);
        } else {
            break;
        }
    }
}

fn spanFrom(start: usize, end: usize) ast.Span {
    // safety: source offsets bounded by max_file_size (16 MiB) per include.zig.
    return .{ .start = @intCast(start), .end = @intCast(end) };
}
