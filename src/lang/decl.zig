/// Declaration parsers — `let`, `const`, `def`, `class`, `struct`,
/// `enum`, `use`, plus the shared `parseParamList` (used by both
/// `def` and `lambda`). Annotations land here too via
/// `takePendingAnnotations` from `parser.zig`.
///
/// Imports `Parser` + `ParserError` from `parser.zig`; delegates
/// to `expr`, `pattern`, `type_ann`, `annotation` for sub-shapes,
/// and to `parser_mod.parseStatement` for function bodies.
const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const expr_mod = @import("expr.zig");
const pattern_mod = @import("pattern.zig");
const type_mod = @import("type_ann.zig");
const annotation_mod = @import("annotation.zig");

const Parser = parser_mod.Parser;
const ParserError = parser_mod.ParserError;

// ---------- let / const ----------

/// `let pattern[: T] = expr` / `let name: T` (uninit form).
pub fn parseLetDecl(p: *Parser, is_local: bool) ParserError!ast.Statement {
    const let_tok = p.peek();
    p.pos += 1;
    const start = let_tok.start;

    const annotations = try parser_mod.takePendingAnnotations(p);
    errdefer parser_mod.freeAnnSlice(p.allocator, annotations);

    const pattern = try pattern_mod.parsePattern(p);

    var type_ann: ?*ast.TypeAnn = null;
    if (p.accept(.colon)) |_| {
        type_ann = try type_mod.parseTypeAnn(p);
    }

    var init: ?*ast.Expr = null;
    if (p.accept(.equals)) |_| {
        init = try expr_mod.parseExpression(p, 0);
    } else if (type_ann == null) {
        try p.recordError(
            "expected `=` or `: T` after `let` binding",
            "= or : T",
        );
    }

    const end = if (init) |e| e.span().end else if (type_ann) |t| t.span().end else pattern.span().end;
    try p.requireStatementBoundary();
    return .{ .let_decl = .{
        .annotations = annotations,
        .pattern = pattern,
        .type_ann = type_ann,
        .init = init,
        .is_local = is_local,
        .span = .{ .start = start, .end = end },
    } };
}

/// `const NAME[: T] = expr`.
pub fn parseConstDecl(p: *Parser, is_local: bool) ParserError!ast.Statement {
    const const_tok = p.peek();
    p.pos += 1;
    const start = const_tok.start;

    const annotations = try parser_mod.takePendingAnnotations(p);
    errdefer parser_mod.freeAnnSlice(p.allocator, annotations);

    const name_tok = try p.expect(.ident, "identifier");
    const name_span = ast.Span.fromToken(name_tok);

    var type_ann: ?*ast.TypeAnn = null;
    if (p.accept(.colon)) |_| {
        type_ann = try type_mod.parseTypeAnn(p);
    }
    _ = try p.expect(.equals, "=");

    const init = try expr_mod.parseExpression(p, 0);
    const end = init.span().end;
    try p.requireStatementBoundary();

    return .{ .const_decl = .{
        .annotations = annotations,
        .name = name_span,
        .type_ann = type_ann,
        .init = init,
        .is_local = is_local,
        .span = .{ .start = start, .end = end },
    } };
}

// ---------- def ----------

/// `def name(params) [-> T] body end` — top-level wrapper.
pub fn parseDefDecl(p: *Parser, is_local: bool) ParserError!ast.Statement {
    const decl = try parseDefDeclInner(p, is_local);
    return .{ .def_decl = decl };
}

/// Inner form used directly by class-method parsing.
pub fn parseDefDeclInner(p: *Parser, is_local: bool) ParserError!ast.DefDecl {
    const def_tok = p.peek();
    p.pos += 1;
    const start = def_tok.start;

    const annotations = try parser_mod.takePendingAnnotations(p);
    errdefer parser_mod.freeAnnSlice(p.allocator, annotations);

    const name_tok = try p.expect(.ident, "function name");
    const name_span = ast.Span.fromToken(name_tok);

    _ = try p.expect(.lparen, "(");
    const params = try parseParamList(p);
    errdefer freeParams(p.allocator, params);

    var ret_type: ?*ast.TypeAnn = null;
    if (p.accept(.arrow)) |_| {
        ret_type = try type_mod.parseTypeAnn(p);
    }
    errdefer if (ret_type) |r| ast.freeTypeAnn(p.allocator, r);

    // `@abstract` on a method (§3.7.6) declares the signature
    // without a body — subclasses must implement it. Skip the body
    // parse + `end` expectation in that case.
    const is_abstract = hasAnnotationNamed(p, annotations, "abstract");

    var body: std.ArrayList(ast.Statement) = .empty;
    errdefer parser_mod.cleanupStatements(p.allocator, &body);
    var end_byte: u32 = if (ret_type) |r| r.span().end else p.peek().start;

    if (!is_abstract) {
        p.skipNewlines();
        while (!p.atEnd() and !p.check(.kw_end)) {
            try parser_mod.parseStatement(p, &body);
            p.skipNewlines();
        }
        const end_tok = try p.expect(.kw_end, "end");
        end_byte = end_tok.end;
    }
    try p.requireStatementBoundary();

    return .{
        .annotations = annotations,
        .name = name_span,
        .params = params,
        .ret_type = ret_type,
        .body = try body.toOwnedSlice(p.allocator),
        .is_local = is_local,
        .span = .{ .start = start, .end = end_byte },
    };
}

