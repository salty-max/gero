/// Gero-lang pretty-printer — walks an `ast.Program` and emits
/// canonical `.gr` source per `docs/gero-lang.md`. Foundation for
/// `gero fmt` and for the parser round-trip property test.
///
/// Strategy: walk the AST and re-emit each node from its structured
/// shape. Identifiers, string parts, format specs, etc. are sliced
/// from `source` because they are byte-exact (the lexer doesn't
/// canonicalize identifier case or string escapes); all other text
/// is emitted from the AST shape itself.
///
/// Round-trip contract (§ acceptance of issue #231):
///
///   parse(print(parse(s))) == parse(s)
///
/// AST equality compares every structural field except byte
/// offsets (those legitimately differ when whitespace differs).
const std = @import("std");
const ast = @import("ast.zig");

/// Emit canonical `.gr` text for `program` into `writer`. `source`
/// is the original source buffer the AST was parsed from; the
/// printer slices identifier names, char literals, format specs
/// and similar atoms from it.
pub fn print(
    writer: *std.Io.Writer,
    program: *const ast.Program,
    source: []const u8,
) std.Io.Writer.Error!void {
    var p: Printer = .{ .writer = writer, .source = source, .indent = 0 };
    for (program.statements, 0..) |s, i| {
        if (i > 0) try p.writer.writeByte('\n');
        try p.writeStatement(s);
    }
    if (program.statements.len > 0) try p.writer.writeByte('\n');
}

