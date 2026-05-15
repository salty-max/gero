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
const vm = @import("../vm/vm.zig");

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

    var cond_stack = ConditionalStack.init(allocator);
    defer cond_stack.deinit();

    var state = core.ParseState.init(source, allocator);

    while (state.index < source.len) {
        try skipSeparatorsCapturingComments(&state, &statements, allocator);
        if (state.index >= source.len) break;
        try parseStatement(&state, allocator, &statements, &errors, &consts, &cond_stack);
    }

    // E019: every `ifdef` / `ifndef` must close before EOF. Flag
    // the **innermost** unclosed frame — that's the one whose
    // missing `endif` is the proximate cause.
    if (cond_stack.frames.items.len > 0) {
        const top = cond_stack.frames.items[cond_stack.frames.items.len - 1];
        try errors.append(allocator, .{
            .code = .unclosed_conditional,
            .parse_error = .{
                .parser = "asm",
                .index = top.open_span.start,
                .message = "`ifdef` / `ifndef` block left open at EOF (missing `endif`)",
                .expected = "endif",
                .actual = "",
                .kind = .semantic,
            },
        });
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

/// Per-parse conditional-assembly state. One frame is pushed per
/// open `ifdef` / `ifndef` block, popped by the matching `endif`.
/// `skipping` is true when the block's content should be discarded
/// (false condition, or inherited from an outer skipping frame).
pub const ConditionalStack = struct {
    frames: std.ArrayList(Frame),
    allocator: std.mem.Allocator,

    /// One open `ifdef` / `ifndef` block. `skipping` reflects the
    /// combined condition (its own predicate **or** an outer
    /// frame's suppression). `open_span` points at the opening
    /// directive so an unclosed-at-EOF diagnostic can locate it.
    pub const Frame = struct {
        skipping: bool,
        open_span: ast.Span,
    };

    /// Build an empty stack — caller owns the backing allocator.
    pub fn init(allocator: std.mem.Allocator) ConditionalStack {
        return .{ .frames = .empty, .allocator = allocator };
    }

    /// Release the backing list. Frames themselves carry no
    /// allocated state, so no per-frame cleanup is needed.
    pub fn deinit(self: *ConditionalStack) void {
        self.frames.deinit(self.allocator);
    }

    /// True when any frame on the stack is suppressing emission.
    pub fn isSkipping(self: ConditionalStack) bool {
        for (self.frames.items) |f| if (f.skipping) return true;
        return false;
    }

    /// Push a new frame on top of the stack.
    pub fn push(self: *ConditionalStack, frame: Frame) !void {
        try self.frames.append(self.allocator, frame);
    }

    /// Pop the topmost frame. Returns `null` when the stack is
    /// empty (caller surfaces an E018 unmatched-`endif` then).
    pub fn pop(self: *ConditionalStack) ?Frame {
        if (self.frames.items.len == 0) return null;
        return self.frames.pop();
    }
};

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
        .instruction => |i| {
            for (i.operands) |op| switch (op) {
                .immediate => |e| ast.freeExpr(allocator, e),
                .addr_expr => |a| ast.freeExpr(allocator, a.expr),
                .indexed => |idx| ast.freeExpr(allocator, idx.addr),
                .reg_offset => |r| ast.freeExpr(allocator, r.offset),
                .register, .indirect, .addr_lit, .sym_ref, .label_ref, .cast => {},
            };
            allocator.free(i.operands);
        },
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
    cond_stack: *ConditionalStack,
) !void {
    const stmt_start = state.index;

    // Conditional-assembly directives are always processed, even
    // while in skip-mode — nested `ifdef` inside a false outer
    // branch must still track its own open/close so the right
    // `endif` pops the right frame.
    if (consumeKeyword(state, "ifndef")) {
        return parseIfDirective(state, allocator, stmt_start, statements, errors, consts, cond_stack, .ifndef);
    }
    if (consumeKeyword(state, "ifdef")) {
        return parseIfDirective(state, allocator, stmt_start, statements, errors, consts, cond_stack, .ifdef);
    }
    if (consumeKeyword(state, "endif")) {
        return parseEndifDirective(state, allocator, stmt_start, statements, errors, cond_stack);
    }

    // Skip-mode: everything inside a false `ifdef` / `ifndef`
    // branch is consumed without emitting AST or diagnostics. The
    // parser still advances past it so token-level position
    // tracking stays consistent.
    if (cond_stack.isSkipping()) {
        try recoverToNewline(state);
        return;
    }

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
    if (consumeKeyword(state, "bank")) {
        return parseBankSwitch(state, allocator, stmt_start, statements, errors, consts);
    }
    if (consumeKeyword(state, "sram_banks")) {
        return parseSramBanksDecl(state, allocator, stmt_start, statements, errors, consts);
    }

    // Label: `ident ":"`. The colon distinguishes a label from an
    // instruction line that happens to start with an identifier.
    if (try tryParseLabel(state, allocator, stmt_start, statements)) return;

    // Instruction: any other identifier in statement position is
    // a mnemonic followed by zero or more operands.
    if (try tryParseInstruction(state, allocator, stmt_start, statements, errors)) return;

    // Anything else: record the line as an `unknown` statement,
    // emit a diagnostic, and recover to the next newline.
    try recordUnknown(state, allocator, stmt_start, statements, errors);
}

