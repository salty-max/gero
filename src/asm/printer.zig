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
/// Comments are preserved: the parser surfaces every `; ...` line
/// as a `Statement.comment` node and the printer emits it span-
/// sliced from source. Trailing comments (`hlt ; halt`) demote to
/// standalone (`hlt\n; halt`) on the first format pass and then
/// stay stable — the blank-line rule counts newlines in the
/// source gap so the layout is idempotent.
///
/// Ignore directives let users opt regions out of canonicalization
/// (same pattern as `// prettier-ignore` / `#[rustfmt::skip]`):
///
///   - `; gero-fmt-ignore-file`  in the leading comment block →
///     emit `source` verbatim, skip all canonicalization
///   - `; gero-fmt-ignore-start` … `; gero-fmt-ignore-end` →
///     statements between the markers are source-sliced verbatim
///   - `; gero-fmt-ignore-next` → the following non-comment
///     statement is source-sliced
///   - trailing `; gero-fmt-ignore` on the same source line as a
///     statement → that statement is source-sliced
///
/// The directive comments themselves stay in the output (they're
/// just regular comments to the printer).
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
    // File-level escape hatch: a `; gero-fmt-ignore-file` directive
    // anywhere in the leading comment block disables canonicalization
    // for the whole file. We dump `source` as-is and bail.
    if (fileIgnoreActive(program, source)) {
        try writer.writeAll(source);
        return;
    }

    var prev: ?ast.Statement = null;
    var in_block_ignore = false;
    var ignore_next_pending = false;
    var skip_next = false; // set by trailing-ignore — consume the trailing comment as part of the host's slice
    for (program.statements, 0..) |stmt, i| {
        if (skip_next) {
            skip_next = false;
            continue;
        }

        if (prev) |p| {
            if (needsBlankLineBefore(stmt, p, source)) try writer.writeByte('\n');
        }

        const directive = directiveOf(stmt, source);

        // Any comment on the same source line as this statement —
        // either the trailing-ignore directive itself, or a regular
        // note that we want to glue to a separately-protected line.
        const trailing_comment: ?ast.Statement = blk: {
            if (stmt == .comment) break :blk null;
            if (i + 1 >= program.statements.len) break :blk null;
            const next = program.statements[i + 1];
            if (next != .comment) break :blk null;
            if (!sameSourceLine(stmt.span().end, next.span().start, source)) break :blk null;
            break :blk next;
        };
        const trailing_is_directive = trailing_comment != null and
            directiveOf(trailing_comment.?, source) == .trailing;

        // ---- decide whether this statement gets source-sliced ----
        const protected = blk: {
            if (in_block_ignore) {
                if (directive == .block_end) break :blk false;
                break :blk true;
            }
            if (ignore_next_pending and stmt != .comment) break :blk true;
            if (trailing_is_directive) break :blk true;
            break :blk false;
        };

        // ---- emit ----
        if (protected) {
            // Walk back to the start of the line so the user's
            // leading indent (which lives outside `stmt.span()`)
            // is preserved verbatim, and extend through any trailing
            // comment on the same line so it stays glued to its host
            // (alignment + comment both preserved). Without the
            // trailing extension a non-directive comment would
            // demote to its own line, breaking idempotence.
            const start = lineStartBefore(source, stmt.span().start);
            const end = if (trailing_comment) |c| c.span().end else stmt.span().end;
            try writer.writeAll(source[start..end]);
        } else {
            try writeStatement(writer, stmt, source, opts);
        }
        try writer.writeByte('\n');

        // ---- update state for next iteration ----
        switch (directive) {
            .block_start => in_block_ignore = true,
            .block_end => in_block_ignore = false,
            .next => ignore_next_pending = true,
            .trailing, .file, .none => {},
        }
        if (protected and stmt != .comment) ignore_next_pending = false;
        // Skip the trailing comment on the next iteration whenever
        // we glued it to the protected host above.
        if (protected and trailing_comment != null) skip_next = true;

        prev = if (protected and trailing_comment != null) trailing_comment.? else stmt;
    }
}

/// `; gero-fmt-...` directive flavors recognized by the printer.
const Directive = enum { none, file, block_start, block_end, next, trailing };

