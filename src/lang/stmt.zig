/// Statement parsers — control flow (`if`/`elif`/`else`,
/// `while`/`while let`, `for`, `match`), `do…end` blocks, `return`,
/// `print`, and the expression-or-assignment fallthrough.
///
/// Imports `Parser` + `ParserError` from `parser.zig`; delegates
/// to `expr` / `pattern` for sub-shapes and to
/// `parser_mod.parseStatement` for nested bodies.
const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const expr_mod = @import("expr.zig");
const pattern_mod = @import("pattern.zig");

const Parser = parser_mod.Parser;
const ParserError = parser_mod.ParserError;
const Kind = lexer.Token.Kind;

/// Friendly diagnostic when a stray `do` appears at a head-end
/// position (after a `while` / `for` head). `do` remains a keyword
/// because it opens `do…end` blocks (§4.3), but it's not a loop-head
/// separator (§4.5) — emit a clear error rather than letting the
/// inner block consume the loop body silently.
fn rejectStrandedDo(p: *Parser, context: []const u8) ParserError!void {
    if (p.check(.kw_do)) {
        try p.recordError(
            "`do` is not a loop-head separator — the head ends at the newline (`do…end` is the block form only)",
            context,
        );
        return error.ParseFailed;
    }
}

// ---------- if / elif / else ----------

/// `if cond then ... [elif ...] [else ...] end` — statement form.
pub fn parseIfStatement(p: *Parser) ParserError!ast.Statement {
    const start_tok = p.peek();
    const result = try parseIfChain(p);
    try p.requireStatementBoundary();
    return .{ .if_stmt = .{
        .arms = result.arms,
        .else_body = result.else_body,
        .span = .{ .start = start_tok.start, .end = result.end },
    } };
}

/// Output of a parsed if-chain: arms in source order + optional
/// else body + the end-of-`end` byte offset. Used by both
/// `parseIfStatement` and `expr.parseIfExpr`.
pub const IfChain = struct {
    arms: []ast.IfArm,
    else_body: ?[]ast.Statement,
    end: u32,
};