/// True when `annotations` contains an entry whose name matches
/// `name` exactly. Used by `parseDefDeclInner` for `@abstract`.
fn hasAnnotationNamed(
    p: *const Parser,
    annotations: []const ast.Annotation,
    name: []const u8,
) bool {
    for (annotations) |a| {
        const lex = p.source[a.name.start..a.name.end];
        if (std.mem.eql(u8, lex, name)) return true;
    }
    return false;
}

/// Parameter list following the opening `(`. Consumes the closing
/// `)`. Both `def` and `lambda` use this. Newlines are tolerated
/// after `(`, after each `,`, and before `)` so long parameter
/// lists can wrap across lines.
pub fn parseParamList(p: *Parser) ParserError![]ast.Param {
    var params: std.ArrayList(ast.Param) = .empty;
    errdefer {
        freeParams(p.allocator, params.items);
        params.deinit(p.allocator);
    }

    p.skipNewlines();
    if (p.check(.rparen)) {
        _ = p.accept(.rparen);
        return try params.toOwnedSlice(p.allocator);
    }

    while (true) {
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
            type_ann = try type_mod.parseTypeAnn(p);
        }

        const param_end: u32 = if (type_ann) |t| t.span().end else name_span.end;
        try params.append(p.allocator, .{
            .name = name_span,
            .type_ann = type_ann,
            .span = .{ .start = name_span.start, .end = param_end },
        });

        if (p.accept(.comma) == null) break;
        p.skipNewlines();
        if (p.check(.rparen)) break; // trailing comma
    }

    p.skipNewlines();
    _ = try p.expect(.rparen, ")");
    return try params.toOwnedSlice(p.allocator);
}

/// Release a parameter slice (handles the nested type-annotation
/// allocations).
pub fn freeParams(allocator: std.mem.Allocator, params: []ast.Param) void {
    for (params) |p| if (p.type_ann) |t| ast.freeTypeAnn(allocator, t);
    allocator.free(params);
}

// ---------- class ----------

