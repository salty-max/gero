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
        .data8, .data16 => |d| {
            for (d.values) |v| switch (v) {
                .expr => |e| ast.freeExpr(allocator, e.expr),
                .reserve => |r| ast.freeExpr(allocator, r.count_expr),
                .addr_lit, .sym_ref, .string => {},
            };
            allocator.free(d.values);
        },
        .struct_decl => |sd| allocator.free(sd.fields),
        .org => |o| ast.freeExpr(allocator, o.addr_expr),
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

    // Directive keywords must be checked before generic labels,
    // since the bare keyword lexeme would otherwise be taken as a
    // label's identifier.
    if (consumeKeyword(state, "const")) {
        return parseConstDecl(state, allocator, stmt_start, statements, errors, consts);
    }
    if (consumeKeyword(state, "data8")) {
        return parseDataDecl(state, allocator, stmt_start, statements, errors, consts, .data8);
    }
    if (consumeKeyword(state, "data16")) {
        return parseDataDecl(state, allocator, stmt_start, statements, errors, consts, .data16);
    }
    if (consumeKeyword(state, "struct")) {
        return parseStructDecl(state, allocator, stmt_start, statements, errors, consts);
    }
    if (consumeKeyword(state, "org")) {
        return parseOrgDecl(state, allocator, stmt_start, statements, errors, consts);
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

// ---------- data8 / data16 directives ----------

/// Selects which data directive is being parsed. The parser
/// shares one function across both — only the variant tag and
/// the string-literal admissibility differ.
const DataKind = enum { data8, data16 };

fn parseDataDecl(
    state: *core.ParseState,
    allocator: std.mem.Allocator,
    stmt_start: usize,
    statements: *std.ArrayList(ast.Statement),
    errors: *std.ArrayList(include.Diagnostic),
    consts: *expr.ConstantTable,
    kind: DataKind,
) !void {
    const kw_name: []const u8 = switch (kind) {
        .data8 => "data8",
        .data16 => "data16",
    };

    skipBlanksInLine(state);

    // Name.
    const name_result = lexer.identP.parseFn(state);
    if (name_result != .ok) {
        try errors.append(allocator, .{
            .parse_error = core.parseError(
                kw_name,
                state.index,
                "expected identifier after directive keyword",
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
                kw_name,
                state.index,
                "expected `=` after directive name",
                .{ .expected = "=", .kind = .syntactic },
            ),
        });
        try recoverToNewline(state);
        try statements.append(allocator, .{ .unknown = .{
            .span = spanFrom(stmt_start, state.index),
        } });
        return;
    }

    // Comma-separated value list. At least one value required.
    var values: std.ArrayList(ast.DataValue) = .empty;
    errdefer cleanupDataValues(allocator, &values);

    while (true) {
        const val_or_err = parseDataValue(state, allocator, errors, consts, kind);
        const val = val_or_err catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseFailed => {
                cleanupDataValues(allocator, &values);
                try recoverToNewline(state);
                try statements.append(allocator, .{ .unknown = .{
                    .span = spanFrom(stmt_start, state.index),
                } });
                return;
            },
        };
        try values.append(allocator, val);

        skipBlanksInLine(state);
        if (peekByte(state, ',')) {
            state.advance(1);
            continue;
        }
        break;
    }

    const owned = try values.toOwnedSlice(allocator);
    const decl: ast.DataDecl = .{
        .name = ast.Span.fromToken(name_token),
        .values = owned,
        .span = spanFrom(stmt_start, state.index),
    };
    try statements.append(allocator, switch (kind) {
        .data8 => .{ .data8 = decl },
        .data16 => .{ .data16 = decl },
    });
}