// ---------- conditional assembly: ifdef / ifndef / endif ----------

/// Parse `ifdef NAME` or `ifndef NAME`. Side effect: pushes a frame
/// onto `cond_stack` whose `skipping` reflects the current ConstantTable
/// lookup result. Nested under an already-skipping outer frame, the
/// new frame is also `skipping` (so we don't accidentally re-enable
/// emission inside a dead block).
fn parseIfDirective(
    state: *core.ParseState,
    allocator: std.mem.Allocator,
    stmt_start: usize,
    statements: *std.ArrayList(ast.Statement),
    errors: *std.ArrayList(include.Diagnostic),
    consts: *expr.ConstantTable,
    cond_stack: *ConditionalStack,
    kind: ast.CondDirective.Kind,
) !void {
    skipBlanksInLine(state);
    const name_start: u32 = u32At(state.index);
    const ident_result = lexer.identP.parseFn(state);
    if (ident_result != .ok) {
        try errors.append(allocator, .{
            .parse_error = .{
                .parser = "asm",
                .index = name_start,
                .message = "expected identifier after `ifdef` / `ifndef`",
                .expected = "identifier",
                .actual = "",
                .kind = .syntactic,
            },
        });
        try recoverToNewline(state);
        // Push a frame anyway so the matching `endif` doesn't
        // surface a spurious E018.
        try cond_stack.push(.{
            .skipping = true,
            .open_span = spanFrom(stmt_start, state.index),
        });
        return;
    }
    const ident_token = ident_result.ok.value;
    const name_span: ast.Span = .{ .start = name_start, .end = ident_token.end };
    const name_lex = state.input[name_start..ident_token.end];

    const outer_skipping = cond_stack.isSkipping();
    const is_defined = consts.get(name_lex) != null;
    const this_skipping = switch (kind) {
        .ifndef => is_defined,
        .ifdef => !is_defined,
        // safety: caller passes ifdef/ifndef only — endif goes through
        //         parseEndifDirective, never reaches this switch.
        .endif => unreachable,
    };

    try cond_stack.push(.{
        .skipping = outer_skipping or this_skipping,
        .open_span = spanFrom(stmt_start, state.index),
    });

    try statements.append(allocator, .{ .cond_directive = .{
        .kind = kind,
        .name = name_span,
        .span = spanFrom(stmt_start, state.index),
    } });

    try recoverToNewline(state);
}

/// Parse `endif`. Pops the conditional stack; emits E018 if the
/// stack was empty (no matching open).
fn parseEndifDirective(
    state: *core.ParseState,
    allocator: std.mem.Allocator,
    stmt_start: usize,
    statements: *std.ArrayList(ast.Statement),
    errors: *std.ArrayList(include.Diagnostic),
    cond_stack: *ConditionalStack,
) !void {
    if (cond_stack.pop() == null) {
        try errors.append(allocator, .{
            .code = .unmatched_endif,
            .parse_error = .{
                .parser = "asm",
                .index = u32At(stmt_start),
                .message = "`endif` without a matching `ifdef` / `ifndef`",
                .expected = "ifdef or ifndef",
                .actual = "endif",
                .kind = .semantic,
            },
        });
    }
    try statements.append(allocator, .{ .cond_directive = .{
        .kind = .endif,
        .name = .{ .start = u32At(state.index), .end = u32At(state.index) },
        .span = spanFrom(stmt_start, state.index),
    } });
    try recoverToNewline(state);
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
    // Local label: `.foo:` — the leading `.` is part of the name
    // span. Codegen mangles to `parent.foo` against the most
    // recent global label.
    const has_dot = state.index < state.input.len and state.input[state.index] == '.';
    const name_start: u32 = u32At(state.index);
    if (has_dot) state.advance(1);
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
    const name_span: ast.Span = .{ .start = name_start, .end = ident_token.end };
    try statements.append(allocator, .{ .label = .{
        .name = name_span,
        .span = ast.Span.join(name_span, ast.Span.fromToken(colon_token)),
    } });
    return true;
}

