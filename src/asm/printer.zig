/// Asm pretty-printer — `ast.Program` + source → canonical `.gas`
/// text. Foundation for the `gero fmt` subcommand.
///
/// Approach: walk the AST and re-emit each statement in a fixed
/// shape (2-space indent for instructions, blank-line discipline
/// around top-level decls, canonical operand separators).
/// Expression and operand *contents* are sliced verbatim from
/// `source` — the printer normalizes the **layout** between
/// statements, not the bytes within them. This keeps round-trip
/// trivially semantic-preserving (the assembler sees the same
/// expression bytes either way) and idempotent (a second
/// parse + print of canonical text picks up the same spans and
/// re-emits identical bytes).
///
/// Known limitation: comments are stripped, because the lexer
/// currently doesn't preserve them in the AST. Tracked as a
/// follow-up; the printer itself stays comment-agnostic.
const std = @import("std");
const ast = @import("ast.zig");

/// Knobs for the canonical printer. Defaults match the asm style
/// used across `examples/asm/`.
pub const PrintOptions = struct {
    /// Spaces to indent instruction lines under their enclosing
    /// label.
    indent: usize = 2,
};

/// Default options — used by `gero fmt` and the round-trip tests.
pub const default_options: PrintOptions = .{};

/// Emit a canonical-form representation of `program` to `writer`.
/// `source` is the same buffer that produced `program` — the
/// printer slices it for expression / operand contents whose
/// source form must be preserved verbatim.
pub fn print(
    writer: *std.Io.Writer,
    program: *const ast.Program,
    source: []const u8,
    opts: PrintOptions,
) std.Io.Writer.Error!void {
    var prev: ?ast.Statement = null;
    for (program.statements) |stmt| {
        if (prev) |p| {
            if (needsBlankLineBefore(stmt, p)) try writer.writeByte('\n');
        }
        try writeStatement(writer, stmt, source, opts);
        try writer.writeByte('\n');
        prev = stmt;
    }
}

/// True when the canonical layout puts a blank line between `prev`
/// and `curr`. Instructions stay attached to their preceding label
/// or directive; consecutive same-kind decls (consts together,
/// data blocks together) cluster without separators.
fn needsBlankLineBefore(curr: ast.Statement, prev: ast.Statement) bool {
    // Instructions cling to the preceding label / directive.
    if (curr == .instruction) return false;
    // After a label header, anything follows tightly.
    if (prev == .label) return false;
    // Cluster same-kind decls (const-const, data8-data8, etc.).
    if (std.meta.activeTag(curr) == std.meta.activeTag(prev)) return false;
    return true;
}

/// Render one statement to `writer` (no trailing newline — `print`
/// adds it). Branches per `Statement` variant.
fn writeStatement(
    writer: *std.Io.Writer,
    stmt: ast.Statement,
    source: []const u8,
    opts: PrintOptions,
) std.Io.Writer.Error!void {
    switch (stmt) {
        .label => |l| try writer.print("{s}:", .{slice(source, l.name)}),
        .const_decl => |c| try writer.print(
            "const {s} = {s}",
            .{ slice(source, c.name), slice(source, c.expr.span()) },
        ),
        .data8 => |d| try writeData(writer, "data8", d, source),
        .data16 => |d| try writeData(writer, "data16", d, source),
        .struct_decl => |s| try writeStruct(writer, s, source),
        .org => |o| try writer.print(
            "org {s}",
            .{slice(source, o.addr_expr.span())},
        ),
        .bank_switch => |b| {
            // Folded `u8` re-emitted as a 2-digit hex literal
            // (`bank $00`) to match the asm-spec syntax — bare
            // decimals aren't accepted by the lexer. `null` only
            // happens when the parser flagged the RHS unresolvable;
            // emit `bank $00` so the canonical text still re-parses
            // cleanly (codegen has already raised the diagnostic).
            const idx = b.index orelse 0;
            try writer.print("bank ${X:0>2}", .{idx});
        },
        .sram_banks_decl => |s| {
            const count = s.count orelse 0;
            try writer.print("sram_banks ${X:0>2}", .{count});
        },
        .instruction => |i| try writeInstruction(writer, i, source, opts),
        .unknown => |u| try writer.writeAll(slice(source, u.span)),
    }
}

/// `data8` / `data16 NAME = v1, v2, ...` — keyword + name + comma-
/// separated value list. Values are span-sliced from source so
/// every literal form (`$10`, `'A'`, `&FFFF`, `@sym`, `"string"`,
/// `reserve N`) round-trips verbatim.
fn writeData(
    writer: *std.Io.Writer,
    keyword: []const u8,
    d: ast.DataDecl,
    source: []const u8,
) std.Io.Writer.Error!void {
    try writer.print("{s} {s} = ", .{ keyword, slice(source, d.name) });
    for (d.values, 0..) |v, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.writeAll(slice(source, v.span()));
    }
}

/// Multi-line struct emission:
///
/// ```asm
/// struct NAME {
///   field1: u8,
///   field2: u16,
/// }
/// ```
fn writeStruct(
    writer: *std.Io.Writer,
    s: ast.StructDecl,
    source: []const u8,
) std.Io.Writer.Error!void {
    try writer.print("struct {s} {{\n", .{slice(source, s.name)});
    for (s.fields) |f| {
        try writer.print(
            "  {s}: {s},\n",
            .{ slice(source, f.name), @tagName(f.ty) },
        );
    }
    try writer.writeByte('}');
}

/// Instruction emission: indent + mnemonic + comma-separated
/// operands. Zero-operand mnemonics (`hlt`, `nop`, `ret`) emit
/// without trailing whitespace.
fn writeInstruction(
    writer: *std.Io.Writer,
    inst: ast.Instruction,
    source: []const u8,
    opts: PrintOptions,
) std.Io.Writer.Error!void {
    var pad: usize = opts.indent;
    while (pad > 0) : (pad -= 1) try writer.writeByte(' ');
    try writer.writeAll(slice(source, inst.mnemonic));
    for (inst.operands, 0..) |op, i| {
        try writer.writeAll(if (i == 0) " " else ", ");
        try writeOperand(writer, op, source);
    }
}

/// One operand. Registers and indirect-via-register use the enum
/// `@tagName` (deterministic — no source variability); everything
/// else slices its span from `source` to preserve literal form
/// (`$10` stays `$10`, not `$0010`).
fn writeOperand(
    writer: *std.Io.Writer,
    op: ast.Operand,
    source: []const u8,
) std.Io.Writer.Error!void {
    switch (op) {
        .register => |r| try writer.writeAll(@tagName(r.id)),
        .indirect => |i| try writer.print("[{s}]", .{@tagName(i.reg.id)}),
        .immediate => |e| try writer.writeAll(slice(source, e.span())),
        .addr_lit => |a| try writer.writeAll(slice(source, a.span)),
        .sym_ref => |s| try writer.writeAll(slice(source, s.span)),
        .label_ref => |l| try writer.writeAll(slice(source, l.span)),
        .addr_expr => |a| try writer.writeAll(slice(source, a.span)),
        .indexed => |i| try writer.writeAll(slice(source, i.span)),
        .cast => |c| try writer.writeAll(slice(source, c.span)),
    }
}

inline fn slice(source: []const u8, span: ast.Span) []const u8 {
    return source[span.start..span.end];
}