/// `class Name [extends Parent] ... end`. The body starts after
/// the optional `extends` clause; fields and methods alternate
/// freely; `end` closes the class. Consistent with `struct`, `def`,
/// and `if` / `while` block delimiters (§6, §3.7.6).
pub fn parseClassDecl(p: *Parser, is_local: bool) ParserError!ast.Statement {
    const class_tok = p.peek();
    p.pos += 1;
    const start = class_tok.start;

    const annotations = try parser_mod.takePendingAnnotations(p);
    errdefer parser_mod.freeAnnSlice(p.allocator, annotations);

    const name_tok = try p.expect(.ident, "class name");
    const name_span = ast.Span.fromToken(name_tok);

    var extends: ?ast.Span = null;
    if (p.accept(.kw_extends)) |_| {
        const parent_tok = try p.expect(.ident, "parent class name");
        extends = ast.Span.fromToken(parent_tok);
    }

    p.skipNewlines();

    var fields: std.ArrayList(ast.ClassField) = .empty;
    errdefer cleanupClassFields(p.allocator, &fields);
    var methods: std.ArrayList(ast.DefDecl) = .empty;
    errdefer cleanupMethods(p.allocator, &methods);

    while (!p.atEnd() and !p.check(.kw_end)) {
        // Accumulate annotations inside the class body, same as
        // file-level. They attach to the next field or method.
        while (p.check(.annotation)) {
            const ann = try annotation_mod.parseAnnotation(p);
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
            .kw_end => break,
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

    const close_tok = try p.expect(.kw_end, "end");
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
    const let_tok = p.peek();
    p.pos += 1;

    const annotations = try parser_mod.takePendingAnnotations(p);
    errdefer parser_mod.freeAnnSlice(p.allocator, annotations);

    const name_tok = try p.expect(.ident, "field name");
    const name_span = ast.Span.fromToken(name_tok);

    var type_ann: ?*ast.TypeAnn = null;
    if (p.accept(.colon)) |_| {
        type_ann = try type_mod.parseTypeAnn(p);
    }

    var init: ?*ast.Expr = null;
    var end_idx: u32 = if (type_ann) |t| t.span().end else name_span.end;
    if (p.accept(.equals)) |_| {
        const e = try expr_mod.parseExpression(p, 0);
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
        parser_mod.freeAnnSlice(allocator, f.annotations);
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
        parser_mod.freeAnnSlice(allocator, m.annotations);
        freeParams(allocator, m.params);
        if (m.ret_type) |r| ast.freeTypeAnn(allocator, r);
        for (m.body) |*s| ast.freeStatement(allocator, s);
        allocator.free(m.body);
    }
    methods.deinit(allocator);
}

// ---------- struct ----------

/// `struct Name field: T ... end` — POD declaration.
pub fn parseStructDecl(p: *Parser, is_local: bool) ParserError!ast.Statement {
    const struct_tok = p.peek();
    p.pos += 1;
    const start = struct_tok.start;

    const annotations = try parser_mod.takePendingAnnotations(p);
    errdefer parser_mod.freeAnnSlice(p.allocator, annotations);

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
        const ftype = try type_mod.parseTypeAnn(p);
        const fend = ftype.span().end;
        try fields.append(p.allocator, .{
            .name = ast.Span.fromToken(fname_tok),
            .type_ann = ftype,
            .span = .{ .start = fname_tok.start, .end = fend },
        });
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

// ---------- enum ----------

/// `enum Name case Variant[(payload)] ... end`.
pub fn parseEnumDecl(p: *Parser, is_local: bool) ParserError!ast.Statement {
    const enum_tok = p.peek();
    p.pos += 1;
    const start = enum_tok.start;

    const annotations = try parser_mod.takePendingAnnotations(p);
    errdefer parser_mod.freeAnnSlice(p.allocator, annotations);

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
                    const tok0 = p.peek();
                    const tok1 = p.peekAt(1);
                    if (tok0.kind == .ident and tok1.kind == .colon) {
                        const fname_tok = p.peek();
                        p.pos += 2;
                        const ftype = try type_mod.parseTypeAnn(p);
                        try payload.append(p.allocator, .{
                            .name = ast.Span.fromToken(fname_tok),
                            .type_ann = ftype,
                            .span = .{ .start = fname_tok.start, .end = ftype.span().end },
                        });
                    } else {
                        const ftype = try type_mod.parseTypeAnn(p);
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

// ---------- use ----------

/// `use module [as alias]`, `use a, b from module`,
/// `use "./path"`.
pub fn parseUseDecl(p: *Parser, is_local: bool) ParserError!ast.Statement {
    const use_tok = p.peek();
    p.pos += 1;
    const start = use_tok.start;

    var items: std.ArrayList(ast.UseItem) = .empty;
    errdefer items.deinit(p.allocator);

    var module_span: ast.Span = undefined;
    var quoted_path = false;
    var alias: ?ast.Span = null;

    const start_pos = p.pos;
    if (try lookaheadHasFromClause(p)) {
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

fn parseUseModuleSpec(p: *Parser, quoted: *bool) ParserError!ast.Span {
    if (p.check(.str_start)) return try parseQuotedPath(p, quoted);
    quoted.* = false;
    const tok = try p.expect(.ident, "module name");
    return ast.Span.fromToken(tok);
}

fn parseQuotedPath(p: *Parser, quoted: *bool) ParserError!ast.Span {
    quoted.* = true;
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

// ---------- local <decl> ----------

/// `local <decl>` — visibility shim. Sets `is_local: true` on the
/// inner decl rather than nesting a wrapper variant.
pub fn parseLocalDecl(
    p: *Parser,
    statements: *std.ArrayList(ast.Statement),
) !void {
    const local_tok = p.peek();
    p.pos += 1;
    const start = local_tok.start;

    switch (p.peek().kind) {
        .kw_let => try statements.append(p.allocator, try parseLetDecl(p, true)),
        .kw_const => try statements.append(p.allocator, try parseConstDecl(p, true)),
        .kw_def => try statements.append(p.allocator, try parseDefDecl(p, true)),
        .kw_class => try statements.append(p.allocator, try parseClassDecl(p, true)),
        .kw_enum => try statements.append(p.allocator, try parseEnumDecl(p, true)),
        .kw_use => try statements.append(p.allocator, try parseUseDecl(p, true)),
        .ident => {
            const lex = p.source[p.peek().start..p.peek().end];
            if (std.mem.eql(u8, lex, "struct")) {
                try statements.append(p.allocator, try parseStructDecl(p, true));
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