fn u32At(i: usize) u32 {
    // @as: fused-source byte offsets fit in u32 (max_file_size = 16 MiB).
    return @as(u32, @intCast(i));
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
                    .code = .operand_type_mismatch,
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
        // The leading byte was `"` — anything past that is a
        // malformed string literal (unterminated, bad escape).
        // Surface the lexer's specific error with its E-code.
        try errors.append(state.allocator, .{
            .code = include.ErrorCode.fromLexerMessage(r.err.message),
            .parse_error = r.err,
        });
        return error.ParseFailed;
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
    const ty: ast.FieldType = std.meta.stringToEnum(ast.FieldType, type_lex) orelse {
        try errors.append(state.allocator, .{
            .code = .operand_type_mismatch,
            .parse_error = core.parseError(
                "struct",
                type_token.start,
                "unknown field type (only `u8` and `u16` are supported)",
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

// ---------- bank N / sram_banks N ----------

/// Parse a folded u8 immediately following a keyword. Used by
/// `bank N` and `sram_banks N`. Frees the expression tree before
/// returning since the value is the only thing the AST needs.
/// Returns `null` on parse / eval failure (the diagnostic is
/// already in `errors`).
fn parseFoldedU8(
    state: *core.ParseState,
    allocator: std.mem.Allocator,
    errors: *std.ArrayList(include.Diagnostic),
    consts: *expr.ConstantTable,
) !?u8 {
    skipBlanksInLine(state);
    const rhs = expr.parseExpression(state, allocator, errors) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseFailed => return null,
    };
    defer ast.freeExpr(allocator, rhs);

    const result = expr.evalExpr(rhs, state.input, consts.*);
    switch (result) {
        .ok => |v| {
            if (v > 0xFF) {
                try errors.append(allocator, .{
                    .code = .hex_out_of_range,
                    .parse_error = core.parseError(
                        "directive",
                        rhs.span().start,
                        "value must fit in u8 (0..255)",
                        .{ .expected = "u8", .kind = .semantic },
                    ),
                });
                return null;
            }
            // @as: bounded by the check above — guaranteed to fit u8.
            return @as(u8, @intCast(v));
        },
        .err => |d| {
            try errors.append(allocator, d);
            return null;
        },
    }
}

fn parseBankSwitch(
    state: *core.ParseState,
    allocator: std.mem.Allocator,
    stmt_start: usize,
    statements: *std.ArrayList(ast.Statement),
    errors: *std.ArrayList(include.Diagnostic),
    consts: *expr.ConstantTable,
) !void {
    const index = try parseFoldedU8(state, allocator, errors, consts);
    try statements.append(allocator, .{ .bank_switch = .{
        .index = index,
        .span = spanFrom(stmt_start, state.index),
    } });
}

fn parseSramBanksDecl(
    state: *core.ParseState,
    allocator: std.mem.Allocator,
    stmt_start: usize,
    statements: *std.ArrayList(ast.Statement),
    errors: *std.ArrayList(include.Diagnostic),
    consts: *expr.ConstantTable,
) !void {
    const count = try parseFoldedU8(state, allocator, errors, consts);
    try statements.append(allocator, .{ .sram_banks_decl = .{
        .count = count,
        .span = spanFrom(stmt_start, state.index),
    } });
}

// ---------- instructions ----------

/// Resolve an identifier lexeme to a `vm.Register` if it names
/// one. Returns `null` for anything else (which the operand
/// parser then routes to `.label_ref`). The `vm.Register` enum
/// is the canonical name → operand-index map for the ISA, so we
/// reuse it directly here instead of duplicating the table.
fn parseRegister(name: []const u8) ?vm.Register {
    return std.meta.stringToEnum(vm.Register, name);
}

fn tryParseInstruction(
    state: *core.ParseState,
    allocator: std.mem.Allocator,
    stmt_start: usize,
    statements: *std.ArrayList(ast.Statement),
    errors: *std.ArrayList(include.Diagnostic),
) !bool {
    const saved = state.index;
    skipBlanksInLine(state);

    // Mnemonic must be a bare identifier in statement position.
    const mnemonic_result = lexer.identP.parseFn(state);
    if (mnemonic_result != .ok) {
        state.index = saved;
        return false;
    }
    const mnemonic_token = mnemonic_result.ok.value;

    // Operands. Newline / EOF / `;`-comment ends the operand list.
    var operands: std.ArrayList(ast.Operand) = .empty;
    errdefer cleanupOperands(allocator, &operands);

    skipBlanksInLine(state);
    if (!atStatementEnd(state)) {
        while (true) {
            const op = parseOperand(state, allocator, errors) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ParseFailed => {
                    cleanupOperands(allocator, &operands);
                    try recoverToNewline(state);
                    try statements.append(allocator, .{ .unknown = .{
                        .span = spanFrom(stmt_start, state.index),
                    } });
                    return true;
                },
            };
            try operands.append(allocator, op);

            skipBlanksInLine(state);
            if (peekByte(state, ',')) {
                state.advance(1);
                skipBlanksInLine(state);
                continue;
            }
            break;
        }
    }

    const owned = try operands.toOwnedSlice(allocator);
    try statements.append(allocator, .{ .instruction = .{
        .mnemonic = ast.Span.fromToken(mnemonic_token),
        .operands = owned,
        .span = spanFrom(stmt_start, state.index),
    } });
    return true;
}

/// True if the cursor sits on a statement terminator (newline,
/// EOF, or a `;`-comment start). Used to recognize zero-operand
/// instructions like `hlt` without parsing further.
fn atStatementEnd(state: *core.ParseState) bool {
    if (state.index >= state.input.len) return true;
    const b = state.input[state.index];
    return b == '\n' or b == ';';
}

fn parseOperand(
    state: *core.ParseState,
    allocator: std.mem.Allocator,
    errors: *std.ArrayList(include.Diagnostic),
) expr.ParseError!ast.Operand {
    skipBlanksInLine(state);
    const start = state.index;

    if (state.index >= state.input.len) {
        try errors.append(state.allocator, .{
            .parse_error = core.parseError(
                "operand",
                state.index,
                "expected an operand",
                .{ .expected = "register / immediate / address / label", .kind = .syntactic },
            ),
        });
        return error.ParseFailed;
    }

    const b = state.input[state.index];

    // `[...]` — either indirect (single register inside) or
    // indexed (`<addr-expr> + <reg>` inside). Distinguished by
    // parsing the inner expression then inspecting its shape.
    if (b == '[') {
        return parseBracketOperand(state, allocator, errors, start);
    }

    // `&FFFF` literal OR `&[<expr>]` compile-time address expr
    // (form a, asm spec §3.4). The trailing `[` after `&` is the
    // discriminator.
    if (b == '&') {
        if (state.index + 1 < state.input.len and state.input[state.index + 1] == '[') {
            return parseAddrExprOperand(state, allocator, errors, start);
        }
        const r = lexer.addrP.parseFn(state);
        if (r == .ok) {
            const tok = r.ok.value;
            return .{ .addr_lit = .{
                .value = tok.value,
                .span = .{ .start = tok.start, .end = tok.end },
            } };
        }
        try errors.append(state.allocator, .{
            .parse_error = core.parseError(
                "operand",
                state.index,
                "expected `&FFFF` address literal or `&[expr]` address expression",
                .{ .expected = "address operand", .kind = .syntactic },
            ),
        });
        return error.ParseFailed;
    }

    // `<Type> @sym.field` — cast sugar (asm spec §3.4). The
    // leading `<` discriminates from the bitwise-`<` operator
    // (which never appears at operand-start position).
    if (b == '<') {
        return parseCastOperand(state, errors, start);
    }

    // `@sym` — symbol reference.
    if (b == '@') {
        const r = lexer.symRefP.parseFn(state);
        if (r == .ok) {
            const tok = r.ok.value;
            return .{ .sym_ref = .{
                .span = .{ .start = tok.start, .end = tok.end },
            } };
        }
        try errors.append(state.allocator, .{
            .parse_error = core.parseError(
                "operand",
                state.index,
                "expected `@sym` symbol reference",
                .{ .expected = "symbol reference", .kind = .syntactic },
            ),
        });
        return error.ParseFailed;
    }

    // Local-label ref: `.foo` (codegen mangles via parent label).
    if (b == '.') {
        const dot_start: u32 = u32At(state.index);
        state.advance(1);
        const r = lexer.identP.parseFn(state);
        if (r != .ok) {
            try errors.append(state.allocator, .{
                .parse_error = core.parseError(
                    "operand",
                    state.index,
                    "expected identifier after `.` for a local-label reference",
                    .{ .expected = "local label name", .kind = .syntactic },
                ),
            });
            return error.ParseFailed;
        }
        const tok = r.ok.value;
        return .{ .label_ref = .{ .span = .{ .start = dot_start, .end = tok.end } } };
    }

    // Identifier — either a register name or a label/const reference.
    if ((b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z') or b == '_') {
        const r = lexer.identP.parseFn(state);
        if (r != .ok) {
            try errors.append(state.allocator, .{
                .parse_error = core.parseError(
                    "operand",
                    state.index,
                    "expected an identifier",
                    .{ .expected = "register or label name", .kind = .syntactic },
                ),
            });
            return error.ParseFailed;
        }
        const tok = r.ok.value;
        const lex = state.input[tok.start..tok.end];
        if (parseRegister(lex)) |id| {
            return .{ .register = .{ .id = id, .span = ast.Span.fromToken(tok) } };
        }
        return .{ .label_ref = .{ .span = ast.Span.fromToken(tok) } };
    }

    // Everything else — defer to the expression parser. Hex
    // literals, char literals, parenthesized expressions, unary
    // operators all start here. The result is wrapped as an
    // `immediate` operand.
    const e = try expr.parseExpression(state, allocator, errors);
    return .{ .immediate = e };
}

/// `[ ... ]` — either indirect or indexed. The discriminator is
/// the inner shape:
///   - single register identifier → indirect
///   - `<expr> + <reg>` → indexed (form b)
///
/// We parse the inner content as one expression. If the top-level
/// node is `binary(+, lhs, rhs)` and `rhs` is a bare ident that
/// names a register, it's indexed. If the inner content is just
/// a bare ident naming a register, it's indirect. Anything else
/// is a structured error.
fn parseBracketOperand(
    state: *core.ParseState,
    allocator: std.mem.Allocator,
    errors: *std.ArrayList(include.Diagnostic),
    start: usize,
) expr.ParseError!ast.Operand {
    state.advance(1); // consume `[`
    skipBlanksInLine(state);

    const inner = try expr.parseExpression(state, allocator, errors);

    skipBlanksInLine(state);
    if (!peekByte(state, ']')) {
        try errors.append(state.allocator, .{
            .parse_error = core.parseError(
                "operand",
                state.index,
                "expected `]` to close indirect or indexed operand",
                .{ .expected = "]", .kind = .syntactic },
            ),
        });
        ast.freeExpr(allocator, inner);
        return error.ParseFailed;
    }
    state.advance(1);

    // Indirect: inner is a single register ident.
    if (inner.* == .ident) {
        const lex = state.input[inner.ident.span.start..inner.ident.span.end];
        if (parseRegister(lex)) |id| {
            const reg = ast.RegisterRef{ .id = id, .span = inner.ident.span };
            ast.freeExpr(allocator, inner);
            return .{ .indirect = .{
                .reg = reg,
                .span = spanFrom(start, state.index),
            } };
        }
    }

    // Register-relative offset: `binary(+|-, reg_lhs, offset_rhs)`.
    // The lhs is a register identifier, the rhs is a compile-time
    // offset expression. Stored as `RegOffset` so codegen emits
    // the 0x1C / 0x1D opcodes with a signed byte. Distinguishes
    // from `indexed` by which side of the `+` holds the register.
    if (inner.* == .binary and (inner.binary.op == .add or inner.binary.op == .sub)) {
        const lhs = inner.binary.lhs;
        if (lhs.* == .ident) {
            const lex = state.input[lhs.ident.span.start..lhs.ident.span.end];
            if (parseRegister(lex)) |id| {
                const rhs_owned = inner.binary.rhs;
                const reg = ast.RegisterRef{ .id = id, .span = lhs.ident.span };
                // For `[reg - expr]` wrap the RHS in unary negate so
                // codegen folds the right signed value naturally.
                const offset_expr: *ast.Expr = if (inner.binary.op == .sub) blk: {
                    const negated = try allocator.create(ast.Expr);
                    negated.* = .{ .unary = .{
                        .op = .neg,
                        .operand = rhs_owned,
                        .span = rhs_owned.span(),
                    } };
                    break :blk negated;
                } else rhs_owned;
                ast.freeExpr(allocator, lhs);
                allocator.destroy(inner); // drop the outer binary; rhs / negated survives
                return .{ .reg_offset = .{
                    .reg = reg,
                    .offset = offset_expr,
                    .span = spanFrom(start, state.index),
                } };
            }
        }
    }

    // Indexed: top-level node is `binary(+, lhs, rhs)` where rhs
    // is a register ident.
    if (inner.* == .binary and inner.binary.op == .add) {
        const rhs = inner.binary.rhs;
        if (rhs.* == .ident) {
            const lex = state.input[rhs.ident.span.start..rhs.ident.span.end];
            if (parseRegister(lex)) |id| {
                const lhs = inner.binary.lhs;
                const reg = ast.RegisterRef{ .id = id, .span = rhs.ident.span };
                // Pre-fold deferred to codegen — the parser
                // doesn't have ConstantTable visibility this
                // deep, and the common case is forward symbol
                // refs anyway.
                ast.freeExpr(allocator, rhs);
                allocator.destroy(inner); // drop the outer binary; lhs survives
                return .{ .indexed = .{
                    .addr = lhs,
                    .addr_value = null,
                    .reg = reg,
                    .span = spanFrom(start, state.index),
                } };
            }
        }
    }

    // Inner doesn't match either shape — surface a diagnostic
    // and let the outer recovery handle it.
    try errors.append(state.allocator, .{
        .code = .operand_type_mismatch,
        .parse_error = core.parseError(
            "operand",
            inner.span().start,
            "expected `[reg]` indirect or `[addr + reg]` indexed addressing",
            .{ .expected = "register or addr-expr + register", .kind = .semantic },
        ),
    });
    ast.freeExpr(allocator, inner);
    return error.ParseFailed;
}

/// `&[<expr>]` — compile-time address expression (form a). The
/// expression follows §1.7 operator rules; if every symbol it
/// references is resolved at parse time, the result is pre-folded
/// for codegen. Otherwise codegen retries against the symbol table.
fn parseAddrExprOperand(
    state: *core.ParseState,
    allocator: std.mem.Allocator,
    errors: *std.ArrayList(include.Diagnostic),
    start: usize,
) expr.ParseError!ast.Operand {
    state.advance(2); // consume `&[`
    skipBlanksInLine(state);

    const inner = try expr.parseExpression(state, allocator, errors);

    skipBlanksInLine(state);
    if (!peekByte(state, ']')) {
        try errors.append(state.allocator, .{
            .parse_error = core.parseError(
                "operand",
                state.index,
                "expected `]` to close `&[...]` address expression",
                .{ .expected = "]", .kind = .syntactic },
            ),
        });
        ast.freeExpr(allocator, inner);
        return error.ParseFailed;
    }
    state.advance(1);

    return .{
        .addr_expr = .{
            .expr = inner,
            // Pre-fold deferred to codegen; the parser doesn't have
            // a ConstantTable handle this deep, and forward symbol
            // refs are the common case here anyway.
            .value = null,
            .span = spanFrom(start, state.index),
        },
    };
}

/// `<Type> @sym.field` — cast sugar (asm spec §3.4). Parsed in
/// raw form; codegen resolves `Type.field` against the struct
/// registry and `@sym` against the symbol table, then emits the
/// same bytes as the desugared `&[@sym + Type.field]`.
fn parseCastOperand(
    state: *core.ParseState,
    errors: *std.ArrayList(include.Diagnostic),
    start: usize,
) expr.ParseError!ast.Operand {
    state.advance(1); // consume `<`
    skipBlanksInLine(state);

    // Type name.
    const type_result = lexer.identP.parseFn(state);
    if (type_result != .ok) {
        try errors.append(state.allocator, .{
            .parse_error = core.parseError(
                "operand",
                state.index,
                "expected struct type name after `<`",
                .{ .expected = "identifier", .kind = .syntactic },
            ),
        });
        return error.ParseFailed;
    }
    const type_token = type_result.ok.value;

    skipBlanksInLine(state);
    if (!peekByte(state, '>')) {
        try errors.append(state.allocator, .{
            .parse_error = core.parseError(
                "operand",
                state.index,
                "expected `>` to close cast type",
                .{ .expected = ">", .kind = .syntactic },
            ),
        });
        return error.ParseFailed;
    }
    state.advance(1);

    skipBlanksInLine(state);

    // `@sym`.
    if (!peekByte(state, '@')) {
        try errors.append(state.allocator, .{
            .parse_error = core.parseError(
                "operand",
                state.index,
                "expected `@sym` after `<Type>` cast",
                .{ .expected = "@sym", .kind = .syntactic },
            ),
        });
        return error.ParseFailed;
    }
    const sym_result = lexer.symRefP.parseFn(state);
    if (sym_result != .ok) {
        try errors.append(state.allocator, .{
            .parse_error = core.parseError(
                "operand",
                state.index,
                "expected `@sym` after `<Type>` cast",
                .{ .expected = "symbol reference", .kind = .syntactic },
            ),
        });
        return error.ParseFailed;
    }
    const sym_token = sym_result.ok.value;

    // `.field`.
    if (!peekByte(state, '.')) {
        try errors.append(state.allocator, .{
            .parse_error = core.parseError(
                "operand",
                state.index,
                "expected `.field` after `<Type> @sym`",
                .{ .expected = ".", .kind = .syntactic },
            ),
        });
        return error.ParseFailed;
    }
    state.advance(1);

    const field_result = lexer.identP.parseFn(state);
    if (field_result != .ok) {
        try errors.append(state.allocator, .{
            .parse_error = core.parseError(
                "operand",
                state.index,
                "expected field name after `.`",
                .{ .expected = "identifier", .kind = .syntactic },
            ),
        });
        return error.ParseFailed;
    }
    const field_token = field_result.ok.value;

    return .{ .cast = .{
        .type_name = ast.Span.fromToken(type_token),
        .sym_ref = .{ .span = ast.Span.fromToken(sym_token) },
        .field_name = ast.Span.fromToken(field_token),
        .span = spanFrom(start, state.index),
    } };
}

fn cleanupOperands(allocator: std.mem.Allocator, operands: *std.ArrayList(ast.Operand)) void {
    for (operands.items) |op| switch (op) {
        .immediate => |e| ast.freeExpr(allocator, e),
        .addr_expr => |a| ast.freeExpr(allocator, a.expr),
        .indexed => |idx| ast.freeExpr(allocator, idx.addr),
        .reg_offset => |r| ast.freeExpr(allocator, r.offset),
        .register, .indirect, .addr_lit, .sym_ref, .label_ref, .cast => {},
    };
    operands.deinit(allocator);
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
            "unrecognized statement",
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
        } else {
            // Stop at `;` so the top-level `skipSeparatorsCapturing
            // Comments` can capture trailing comments as first-class
            // `Comment` statements. `atStatementEnd` recognizes `;`
            // as a statement terminator, so the rest of intra-line
            // parsing handles the same shape as today.
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

/// Same as `skipSeparators` but captures every `;` comment as a
/// first-class `Statement.comment` and appends it to the program
/// in parse order. Trailing comments on a statement line surface
/// as standalone `Comment` statements following the statement
/// they trailed — the pretty-printer uses span proximity in the
/// source to recover the "trailing vs standalone" distinction.
fn skipSeparatorsCapturingComments(
    state: *core.ParseState,
    statements: *std.ArrayList(ast.Statement),
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!void {
    while (state.index < state.input.len) {
        const b = state.input[state.index];
        if (b == ' ' or b == '\t' or b == '\n') {
            state.advance(1);
        } else if (b == ';') {
            const start = state.index;
            while (state.index < state.input.len and state.input[state.index] != '\n') state.advance(1);
            try statements.append(allocator, .{
                .comment = .{ .span = spanFrom(start, state.index) },
            });
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