fn parseDataValue(
    state: *core.ParseState,
    allocator: std.mem.Allocator,
    errors: *std.ArrayList(include.Diagnostic),
    consts: *expr.ConstantTable,
    kind: DataKind,
) expr.ParseError!ast.DataValue {
    skipBlanksInLine(state);
    const start = state.index;

    // `"..."` string literal — `data8` only.
    if (state.index < state.input.len and state.input[state.index] == '"') {
        const r = lexer.stringP.parseFn(state);
        if (r == .ok) {
            const tok = r.ok.value;
            if (kind == .data16) {
                try errors.append(state.allocator, .{
                    .parse_error = core.parseError(
                        "data16",
                        tok.start,
                        "string literals are only allowed in `data8` bodies",
                        .{ .expected = "hex / addr / sym_ref / expression", .kind = .semantic },
                    ),
                });
            }
            return .{ .string = .{
                .span = .{ .start = tok.start, .end = tok.end },
            } };
        }
        // Fall through — the string parser refused (probably
        // unterminated). Let the lexer's earlier error stand;
        // we'll surface a generic "expected value" below.
    }

    // `&FFFF` address literal — must come before the expression
    // path because the expression parser treats `&` as bitwise AND.
    if (state.index < state.input.len and state.input[state.index] == '&') {
        const r = lexer.addrP.parseFn(state);
        if (r == .ok) {
            const tok = r.ok.value;
            return .{ .addr_lit = .{
                .value = tok.value,
                .span = .{ .start = tok.start, .end = tok.end },
            } };
        }
    }

    // `@sym` reference.
    if (state.index < state.input.len and state.input[state.index] == '@') {
        const r = lexer.symRefP.parseFn(state);
        if (r == .ok) {
            const tok = r.ok.value;
            return .{ .sym_ref = .{
                .span = .{ .start = tok.start, .end = tok.end },
            } };
        }
    }

    // `reserve N` — the count is itself an expression.
    if (consumeKeyword(state, "reserve")) {
        const count_expr = try expr.parseExpression(state, allocator, errors);
        const count: ?u16 = blk: {
            const eval = expr.evalExpr(count_expr, state.input, consts.*);
            switch (eval) {
                .ok => |v| break :blk v,
                .err => |d| {
                    try errors.append(state.allocator, d);
                    break :blk null;
                },
            }
        };
        return .{ .reserve = .{
            .count_expr = count_expr,
            .count = count,
            .span = spanFrom(start, state.index),
        } };
    }

    // Fall through to the general compile-time expression.
    const e = try expr.parseExpression(state, allocator, errors);
    return .{ .expr = .{
        .expr = e,
        .span = e.span(),
    } };
}

fn cleanupDataValues(allocator: std.mem.Allocator, values: *std.ArrayList(ast.DataValue)) void {
    for (values.items) |v| switch (v) {
        .expr => |e| ast.freeExpr(allocator, e.expr),
        .reserve => |r| ast.freeExpr(allocator, r.count_expr),
        .addr_lit, .sym_ref, .string => {},
    };
    values.deinit(allocator);
}

// ---------- struct directive ----------

fn parseStructDecl(
    state: *core.ParseState,
    allocator: std.mem.Allocator,
    stmt_start: usize,
    statements: *std.ArrayList(ast.Statement),
    errors: *std.ArrayList(include.Diagnostic),
    consts: *expr.ConstantTable,
) !void {
    skipBlanksInLine(state);

    // Type name.
    const name_result = lexer.identP.parseFn(state);
    if (name_result != .ok) {
        try errors.append(allocator, .{
            .parse_error = core.parseError(
                "struct",
                state.index,
                "expected identifier after `struct` keyword",
                .{ .expected = "identifier", .kind = .syntactic },
            ),
        });
        try recoverToEndOfBlock(state);
        try statements.append(allocator, .{ .unknown = .{
            .span = spanFrom(stmt_start, state.index),
        } });
        return;
    }
    const name_token = name_result.ok.value;

    skipSeparators(state); // whitespace + newlines allowed before `{`

    // Opening brace.
    const lb_result = lexer.lbraceP.parseFn(state);
    if (lb_result != .ok) {
        try errors.append(allocator, .{
            .parse_error = core.parseError(
                "struct",
                state.index,
                "expected `{` to open struct body",
                .{ .expected = "{", .kind = .syntactic },
            ),
        });
        try recoverToEndOfBlock(state);
        try statements.append(allocator, .{ .unknown = .{
            .span = spanFrom(stmt_start, state.index),
        } });
        return;
    }

    // Field list. Fields separated by commas, newlines, or both.
    // Closing `}` ends the body. Allow a trailing comma.
    var fields: std.ArrayList(ast.StructField) = .empty;
    errdefer fields.deinit(allocator);

    var running_offset: u16 = 0;

    while (true) {
        skipSeparators(state);

        // End of body?
        if (state.index < state.input.len and state.input[state.index] == '}') {
            state.advance(1);
            break;
        }

        const field_or_err = parseStructField(state, allocator, errors, running_offset);
        const field = field_or_err catch |err| switch (err) {
            error.OutOfMemory => {
                fields.deinit(allocator);
                return error.OutOfMemory;
            },
            error.ParseFailed => {
                fields.deinit(allocator);
                try recoverToEndOfBlock(state);
                try statements.append(allocator, .{ .unknown = .{
                    .span = spanFrom(stmt_start, state.index),
                } });
                return;
            },
        };
        try fields.append(allocator, field);
        running_offset += field.ty.width();

        skipBlanksInLine(state);
        // Optional comma between fields. The next iteration's
        // `skipSeparators` handles newlines.
        if (peekByte(state, ',')) state.advance(1);
    }

    // Inject `Name.field` offset constants into the parser's
    // ConstantTable so downstream expressions can resolve them.
    const struct_name = state.input[name_token.start..name_token.end];
    for (fields.items) |f| {
        const field_name = state.input[f.name.start..f.name.end];
        const qualified = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ struct_name, field_name });
        try consts.putOwned(qualified, f.offset);
    }

    const owned = try fields.toOwnedSlice(allocator);
    try statements.append(allocator, .{ .struct_decl = .{
        .name = ast.Span.fromToken(name_token),
        .fields = owned,
        .size = running_offset,
        .span = spanFrom(stmt_start, state.index),
    } });
}