/// Identify the ignore-directive flavor (if any) of a statement.
/// Non-comment statements always return `.none`.
fn directiveOf(stmt: ast.Statement, source: []const u8) Directive {
    if (stmt != .comment) return .none;
    const body = commentBody(stmt.comment, source);
    if (std.mem.eql(u8, body, "gero-fmt-ignore-file")) return .file;
    if (std.mem.eql(u8, body, "gero-fmt-ignore-start")) return .block_start;
    if (std.mem.eql(u8, body, "gero-fmt-ignore-end")) return .block_end;
    if (std.mem.eql(u8, body, "gero-fmt-ignore-next")) return .next;
    if (std.mem.eql(u8, body, "gero-fmt-ignore")) return .trailing;
    return .none;
}

/// Trimmed body of a `;` comment — strips the leading `;` and any
/// surrounding ASCII whitespace.
fn commentBody(c: ast.Comment, source: []const u8) []const u8 {
    var body = source[c.span.start..c.span.end];
    if (body.len > 0 and body[0] == ';') body = body[1..];
    return std.mem.trim(u8, body, " \t");
}

/// `true` when any statement in the leading **comment block** is
/// the file-level ignore directive. A non-comment statement
/// terminates the lookup.
fn fileIgnoreActive(program: *const ast.Program, source: []const u8) bool {
    for (program.statements) |s| {
        if (s != .comment) return false;
        if (directiveOf(s, source) == .file) return true;
    }
    return false;
}

/// Walk backward from `pos` to the start of the containing line
/// (one past the previous `\n`, or 0). Used by the ignore-region
/// emitter so leading indent is preserved verbatim.
fn lineStartBefore(source: []const u8, pos: u32) usize {
    var i: usize = pos;
    while (i > 0 and source[i - 1] != '\n') i -= 1;
    return i;
}

/// True when `end_a..start_b` in `source` is free of `\n`.
fn sameSourceLine(end_a: u32, start_b: u32, source: []const u8) bool {
    if (start_b <= end_a) return true;
    const lo: usize = end_a;
    // @as: widen u32 → usize so the slice indexes line up.
    const hi: usize = @min(@as(usize, start_b), source.len);
    for (source[lo..hi]) |b| {
        if (b == '\n') return false;
    }
    return true;
}

/// True when the canonical layout puts a blank line between `prev`
/// and `curr`. Rules:
///
/// - Instructions cling to the preceding label / directive.
/// - After a label header, anything follows tightly.
/// - Same-kind consecutive decls cluster (consts together, data
///   blocks together, comments together).
/// - Comments preserve the user's source blank-line intent: a
///   comment that had a blank line before it in source gets one
///   in the output too; a comment tight against its preceding
///   statement stays tight. This makes trailing-comment demotion
///   (`hlt ; halt` → `hlt\n; halt`) idempotent across re-formats.
/// - A standalone comment leads into the following statement
///   tightly (no blank between).
fn needsBlankLineBefore(
    curr: ast.Statement,
    prev: ast.Statement,
    source: []const u8,
) bool {
    if (curr == .instruction) return false;
    if (prev == .label) return false;
    if (std.meta.activeTag(curr) == std.meta.activeTag(prev)) return false;
    if (curr == .comment) {
        // Preserve "≥1 blank line in source" by counting newlines
        // in the inter-statement gap.
        return sourceNewlineCount(source, prev.span().end, curr.span().start) >= 2;
    }
    if (prev == .comment) return false;
    return true;
}

/// Number of `\n` bytes in `source[end_a..start_b)`. Caps inputs
/// at the source length for safety. Used by the blank-line rule
/// to inspect the original gap between two AST nodes.
fn sourceNewlineCount(source: []const u8, end_a: u32, start_b: u32) usize {
    if (start_b <= end_a) return 0;
    const lo: usize = end_a;
    // @as: widen u32 → usize so `@min` matches `source.len`'s type.
    const hi: usize = @min(@as(usize, start_b), source.len);
    var n: usize = 0;
    for (source[lo..hi]) |b| {
        if (b == '\n') n += 1;
    }
    return n;
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
        .comment => |c| try writer.writeAll(slice(source, c.span)),
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