const Printer = struct {
    writer: *std.Io.Writer,
    source: []const u8,
    indent: usize,

    // ---------- low-level ----------

    fn lexeme(self: *const Printer, span: ast.Span) []const u8 {
        return self.source[span.start..span.end];
    }

    fn writeIndent(self: *Printer) std.Io.Writer.Error!void {
        var i: usize = 0;
        while (i < self.indent) : (i += 1) try self.writer.writeAll("  ");
    }

    /// Bump indent by one and emit each body statement as its own
    /// line. `writeStatement` is responsible for prefixing its own
    /// indent, so this function only sets up indentation depth.
    fn writeBodyBlock(
        self: *Printer,
        body: []const ast.Statement,
    ) std.Io.Writer.Error!void {
        self.indent += 1;
        for (body) |s| {
            try self.writeStatement(s);
            try self.writer.writeByte('\n');
        }
        self.indent -= 1;
    }

    // ---------- annotations ----------

    /// Emit annotations as a sequence of `@name(args)\n<indent>`
    /// pairs. Caller is expected to have placed the writer at the
    /// start of the decl's line (with its proper indent already
    /// written). After the call, the writer is repositioned at the
    /// start of the decl content line.
    fn writeAnnotations(
        self: *Printer,
        anns: []const ast.Annotation,
    ) std.Io.Writer.Error!void {
        for (anns) |a| {
            try self.writer.writeByte('@');
            try self.writer.writeAll(self.lexeme(a.name));
            if (a.args.len > 0) {
                try self.writer.writeByte('(');
                for (a.args, 0..) |arg, i| {
                    if (i > 0) try self.writer.writeAll(", ");
                    try self.writeExpr(arg, .lowest);
                }
                try self.writer.writeByte(')');
            }
            try self.writer.writeByte('\n');
            try self.writeIndent();
        }
    }

    // ---------- statements ----------

    /// Emit a full statement line: indent prefix + statement content.
    /// Use this from contexts where the writer is at the start of a
    /// fresh line and a new statement needs its own indent.
    fn writeStatement(self: *Printer, s: ast.Statement) std.Io.Writer.Error!void {
        try self.writeIndent();
        try self.writeStatementInline(s);
    }

    /// Emit only the statement content, no indent prefix. Use this
    /// when the writer is already positioned mid-line — match-arm
    /// single-line bodies (after `=>`), `defer <stmt>`, etc.
    fn writeStatementInline(self: *Printer, s: ast.Statement) std.Io.Writer.Error!void {
        switch (s) {
            .let_decl => |d| try self.writeLetDecl(d),
            .const_decl => |d| try self.writeConstDecl(d),
            .assign => |a| try self.writeAssign(a),
            .inc_dec => |id| {
                try self.writeExpr(id.target, .lowest);
                try self.writer.writeAll(if (id.inc) "++" else "--");
            },
            .discard => |d| {
                try self.writer.writeAll("_ = ");
                try self.writeExpr(d.expr, .lowest);
            },
            .expr_stmt => |es| try self.writeExpr(es.expr, .lowest),
            .block => |b| try self.writeBlockStmt(b.body),
            .if_stmt => |is_| try self.writeIfStmt(is_),
            .while_stmt => |ws| try self.writeWhileStmt(ws),
            .for_stmt => |fs| try self.writeForStmt(fs),
            .repeat_stmt => |rs| try self.writeRepeatStmt(rs),
            .match_stmt => |ms| try self.writeMatchStmt(ms),
            .return_stmt => |rs| try self.writeReturnStmt(rs),
            .break_stmt => |b| try self.writeJump("break", b.label),
            .continue_stmt => |c| try self.writeJump("continue", c.label),
            .print_stmt => |ps| try self.writePrintStmt(ps),
            .def_decl => |d| try self.writeDefDecl(d),
            .class_decl => |c| try self.writeClassDecl(c),
            .struct_decl => |sd| try self.writeStructDecl(sd),
            .enum_decl => |ed| try self.writeEnumDecl(ed),
            .use_decl => |ud| try self.writeUseDecl(ud),
            .local_decl => {
                // Parser flattens `local <decl>` into the inner decl's
                // `is_local` field; the .local_decl variant only
                // appears for unrecognized shapes.
                try self.writer.writeAll("local <unrecognized>");
            },
            .asm_stmt => |as_| {
                try self.writer.writeAll("asm ");
                try self.writer.writeAll(self.lexeme(as_.body));
            },
            .defer_stmt => |ds| {
                try self.writer.writeAll("defer ");
                try self.writeStatementInline(ds.body.*);
            },
            .unknown => try self.writer.writeAll("<unknown>"),
        }
    }

    fn writeLetDecl(self: *Printer, d: ast.LetDecl) std.Io.Writer.Error!void {
        try self.writeAnnotations(d.annotations);
        if (d.is_local) try self.writer.writeAll("local ");
        try self.writer.writeAll("let ");
        try self.writePattern(d.pattern);
        if (d.type_ann) |t| {
            try self.writer.writeAll(": ");
            try self.writeTypeAnn(t);
        }
        if (d.init) |e| {
            try self.writer.writeAll(" = ");
            try self.writeExpr(e, .lowest);
        }
    }

    fn writeConstDecl(self: *Printer, d: ast.ConstDecl) std.Io.Writer.Error!void {
        try self.writeAnnotations(d.annotations);
        if (d.is_local) try self.writer.writeAll("local ");
        try self.writer.writeAll("const ");
        try self.writer.writeAll(self.lexeme(d.name));
        if (d.type_ann) |t| {
            try self.writer.writeAll(": ");
            try self.writeTypeAnn(t);
        }
        try self.writer.writeAll(" = ");
        try self.writeExpr(d.init, .lowest);
    }

    fn writeAssign(self: *Printer, a: ast.AssignStmt) std.Io.Writer.Error!void {
        try self.writeExpr(a.target, .lowest);
        try self.writer.writeByte(' ');
        try self.writer.writeAll(switch (a.op) {
            .set => "=",
            .add_set => "+=",
            .sub_set => "-=",
            .mul_set => "*=",
            .div_set => "/=",
            .mod_set => "%=",
            .bit_and_set => "&=",
            .bit_or_set => "|=",
            .bit_xor_set => "^=",
            .shl_set => "<<=",
            .shr_set => ">>=",
        });
        try self.writer.writeByte(' ');
        try self.writeExpr(a.value, .lowest);
    }

    fn writeBlockStmt(
        self: *Printer,
        body: []const ast.Statement,
    ) std.Io.Writer.Error!void {
        try self.writer.writeAll("do\n");
        try self.writeBodyBlock(body);
        try self.writeIndent();
        try self.writer.writeAll("end");
    }

    fn writeIfStmt(self: *Printer, s: ast.IfStmt) std.Io.Writer.Error!void {
        try self.writeIfChain(s.arms, s.else_body);
    }

    fn writeIfChain(
        self: *Printer,
        arms: []const ast.IfArm,
        else_body: ?[]const ast.Statement,
    ) std.Io.Writer.Error!void {
        for (arms, 0..) |arm, i| {
            try self.writer.writeAll(if (i == 0) "if " else "elif ");
            try self.writeIfArmHead(arm);
            try self.writer.writeByte('\n');
            try self.writeBodyBlock(arm.body);
        }
        if (else_body) |eb| {
            try self.writeIndent();
            try self.writer.writeAll("else\n");
            try self.writeBodyBlock(eb);
        }
        try self.writeIndent();
        try self.writer.writeAll("end");
    }

    fn writeIfArmHead(self: *Printer, arm: ast.IfArm) std.Io.Writer.Error!void {
        if (arm.let_pattern) |pat| {
            try self.writer.writeAll("let ");
            try self.writePattern(pat);
            try self.writer.writeAll(" = ");
            try self.writeExpr(arm.let_expr.?, .lowest);
            if (arm.let_guard) |g| {
                try self.writer.writeAll(" when ");
                try self.writeExpr(g, .lowest);
            }
        } else if (arm.cond) |c| {
            try self.writeExpr(c, .lowest);
        }
    }

    fn writeWhileStmt(self: *Printer, s: ast.WhileStmt) std.Io.Writer.Error!void {
        try self.writer.writeAll("while ");
        if (s.let_pattern) |pat| {
            try self.writer.writeAll("let ");
            try self.writePattern(pat);
            try self.writer.writeAll(" = ");
            try self.writeExpr(s.let_expr.?, .lowest);
            if (s.let_guard) |g| {
                try self.writer.writeAll(" when ");
                try self.writeExpr(g, .lowest);
            }
        } else if (s.cond) |c| {
            try self.writeExpr(c, .lowest);
        }
        if (s.label) |lbl| {
            try self.writer.writeAll(" :");
            try self.writer.writeAll(self.lexeme(lbl));
        }
        try self.writer.writeByte('\n');
        try self.writeBodyBlock(s.body);
        try self.writeIndent();
        try self.writer.writeAll("end");
    }

    fn writeForStmt(self: *Printer, s: ast.ForStmt) std.Io.Writer.Error!void {
        try self.writer.writeAll("for ");
        try self.writer.writeAll(self.lexeme(s.binding));
        try self.writer.writeAll(" in ");
        try self.writeExpr(s.iter, .lowest);
        if (s.step) |st| {
            try self.writer.writeAll(" step ");
            try self.writeExpr(st, .lowest);
        }
        if (s.label) |lbl| {
            try self.writer.writeAll(" :");
            try self.writer.writeAll(self.lexeme(lbl));
        }
        try self.writer.writeByte('\n');
        try self.writeBodyBlock(s.body);
        try self.writeIndent();
        try self.writer.writeAll("end");
    }

    fn writeRepeatStmt(self: *Printer, s: ast.RepeatStmt) std.Io.Writer.Error!void {
        try self.writer.writeAll("repeat");
        if (s.label) |lbl| {
            try self.writer.writeAll(" :");
            try self.writer.writeAll(self.lexeme(lbl));
        }
        try self.writer.writeByte('\n');
        try self.writeBodyBlock(s.body);
        try self.writeIndent();
        try self.writer.writeAll("until ");
        try self.writeExpr(s.cond, .lowest);
    }

    fn writeMatchStmt(self: *Printer, s: ast.MatchStmt) std.Io.Writer.Error!void {
        try self.writer.writeAll("match ");
        try self.writeExpr(s.scrutinee, .lowest);
        try self.writer.writeByte('\n');
        self.indent += 1;
        for (s.arms) |arm| {
            try self.writeIndent();
            try self.writer.writeAll("case ");
            try self.writePattern(arm.pattern);
            if (arm.guard) |g| {
                try self.writer.writeAll(" when ");
                try self.writeExpr(g, .lowest);
            }
            try self.writer.writeAll(" =>");
            if (arm.body.len == 1 and isSingleLineStatement(arm.body[0])) {
                try self.writer.writeByte(' ');
                try self.writeStatementInline(arm.body[0]);
                try self.writer.writeByte('\n');
            } else {
                try self.writer.writeByte('\n');
                try self.writeBodyBlock(arm.body);
            }
        }
        self.indent -= 1;
        try self.writeIndent();
        try self.writer.writeAll("end");
    }

    fn writeReturnStmt(self: *Printer, s: ast.ReturnStmt) std.Io.Writer.Error!void {
        try self.writer.writeAll("return");
        if (s.value) |v| {
            try self.writer.writeByte(' ');
            try self.writeExpr(v, .lowest);
        }
    }

    fn writeJump(
        self: *Printer,
        kw: []const u8,
        label: ?ast.Span,
    ) std.Io.Writer.Error!void {
        try self.writer.writeAll(kw);
        if (label) |l| {
            try self.writer.writeAll(" :");
            try self.writer.writeAll(self.lexeme(l));
        }
    }

    fn writePrintStmt(self: *Printer, s: ast.PrintStmt) std.Io.Writer.Error!void {
        try self.writer.writeAll("print");
        for (s.args, 0..) |a, i| {
            try self.writer.writeAll(if (i == 0) " " else ", ");
            try self.writeExpr(a, .lowest);
        }
    }

    fn writeDefDecl(self: *Printer, d: ast.DefDecl) std.Io.Writer.Error!void {
        try self.writeAnnotations(d.annotations);
        if (d.is_local) try self.writer.writeAll("local ");
        if (d.is_bake) try self.writer.writeAll("bake ");
        try self.writer.writeAll("def ");
        try self.writer.writeAll(self.lexeme(d.name));
        try self.writeParamList(d.params);
        if (d.ret_type) |r| {
            try self.writer.writeAll(" -> ");
            try self.writeTypeAnn(r);
        }
        if (d.body.len == 0 and hasAnnotationNamed(d.annotations, "abstract")) {
            return; // abstract method — no body
        }
        try self.writer.writeByte('\n');
        try self.writeBodyBlock(d.body);
        try self.writeIndent();
        try self.writer.writeAll("end");
    }

    fn writeParamList(
        self: *Printer,
        params: []const ast.Param,
    ) std.Io.Writer.Error!void {
        try self.writer.writeByte('(');
        for (params, 0..) |param, i| {
            if (i > 0) try self.writer.writeAll(", ");
            try self.writer.writeAll(self.lexeme(param.name));
            if (param.variadic) {
                try self.writer.writeAll(": ...");
            } else if (param.type_ann) |t| {
                try self.writer.writeAll(": ");
                try self.writeTypeAnn(t);
            }
        }
        try self.writer.writeByte(')');
    }

    fn writeClassDecl(self: *Printer, d: ast.ClassDecl) std.Io.Writer.Error!void {
        try self.writeAnnotations(d.annotations);
        if (d.is_local) try self.writer.writeAll("local ");
        try self.writer.writeAll("class ");
        try self.writer.writeAll(self.lexeme(d.name));
        if (d.extends) |e| {
            try self.writer.writeAll(" extends ");
            try self.writer.writeAll(self.lexeme(e));
        }
        try self.writer.writeByte('\n');
        self.indent += 1;
        for (d.fields) |f| {
            try self.writeIndent();
            try self.writeAnnotations(f.annotations);
            try self.writer.writeAll("let ");
            try self.writer.writeAll(self.lexeme(f.name));
            if (f.type_ann) |t| {
                try self.writer.writeAll(": ");
                try self.writeTypeAnn(t);
            }
            if (f.init) |init_| {
                try self.writer.writeAll(" = ");
                try self.writeExpr(init_, .lowest);
            }
            try self.writer.writeByte('\n');
        }
        if (d.fields.len > 0 and d.methods.len > 0) try self.writer.writeByte('\n');
        for (d.methods, 0..) |m, i| {
            if (i > 0) try self.writer.writeByte('\n');
            try self.writeIndent();
            try self.writeDefDecl(m);
            try self.writer.writeByte('\n');
        }
        self.indent -= 1;
        try self.writeIndent();
        try self.writer.writeAll("end");
    }

    fn writeStructDecl(self: *Printer, d: ast.StructDecl) std.Io.Writer.Error!void {
        try self.writeAnnotations(d.annotations);
        if (d.is_local) try self.writer.writeAll("local ");
        try self.writer.writeAll("struct ");
        try self.writer.writeAll(self.lexeme(d.name));
        try self.writer.writeByte('\n');
        self.indent += 1;
        for (d.fields) |f| {
            try self.writeIndent();
            try self.writer.writeAll(self.lexeme(f.name));
            try self.writer.writeAll(": ");
            try self.writeTypeAnn(f.type_ann);
            try self.writer.writeByte('\n');
        }
        self.indent -= 1;
        try self.writeIndent();
        try self.writer.writeAll("end");
    }

    fn writeEnumDecl(self: *Printer, d: ast.EnumDecl) std.Io.Writer.Error!void {
        try self.writeAnnotations(d.annotations);
        if (d.is_local) try self.writer.writeAll("local ");
        try self.writer.writeAll("enum ");
        try self.writer.writeAll(self.lexeme(d.name));
        try self.writer.writeByte('\n');
        self.indent += 1;
        for (d.variants) |v| {
            try self.writeIndent();
            try self.writer.writeAll("case ");
            try self.writer.writeAll(self.lexeme(v.name));
            if (v.payload.len > 0) {
                try self.writer.writeByte('(');
                for (v.payload, 0..) |p, i| {
                    if (i > 0) try self.writer.writeAll(", ");
                    // Anonymous payload slots have a zero-width name
                    // span (parser convention); only re-emit the
                    // `name: ` prefix when the span has bytes.
                    if (p.name.end > p.name.start) {
                        try self.writer.writeAll(self.lexeme(p.name));
                        try self.writer.writeAll(": ");
                    }
                    try self.writeTypeAnn(p.type_ann);
                }
                try self.writer.writeByte(')');
            }
            try self.writer.writeByte('\n');
        }
        self.indent -= 1;
        try self.writeIndent();
        try self.writer.writeAll("end");
    }

    fn writeUseDecl(self: *Printer, d: ast.UseDecl) std.Io.Writer.Error!void {
        if (d.is_local) try self.writer.writeAll("local ");
        try self.writer.writeAll("use ");
        if (d.items.len > 0) {
            // `use a [as al], b [as bl] from module`.
            for (d.items, 0..) |it, i| {
                if (i > 0) try self.writer.writeAll(", ");
                try self.writer.writeAll(self.lexeme(it.name));
                if (it.alias) |al| {
                    try self.writer.writeAll(" as ");
                    try self.writer.writeAll(self.lexeme(al));
                }
            }
            try self.writer.writeAll(" from ");
        }
        // For `use "./path"`, the module span already covers the
        // surrounding quotes captured by the lexer; for bare module
        // names there are none to add.
        try self.writer.writeAll(self.lexeme(d.module));
        if (d.alias) |al| {
            // Whole-module alias only — selective form attaches per-
            // item aliases above.
            try self.writer.writeAll(" as ");
            try self.writer.writeAll(self.lexeme(al));
        }
    }

    // ---------- patterns ----------

    fn writePattern(self: *Printer, p: *const ast.Pattern) std.Io.Writer.Error!void {
        switch (p.*) {
            .wildcard => try self.writer.writeByte('_'),
            .ident => |x| try self.writer.writeAll(self.lexeme(x.name)),
            // Re-emit the source span so hex (`$FF`) / binary
            // (`0b…`) / decimal forms round-trip byte-identical
            // instead of normalizing to decimal.
            .int_lit => |x| try self.writer.writeAll(self.lexeme(x.span)),
            .str_lit => |x| try self.writer.writeAll(self.lexeme(x.span)),
            .char_lit => |x| try self.writer.writeAll(self.lexeme(x.span)),
            .bool_lit => |x| try self.writer.writeAll(if (x.value) "true" else "false"),
            .nil_lit => try self.writer.writeAll("nil"),
            .or_pattern => |x| {
                for (x.alts, 0..) |alt, i| {
                    if (i > 0) try self.writer.writeAll(" | ");
                    try self.writePattern(alt);
                }
            },
            .range_pattern => |x| try self.writer.writeAll(self.lexeme(x.span)),
            .tuple_pattern => |x| {
                try self.writer.writeByte('(');
                for (x.elems, 0..) |elem, i| {
                    if (i > 0) try self.writer.writeAll(", ");
                    try self.writePattern(elem);
                }
                try self.writer.writeByte(')');
            },
            .variant_pattern => |x| {
                try self.writer.writeAll(self.lexeme(x.path));
                if (x.args.len > 0) {
                    try self.writer.writeByte('(');
                    for (x.args, 0..) |arg, i| {
                        if (i > 0) try self.writer.writeAll(", ");
                        try self.writePattern(arg);
                    }
                    try self.writer.writeByte(')');
                }
            },
            .struct_pattern => |x| {
                try self.writer.writeAll(self.lexeme(x.type_name));
                try self.writer.writeAll(" { ");
                for (x.fields, 0..) |f, i| {
                    if (i > 0) try self.writer.writeAll(", ");
                    // Shorthand: `Player { hp }` desugared by parser
                    // to `hp: hp`. Re-emit short form when the sub-
                    // pattern is a same-named ident.
                    if (f.sub.* == .ident and
                        std.mem.eql(u8, self.lexeme(f.sub.ident.name), self.lexeme(f.name)))
                    {
                        try self.writer.writeAll(self.lexeme(f.name));
                    } else {
                        try self.writer.writeAll(self.lexeme(f.name));
                        try self.writer.writeAll(": ");
                        try self.writePattern(f.sub);
                    }
                }
                try self.writer.writeAll(" }");
            },
        }
    }

    // ---------- type annotations ----------

    fn writeTypeAnn(self: *Printer, t: *const ast.TypeAnn) std.Io.Writer.Error!void {
        switch (t.*) {
            .named => |n| try self.writer.writeAll(self.lexeme(n.name)),
            .nullable => |n| {
                try self.writeTypeAnn(n.inner);
                try self.writer.writeByte('?');
            },
            .array => |a| {
                try self.writer.writeByte('[');
                try self.writeTypeAnn(a.elem);
                try self.writer.writeAll("; ");
                try self.writeExpr(a.len_expr, .lowest);
                try self.writer.writeByte(']');
            },
            .vec => |v| {
                try self.writer.writeAll("Vec(");
                try self.writeTypeAnn(v.elem);
                try self.writer.writeByte(')');
            },
            .tuple => |tu| {
                try self.writer.writeByte('(');
                for (tu.elems, 0..) |e, i| {
                    if (i > 0) try self.writer.writeAll(", ");
                    try self.writeTypeAnn(e);
                }
                try self.writer.writeByte(')');
            },
            .fn_type => |f| {
                try self.writer.writeAll("fn(");
                for (f.params, 0..) |p, i| {
                    if (i > 0) try self.writer.writeAll(", ");
                    try self.writeTypeAnn(p);
                }
                try self.writer.writeByte(')');
                if (f.ret) |r| {
                    try self.writer.writeAll(" -> ");
                    try self.writeTypeAnn(r);
                }
            },
            .reference => |r| {
                try self.writer.writeByte('&');
                try self.writeTypeAnn(r.inner);
            },
        }
    }

    // ---------- expressions ----------

    /// Pratt-style precedence to drive minimum-paren printing.
    /// Mirrors the order in `src/lang/expr.zig::Prec`.
    const Prec = enum(u8) {
        lowest = 0,
        range = 1,
        log_or = 2,
        log_and = 3,
        compare = 4,
        bit_or = 5,
        bit_xor = 6,
        bit_and = 7,
        shift = 8,
        add = 9,
        mul = 10,
        is_test = 11,
        as_cast = 12,
        unary = 13,
        call = 14,
    };

    fn binPrec(op: ast.BinaryOp) Prec {
        return switch (op) {
            .log_or => .log_or,
            .log_and => .log_and,
            .eq, .neq, .lt, .lte, .gt, .gte => .compare,
            .bit_or => .bit_or,
            .bit_xor => .bit_xor,
            .bit_and => .bit_and,
            .shl, .shr => .shift,
            .add, .sub => .add,
            .mul, .div, .mod => .mul,
        };
    }

    fn writeExpr(
        self: *Printer,
        e: *const ast.Expr,
        outer: Prec,
    ) std.Io.Writer.Error!void {
        switch (e.*) {
            // Re-emit the source span so hex (`$FF`) / binary
            // (`0b…`) / decimal forms round-trip byte-identical
            // instead of normalizing to decimal.
            .int_lit => |x| try self.writer.writeAll(self.lexeme(x.span)),
            .fixed_lit => |x| try self.writer.writeAll(self.lexeme(x.span)),
            .bool_lit => |x| try self.writer.writeAll(if (x.value) "true" else "false"),
            .nil_lit => try self.writer.writeAll("nil"),
            .self_expr => try self.writer.writeAll("self"),
            .super_expr => try self.writer.writeAll("super"),
            .char_lit => |x| try self.writer.writeAll(self.lexeme(x.span)),
            .str_lit => |x| try self.writeStrLit(x),
            .ident => |x| try self.writer.writeAll(self.lexeme(x.span)),
            .paren => |p| {
                try self.writer.writeByte('(');
                try self.writeExpr(p.inner, .lowest);
                try self.writer.writeByte(')');
            },
            .unary => |u| {
                const need_parens = @intFromEnum(outer) > @intFromEnum(Prec.unary);
                if (need_parens) try self.writer.writeByte('(');
                try self.writer.writeAll(switch (u.op) {
                    .neg => "-",
                    .log_not => "not ",
                    .bit_not => "~",
                });
                try self.writeExpr(u.operand, .unary);
                if (need_parens) try self.writer.writeByte(')');
            },
            .binary => |b| {
                const my_prec = binPrec(b.op);
                const need_parens = @intFromEnum(outer) > @intFromEnum(my_prec);
                if (need_parens) try self.writer.writeByte('(');
                try self.writeExpr(b.lhs, my_prec);
                try self.writer.writeByte(' ');
                try self.writer.writeAll(binOpLexeme(b.op));
                try self.writer.writeByte(' ');
                // Right-associativity: bump prec so chains parse same shape.
                const rhs_prec: Prec = @enumFromInt(@intFromEnum(my_prec) + 1);
                try self.writeExpr(b.rhs, rhs_prec);
                if (need_parens) try self.writer.writeByte(')');
            },
            .range => |r| {
                const need_parens = @intFromEnum(outer) > @intFromEnum(Prec.range);
                if (need_parens) try self.writer.writeByte('(');
                try self.writeExpr(r.start, .range);
                try self.writer.writeAll(if (r.inclusive) "..=" else "..");
                try self.writeExpr(r.end, .range);
                if (need_parens) try self.writer.writeByte(')');
            },
            .call => |c| {
                try self.writeExpr(c.callee, .call);
                try self.writer.writeByte('(');
                for (c.args, 0..) |a, i| {
                    if (i > 0) try self.writer.writeAll(", ");
                    try self.writeExpr(a, .lowest);
                }
                try self.writer.writeByte(')');
            },
            .method_call => |m| {
                try self.writeExpr(m.receiver, .call);
                try self.writer.writeByte('.');
                try self.writer.writeAll(self.lexeme(m.method));
                try self.writer.writeByte('(');
                for (m.args, 0..) |a, i| {
                    if (i > 0) try self.writer.writeAll(", ");
                    try self.writeExpr(a, .lowest);
                }
                try self.writer.writeByte(')');
            },
            .field => |f| {
                try self.writeExpr(f.receiver, .call);
                try self.writer.writeByte('.');
                try self.writer.writeAll(self.lexeme(f.field));
            },
            .index => |ix| {
                try self.writeExpr(ix.receiver, .call);
                try self.writer.writeByte('[');
                try self.writeExpr(ix.index, .lowest);
                try self.writer.writeByte(']');
            },
            .do_expr => |d| {
                if (d.is_bake) try self.writer.writeAll("bake ");
                try self.writer.writeAll("do\n");
                try self.writeBodyBlock(d.body);
                try self.writeIndent();
                try self.writer.writeAll("end");
            },
            .if_expr => |ie| try self.writeIfChain(ie.arms, ie.else_body),
            .lambda => |l| try self.writeLambda(l),
            .list_lit => |ll| {
                try self.writer.writeByte('[');
                for (ll.elems, 0..) |x, i| {
                    if (i > 0) try self.writer.writeAll(", ");
                    try self.writeExpr(x, .lowest);
                }
                try self.writer.writeByte(']');
            },
            .list_repeat => |lr| {
                try self.writer.writeByte('[');
                try self.writeExpr(lr.value, .lowest);
                try self.writer.writeAll("; ");
                try self.writeExpr(lr.count, .lowest);
                try self.writer.writeByte(']');
            },
            .struct_lit => |sl| {
                try self.writer.writeAll(self.lexeme(sl.type_name));
                try self.writer.writeAll(" { ");
                for (sl.fields, 0..) |f, i| {
                    if (i > 0) try self.writer.writeAll(", ");
                    try self.writer.writeAll(self.lexeme(f.name));
                    try self.writer.writeAll(": ");
                    try self.writeExpr(f.value, .lowest);
                }
                try self.writer.writeAll(" }");
            },
            .tuple_lit => |tl| {
                try self.writer.writeByte('(');
                for (tl.elems, 0..) |x, i| {
                    if (i > 0) try self.writer.writeAll(", ");
                    try self.writeExpr(x, .lowest);
                }
                try self.writer.writeByte(')');
            },
            .is_test => |it| {
                const need_parens = @intFromEnum(outer) > @intFromEnum(Prec.is_test);
                if (need_parens) try self.writer.writeByte('(');
                try self.writeExpr(it.lhs, .is_test);
                try self.writer.writeAll(" is ");
                try self.writer.writeAll(self.lexeme(it.variant_path));
                if (need_parens) try self.writer.writeByte(')');
            },
            .cast => |c| {
                const need_parens = @intFromEnum(outer) > @intFromEnum(Prec.as_cast);
                if (need_parens) try self.writer.writeByte('(');
                try self.writeExpr(c.inner, .as_cast);
                try self.writer.writeAll(" as ");
                try self.writeTypeAnn(c.target_type);
                if (need_parens) try self.writer.writeByte(')');
            },
            .ref_of => |r| {
                const need_parens = @intFromEnum(outer) > @intFromEnum(Prec.unary);
                if (need_parens) try self.writer.writeByte('(');
                try self.writer.writeByte('&');
                try self.writeExpr(r.inner, .unary);
                if (need_parens) try self.writer.writeByte(')');
            },
        }
    }

    fn writeStrLit(self: *Printer, x: ast.StrLitExpr) std.Io.Writer.Error!void {
        try self.writer.writeByte('"');
        for (x.parts) |part| switch (part) {
            .lit => |lp| try self.writer.writeAll(self.lexeme(lp.span)),
            .interp => |ip| {
                try self.writer.writeAll("$(");
                try self.writeExpr(ip.expr, .lowest);
                if (ip.format_spec) |fs| {
                    try self.writer.writeByte(':');
                    try self.writer.writeAll(self.lexeme(fs));
                }
                try self.writer.writeByte(')');
            },
        };
        try self.writer.writeByte('"');
    }

    fn writeLambda(self: *Printer, l: ast.LambdaExpr) std.Io.Writer.Error!void {
        // Short form when the body is exactly one `return <expr>` —
        // this is the canonical shape `parseShortLambda` produces.
        if (l.body.len == 1 and l.body[0] == .return_stmt and l.body[0].return_stmt.value != null) {
            try self.writer.writeByte('|');
            for (l.params, 0..) |p, i| {
                if (i > 0) try self.writer.writeAll(", ");
                try self.writer.writeAll(self.lexeme(p.name));
                if (p.type_ann) |t| {
                    try self.writer.writeAll(": ");
                    try self.writeTypeAnn(t);
                }
            }
            try self.writer.writeByte('|');
            if (l.ret_type) |r| {
                try self.writer.writeAll(" -> ");
                try self.writeTypeAnn(r);
            }
            try self.writer.writeByte(' ');
            try self.writeExpr(l.body[0].return_stmt.value.?, .lowest);
            return;
        }
        // Long form.
        try self.writer.writeAll("lambda ");
        try self.writeParamList(l.params);
        if (l.ret_type) |r| {
            try self.writer.writeAll(" -> ");
            try self.writeTypeAnn(r);
        }
        try self.writer.writeByte('\n');
        try self.writeBodyBlock(l.body);
        try self.writeIndent();
        try self.writer.writeAll("end");
    }
};

// ---------- module-level helpers ----------

fn binOpLexeme(op: ast.BinaryOp) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .mod => "%",
        .shl => "<<",
        .shr => ">>",
        .bit_and => "&",
        .bit_or => "|",
        .bit_xor => "^",
        .eq => "==",
        .neq => "!=",
        .lt => "<",
        .lte => "<=",
        .gt => ">",
        .gte => ">=",
        .log_and => "and",
        .log_or => "or",
    };
}

fn hasAnnotationNamed(anns: []const ast.Annotation, _name: []const u8) bool {
    _ = anns;
    _ = _name;
    // The parser already stripped `@abstract` bodies from the AST
    // (body is empty). We don't need to inspect annotations here —
    // a body-less def_decl is the signal. Reserved for future use.
    return false;
}

fn isSingleLineStatement(s: ast.Statement) bool {
    return switch (s) {
        .expr_stmt, .return_stmt, .break_stmt, .continue_stmt, .print_stmt, .assign, .inc_dec, .discard => true,
        else => false,
    };
}