fn parseStructField(
    state: *core.ParseState,
    allocator: std.mem.Allocator,
    errors: *std.ArrayList(include.Diagnostic),
    offset: u16,
) expr.ParseError!ast.StructField {
    _ = allocator;
    const field_start = state.index;
    skipBlanksInLine(state);

    // Field name.
    const name_result = lexer.identP.parseFn(state);
    if (name_result != .ok) {
        try errors.append(state.allocator, .{
            .parse_error = core.parseError(
                "struct",
                state.index,
                "expected field name",
                .{ .expected = "identifier", .kind = .syntactic },
            ),
        });
        return error.ParseFailed;
    }
    const name_token = name_result.ok.value;

    skipBlanksInLine(state);

    // Separator `:`.
    const colon_result = lexer.colonP.parseFn(state);
    if (colon_result != .ok) {
        try errors.append(state.allocator, .{
            .parse_error = core.parseError(
                "struct",
                state.index,
                "expected `:` between field name and type",
                .{ .expected = ":", .kind = .syntactic },
            ),
        });
        return error.ParseFailed;
    }

    skipBlanksInLine(state);

    // Type — must be `u8` or `u16`.
    const type_result = lexer.identP.parseFn(state);
    if (type_result != .ok) {
        try errors.append(state.allocator, .{
            .parse_error = core.parseError(
                "struct",
                state.index,
                "expected `u8` or `u16` as field type",
                .{ .expected = "u8 | u16", .kind = .syntactic },
            ),
        });
        return error.ParseFailed;
    }
    const type_token = type_result.ok.value;
    const type_lex = state.input[type_token.start..type_token.end];
    const ty: ast.FieldType = if (std.mem.eql(u8, type_lex, "u8"))
        .u8_t
    else if (std.mem.eql(u8, type_lex, "u16"))
        .u16_t
    else {
        try errors.append(state.allocator, .{
            .parse_error = core.parseError(
                "struct",
                type_token.start,
                "unknown field type (v0.1 supports `u8` and `u16` only)",
                .{ .expected = "u8 | u16", .actual = type_lex, .kind = .semantic },
            ),
        });
        return error.ParseFailed;
    };

    return .{
        .name = ast.Span.fromToken(name_token),
        .ty = ty,
        .offset = offset,
        .span = spanFrom(field_start, state.index),
    };
}

/// Recover from a malformed struct body — advance past the next
/// closing `}` (or to EOF) so the outer loop can pick up cleanly.
fn recoverToEndOfBlock(state: *core.ParseState) !void {
    while (state.index < state.input.len) {
        const b = state.input[state.index];
        state.advance(1);
        if (b == '}') return;
    }
}

// ---------- org directive ----------

fn parseOrgDecl(
    state: *core.ParseState,
    allocator: std.mem.Allocator,
    stmt_start: usize,
    statements: *std.ArrayList(ast.Statement),
    errors: *std.ArrayList(include.Diagnostic),
    consts: *expr.ConstantTable,
) !void {
    skipBlanksInLine(state);

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

    // Fold against the visible constants. Backward-`org` overlap
    // (E014) is a codegen-time check — the parser doesn't track
    // the emit position, so it just records the address here.
    const addr: ?u16 = blk: {
        const eval = expr.evalExpr(rhs, state.input, consts.*);
        switch (eval) {
            .ok => |v| break :blk v,
            .err => |d| {
                try errors.append(allocator, d);
                break :blk null;
            },
        }
    };

    try statements.append(allocator, .{ .org = .{
        .addr_expr = rhs,
        .addr = addr,
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

/// Lightweight byte peek without going through a lexer parser.
/// Used for one-char punctuation (`,`, `=`, …) in directive bodies
/// where round-tripping through knit is overkill.
fn peekByte(state: *core.ParseState, b: u8) bool {
    skipBlanksInLine(state);
    return state.index < state.input.len and state.input[state.index] == b;
}