/// Drive the `if` / `elif` / `else` cascade. Consumes the opening
/// `if` and the closing `end`.
pub fn parseIfChain(p: *Parser) ParserError!IfChain {
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
            if (p.check(.kw_if)) {
                p.pos += 1;
                try parseIfArm(p, &arms);
                continue;
            }
            p.skipNewlines();
            var body: std.ArrayList(ast.Statement) = .empty;
            errdefer parser_mod.cleanupStatements(p.allocator, &body);
            while (!p.atEnd() and !p.check(.kw_end)) {
                try parser_mod.parseStatement(p, &body);
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

    // `if let pat = expr [when guard]` — §4.4.1. No `then` separator
    // (§4.4) — the head expression ends at the newline.
    if (p.accept(.kw_let)) |_| {
        let_pattern = try pattern_mod.parsePattern(p);
        _ = try p.expect(.equals, "=");
        let_expr = try expr_mod.parseExpression(p, 0);
        if (p.accept(.kw_when)) |_| {
            let_guard = try expr_mod.parseExpression(p, 0);
        }
    } else {
        cond = try expr_mod.parseExpression(p, 0);
    }
    p.skipNewlines();

    var body: std.ArrayList(ast.Statement) = .empty;
    errdefer parser_mod.cleanupStatements(p.allocator, &body);

    while (!p.atEnd() and !p.check(.kw_end) and !p.check(.kw_else) and !p.check(.kw_elif)) {
        try parser_mod.parseStatement(p, &body);
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

// ---------- while (incl. while let) ----------

/// `while cond ... end` and `while let pat = expr [when guard] ... end`.
/// Head ends at the newline — no `do` separator (§4.5).
pub fn parseWhileStatement(p: *Parser) ParserError!ast.Statement {
    const while_tok = p.peek();
    p.pos += 1;
    const start = while_tok.start;

    var cond: ?*ast.Expr = null;
    var let_pattern: ?*ast.Pattern = null;
    var let_expr: ?*ast.Expr = null;
    var let_guard: ?*ast.Expr = null;

    if (p.accept(.kw_let)) |_| {
        let_pattern = try pattern_mod.parsePattern(p);
        _ = try p.expect(.equals, "=");
        let_expr = try expr_mod.parseExpression(p, 0);
        if (p.accept(.kw_when)) |_| {
            let_guard = try expr_mod.parseExpression(p, 0);
        }
    } else {
        cond = try expr_mod.parseExpression(p, 0);
    }

    try rejectStrandedDo(p, "while");
    const label = try parser_mod.parseOptionalJumpLabel(p);
    p.skipNewlines();

    var body: std.ArrayList(ast.Statement) = .empty;
    errdefer parser_mod.cleanupStatements(p.allocator, &body);
    while (!p.atEnd() and !p.check(.kw_end)) {
        try parser_mod.parseStatement(p, &body);
        p.skipNewlines();
    }
    const end_tok = try p.expect(.kw_end, "end");
    try p.requireStatementBoundary();

    return .{ .while_stmt = .{
        .cond = cond,
        .let_pattern = let_pattern,
        .let_expr = let_expr,
        .let_guard = let_guard,
        .label = label,
        .body = try body.toOwnedSlice(p.allocator),
        .span = .{ .start = start, .end = end_tok.end },
    } };
}

// ---------- for-in ----------

/// `for x in iter [step N] ... end`. Head ends at the newline — no
/// `do` separator (§4.5).
pub fn parseForStatement(p: *Parser) ParserError!ast.Statement {
    const for_tok = p.peek();
    p.pos += 1;
    const start = for_tok.start;

    const binding_tok = try p.expect(.ident, "loop variable name");
    _ = try p.expect(.kw_in, "in");

    const iter = try expr_mod.parseExpression(p, 0);
    errdefer ast.freeExpr(p.allocator, iter);

    var step: ?*ast.Expr = null;
    if (p.accept(.kw_step)) |_| {
        step = try expr_mod.parseExpression(p, 0);
    }
    errdefer if (step) |s| ast.freeExpr(p.allocator, s);

    try rejectStrandedDo(p, "for");
    const label = try parser_mod.parseOptionalJumpLabel(p);
    p.skipNewlines();

    var body: std.ArrayList(ast.Statement) = .empty;
    errdefer parser_mod.cleanupStatements(p.allocator, &body);
    while (!p.atEnd() and !p.check(.kw_end)) {
        try parser_mod.parseStatement(p, &body);
        p.skipNewlines();
    }
    const end_tok = try p.expect(.kw_end, "end");
    try p.requireStatementBoundary();

    return .{ .for_stmt = .{
        .binding = ast.Span.fromToken(binding_tok),
        .iter = iter,
        .step = step,
        .label = label,
        .body = try body.toOwnedSlice(p.allocator),
        .span = .{ .start = start, .end = end_tok.end },
    } };
}

// ---------- repeat ... until cond ----------

/// `repeat [:label] ... until cond` — do-while-style loop. Body
/// runs at least once; the loop exits when `cond` evaluates true
/// (§4.5.5).
pub fn parseRepeatStatement(p: *Parser) ParserError!ast.Statement {
    const repeat_tok = p.peek();
    p.pos += 1;
    const start = repeat_tok.start;

    const label = try parser_mod.parseOptionalJumpLabel(p);
    p.skipNewlines();

    var body: std.ArrayList(ast.Statement) = .empty;
    errdefer parser_mod.cleanupStatements(p.allocator, &body);
    while (!p.atEnd() and !p.check(.kw_until)) {
        try parser_mod.parseStatement(p, &body);
        p.skipNewlines();
    }
    _ = try p.expect(.kw_until, "until");
    const cond = try expr_mod.parseExpression(p, 0);
    errdefer ast.freeExpr(p.allocator, cond);
    try p.requireStatementBoundary();

    return .{ .repeat_stmt = .{
        .body = try body.toOwnedSlice(p.allocator),
        .cond = cond,
        .label = label,
        .span = .{ .start = start, .end = cond.span().end },
    } };
}

// ---------- match ----------

/// `match scrutinee case pat [when guard] => body ... end` (§4.8).
pub fn parseMatchStatement(p: *Parser) ParserError!ast.Statement {
    const match_tok = p.peek();
    p.pos += 1;
    const start = match_tok.start;

    const scrutinee = try expr_mod.parseExpression(p, 0);
    errdefer ast.freeExpr(p.allocator, scrutinee);
    p.skipNewlines();

    var arms: std.ArrayList(ast.MatchArm) = .empty;
    errdefer cleanupMatchArms(p.allocator, &arms);

    while (p.accept(.kw_case)) |case_tok| {
        const arm_start = case_tok.start;
        const pattern = try pattern_mod.parsePattern(p);
        errdefer ast.freePattern(p.allocator, pattern);

        var guard: ?*ast.Expr = null;
        if (p.accept(.kw_when)) |_| {
            guard = try expr_mod.parseExpression(p, 0);
        }
        errdefer if (guard) |g| ast.freeExpr(p.allocator, g);

        _ = try p.expect(.fat_arrow, "=>");
        p.skipNewlines();

        var body: std.ArrayList(ast.Statement) = .empty;
        errdefer parser_mod.cleanupStatements(p.allocator, &body);
        while (!p.atEnd() and !p.check(.kw_case) and !p.check(.kw_end)) {
            try parser_mod.parseStatement(p, &body);
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

// ---------- do block, return, print ----------

/// `do ... end` at statement position.
pub fn parseBlockStatement(p: *Parser) ParserError!ast.Statement {
    const do_tok = p.peek();
    p.pos += 1;
    const start = do_tok.start;
    p.skipNewlines();

    var body: std.ArrayList(ast.Statement) = .empty;
    errdefer parser_mod.cleanupStatements(p.allocator, &body);
    while (!p.atEnd() and !p.check(.kw_end)) {
        try parser_mod.parseStatement(p, &body);
        p.skipNewlines();
    }
    const end_tok = try p.expect(.kw_end, "end");
    try p.requireStatementBoundary();

    return .{ .block = .{
        .body = try body.toOwnedSlice(p.allocator),
        .span = .{ .start = start, .end = end_tok.end },
    } };
}

/// `return [expr]`.
pub fn parseReturnStatement(p: *Parser) ParserError!ast.Statement {
    const ret_tok = p.peek();
    p.pos += 1;
    const start = ret_tok.start;

    var value: ?*ast.Expr = null;
    var end: u32 = ret_tok.end;
    if (!p.check(.newline) and !p.atEnd() and !p.check(.kw_end)) {
        const v = try expr_mod.parseExpression(p, 0);
        end = v.span().end;
        value = v;
    }
    try p.requireStatementBoundary();

    return .{ .return_stmt = .{
        .value = value,
        .span = .{ .start = start, .end = end },
    } };
}

/// `defer <stmt>` — schedule a statement to run at scope exit
/// (§4.10). The inner statement is parsed via the normal
/// `parseStatement` dispatch (so `defer foo()`, `defer do … end`,
/// `defer obj.cleanup()` all work).
pub fn parseDeferStatement(p: *Parser) ParserError!ast.Statement {
    const defer_tok = p.peek();
    p.pos += 1;
    const start = defer_tok.start;

    var temp: std.ArrayList(ast.Statement) = .empty;
    errdefer parser_mod.cleanupStatements(p.allocator, &temp);
    try parser_mod.parseStatement(p, &temp);
    if (temp.items.len != 1) {
        for (temp.items) |*s| ast.freeStatement(p.allocator, s);
        temp.deinit(p.allocator);
        try p.recordError(
            "defer requires exactly one statement (wrap with `do … end` for multi-statement cleanups)",
            "single statement",
        );
        return error.ParseFailed;
    }
    const body_stmt = temp.items[0];
    temp.deinit(p.allocator);

    const body_ptr = try p.allocator.create(ast.Statement);
    body_ptr.* = body_stmt;

    return .{ .defer_stmt = .{
        .body = body_ptr,
        .span = .{ .start = start, .end = body_stmt.span().end },
    } };
}

/// `print expr, expr, ...`.
pub fn parsePrintStatement(p: *Parser) ParserError!ast.Statement {
    const print_tok = p.peek();
    p.pos += 1;
    const start = print_tok.start;

    var args: std.ArrayList(*ast.Expr) = .empty;
    errdefer {
        for (args.items) |a| ast.freeExpr(p.allocator, a);
        args.deinit(p.allocator);
    }

    if (!p.check(.newline) and !p.atEnd()) {
        while (true) {
            const a = try expr_mod.parseExpression(p, 0);
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

// ---------- expression-or-assignment ----------

/// Statement-position dispatch when the leading token can start an
/// expression: parses one expression, then decides between bare
/// `expr_stmt`, `assign` (plain or compound), `inc_dec` (`x++` /
/// `x--`), or `discard` (`_ = expr`).
pub fn parseExprOrAssignStatement(
    p: *Parser,
    statements: *std.ArrayList(ast.Statement),
) ParserError!void {
    const start = p.peek().start;
    const first = try expr_mod.parseExpression(p, 0);
    errdefer ast.freeExpr(p.allocator, first);

    if (matchAssignOp(p.peek().kind)) |op| {
        p.pos += 1;
        // `_ = expr` — discard form. The `_` identifier survived as
        // a plain ident expression; we drop it and emit `.discard`.
        if (op == .set and isUnderscore(p, first)) {
            const value = try expr_mod.parseExpression(p, 0);
            ast.freeExpr(p.allocator, first);
            try p.requireStatementBoundary();
            try statements.append(p.allocator, .{ .discard = .{
                .expr = value,
                .span = .{ .start = start, .end = value.span().end },
            } });
            return;
        }
        const value = try expr_mod.parseExpression(p, 0);
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
