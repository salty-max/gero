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
/// sliced from source. Trailing comments (`hlt ; halt`) stay
/// **inline** with their host, padded to `opts.comment_column`
/// for vertical alignment across a block.
///
/// Additional canonical normalization:
///
///   - `const` / `data8` / `data16` blocks align their `=` column
///     to the longest name within a consecutive same-kind run
///     (`opts.align_kv`).
///   - `HexLit` / `AddrLit` re-emit from their parsed `u16` value
///     with case policy from `opts.hex_case` (upper / lower /
///     preserve).
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
    /// Column (1-indexed) trailing comments are padded to. Set to
    /// `0` to disable alignment (single space between host and
    /// `;` — minimal canonical form). The default matches the
    /// hand style across `examples/asm/`.
    comment_column: usize = 32,
    /// When `true`, aligns the `=` of consecutive `const`-decls
    /// (and `data8`/`data16`-decls) by padding the name column to
    /// the block's widest name.
    align_kv: bool = true,
    /// Case policy for `$XX` / `&XXXX` literals re-emitted from
    /// their parsed `u16` value.
    hex_case: HexCase = .upper,
};

/// Case policy for hex literals.
pub const HexCase = enum {
    /// `$ABCD`, `&FFFF` — canonical for v0.1 examples.
    upper,
    /// `$abcd`, `&ffff` — lowercase (some C / Rust shops).
    lower,
    /// Slice from source verbatim — don't normalize case.
    preserve,
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
    var skip_next = false;

    // Const / data K=V alignment is computed lazily per block: the
    // first decl in a same-kind run scans forward to its block end
    // and remembers the longest name. Subsequent decls in the run
    // reuse the cached width; once we exit the run, the cache is
    // invalidated so the next block recomputes.
    var kv_block_width: usize = 0;
    var kv_block_end: usize = 0;

    for (program.statements, 0..) |stmt, i| {
        if (skip_next) {
            skip_next = false;
            continue;
        }

        if (prev) |p| {
            if (needsBlankLineBefore(stmt, p, source)) try writer.writeByte('\n');
        }

        const directive = directiveOf(stmt, source);

        const trailing_comment: ?ast.Statement = blk: {
            if (stmt == .comment) break :blk null;
            if (i + 1 >= program.statements.len) break :blk null;
            const next = program.statements[i + 1];
            if (next != .comment) break :blk null;
            if (!sameSourceLine(stmt.span().end, next.span().start, source)) break :blk null;
            break :blk next;
        };

        // ---- decide whether this statement gets source-sliced ----
        const protected = blk: {
            if (in_block_ignore) {
                if (directive == .block_end) break :blk false;
                break :blk true;
            }
            if (ignore_next_pending and stmt != .comment) break :blk true;
            // Trailing-ignore on next line protects the host so the
            // whole line stays as-typed (no canonicalization).
            if (trailing_comment) |c| {
                if (directiveOf(c, source) == .trailing) break :blk true;
            }
            break :blk false;
        };

        // ---- refresh K=V block cache if we're entering a new run ----
        if (!protected and opts.align_kv and i >= kv_block_end and stmtIsKv(stmt)) {
            const info = kvBlockExtent(program.statements, i, source);
            kv_block_width = info.max_name_width;
            kv_block_end = info.end_idx;
        }

        // ---- emit ----
        if (protected) {
            // Source-slice the entire line, including the user's
            // leading indent (lives outside `stmt.span()`) and any
            // trailing comment on the same source line. Preserves
            // the user's exact byte-for-byte intent inside ignore
            // regions; no canonical padding.
            const start = lineStartBefore(source, stmt.span().start);
            const end = if (trailing_comment) |c| c.span().end else stmt.span().end;
            try writer.writeAll(source[start..end]);
        } else {
            const host_width = try writeStatementCanonical(writer, stmt, source, opts, kv_block_width);
            // Glue the trailing comment on the same line, padded to
            // the configured column. Single space if the host is
            // already past the column or alignment is off.
            if (trailing_comment) |c| {
                const pad = if (opts.comment_column > 0 and opts.comment_column > host_width + 1)
                    opts.comment_column - 1 - host_width
                else
                    1;
                try writeSpaces(writer, pad);
                try writer.writeAll(slice(source, c.span()));
            }
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
        if (trailing_comment != null) skip_next = true;

        prev = if (trailing_comment) |c| c else stmt;
    }
}

/// True when the statement is a key=value declaration eligible for
/// `=`-column alignment within its consecutive same-kind block.
fn stmtIsKv(stmt: ast.Statement) bool {
    return switch (stmt) {
        .const_decl, .data8, .data16 => true,
        else => false,
    };
}

/// Walk a consecutive run of same-kind K=V decls starting at
/// `start`, return the longest name width seen and the index right
/// past the run. Used by the K=V aligner.
fn kvBlockExtent(
    statements: []const ast.Statement,
    start: usize,
    source: []const u8,
) struct { max_name_width: usize, end_idx: usize } {
    const kind = std.meta.activeTag(statements[start]);
    var max: usize = 0;
    var i = start;
    while (i < statements.len and std.meta.activeTag(statements[i]) == kind) : (i += 1) {
        const name = kvName(statements[i]);
        const w = name.end - name.start;
        if (w > max) max = w;
        _ = source;
    }
    return .{ .max_name_width = max, .end_idx = i };
}

/// Name span of a K=V statement (const / data8 / data16).
fn kvName(stmt: ast.Statement) ast.Span {
    return switch (stmt) {
        .const_decl => |c| c.name,
        .data8 => |d| d.name,
        .data16 => |d| d.name,
        // allow-strict: only K=V variants pass `stmtIsKv`
        else => unreachable,
    };
}

/// Emit `count` ASCII spaces.
fn writeSpaces(writer: *std.Io.Writer, count: usize) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < count) : (i += 1) try writer.writeByte(' ');
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
/// adds it). Returns the width (in bytes) of what was emitted on
/// the current line, used by the trailing-comment aligner. The
/// optional `kv_block_width` is the longest name in the surrounding
/// K=V block (0 → no alignment).
fn writeStatementCanonical(
    writer: *std.Io.Writer,
    stmt: ast.Statement,
    source: []const u8,
    opts: PrintOptions,
    kv_block_width: usize,
) std.Io.Writer.Error!usize {
    return switch (stmt) {
        .label => |l| try writeLabel(writer, l, source),
        .const_decl => |c| try writeConst(writer, c, source, opts, kv_block_width),
        .data8 => |d| try writeData(writer, "data8", d, source, opts, kv_block_width),
        .data16 => |d| try writeData(writer, "data16", d, source, opts, kv_block_width),
        .struct_decl => |s| try writeStruct(writer, s, source),
        .org => |o| try writeOrg(writer, o, source, opts),
        .bank_switch => |b| try writeBankSwitch(writer, b.index orelse 0, opts),
        .sram_banks_decl => |s| try writeSramBanks(writer, s.count orelse 0, opts),
        .instruction => |i| try writeInstruction(writer, i, source, opts),
        .comment => |c| blk: {
            try writer.writeAll(slice(source, c.span));
            break :blk c.span.end - c.span.start;
        },
        .unknown => |u| blk: {
            try writer.writeAll(slice(source, u.span));
            break :blk u.span.end - u.span.start;
        },
    };
}

fn writeLabel(writer: *std.Io.Writer, l: ast.Label, source: []const u8) std.Io.Writer.Error!usize {
    const name = slice(source, l.name);
    try writer.print("{s}:", .{name});
    return name.len + 1;
}

fn writeConst(
    writer: *std.Io.Writer,
    c: ast.ConstDecl,
    source: []const u8,
    opts: PrintOptions,
    kv_block_width: usize,
) std.Io.Writer.Error!usize {
    const name = slice(source, c.name);
    try writer.writeAll("const ");
    try writer.writeAll(name);
    var pad: usize = 0;
    if (opts.align_kv and kv_block_width > name.len) {
        pad = kv_block_width - name.len;
        try writeSpaces(writer, pad);
    }
    try writer.writeAll(" = ");
    const expr_width = try writeExpr(writer, c.expr, source, opts);
    return "const ".len + name.len + pad + " = ".len + expr_width;
}

fn writeOrg(
    writer: *std.Io.Writer,
    o: ast.OrgDecl,
    source: []const u8,
    opts: PrintOptions,
) std.Io.Writer.Error!usize {
    try writer.writeAll("org ");
    const expr_width = try writeExpr(writer, o.addr_expr, source, opts);
    return "org ".len + expr_width;
}

fn writeBankSwitch(
    writer: *std.Io.Writer,
    idx: u8,
    opts: PrintOptions,
) std.Io.Writer.Error!usize {
    _ = opts; // hex_case is fixed `upper` for these — `bank $00` is the canonical asm spec form.
    try writer.print("bank ${X:0>2}", .{idx});
    return "bank $00".len;
}

fn writeSramBanks(
    writer: *std.Io.Writer,
    count: u8,
    opts: PrintOptions,
) std.Io.Writer.Error!usize {
    _ = opts;
    try writer.print("sram_banks ${X:0>2}", .{count});
    return "sram_banks $00".len;
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
    opts: PrintOptions,
    kv_block_width: usize,
) std.Io.Writer.Error!usize {
    _ = opts;
    const name = slice(source, d.name);
    try writer.writeAll(keyword);
    try writer.writeByte(' ');
    try writer.writeAll(name);
    var pad: usize = 0;
    if (kv_block_width > name.len) {
        pad = kv_block_width - name.len;
        try writeSpaces(writer, pad);
    }
    try writer.writeAll(" = ");
    var values_width: usize = 0;
    for (d.values, 0..) |v, i| {
        if (i > 0) {
            try writer.writeAll(", ");
            values_width += 2;
        }
        const text = slice(source, v.span());
        try writer.writeAll(text);
        values_width += text.len;
    }
    return keyword.len + 1 + name.len + pad + " = ".len + values_width;
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
) std.Io.Writer.Error!usize {
    try writer.print("struct {s} {{\n", .{slice(source, s.name)});
    for (s.fields) |f| {
        try writer.print(
            "  {s}: {s},\n",
            .{ slice(source, f.name), @tagName(f.ty) },
        );
    }
    try writer.writeByte('}');
    // The host-line width for trailing-comment alignment is the
    // closing brace's column (1) — multi-line structs almost
    // never carry trailing comments, but returning a sane value
    // keeps the aligner well-behaved.
    return 1;
}

/// Instruction emission: indent + mnemonic + comma-separated
/// operands. Zero-operand mnemonics (`hlt`, `nop`, `ret`) emit
/// without trailing whitespace.
fn writeInstruction(
    writer: *std.Io.Writer,
    inst: ast.Instruction,
    source: []const u8,
    opts: PrintOptions,
) std.Io.Writer.Error!usize {
    try writeSpaces(writer, opts.indent);
    const mnemonic = slice(source, inst.mnemonic);
    try writer.writeAll(mnemonic);
    var width: usize = opts.indent + mnemonic.len;
    for (inst.operands, 0..) |op, i| {
        const sep: []const u8 = if (i == 0) " " else ", ";
        try writer.writeAll(sep);
        width += sep.len;
        width += try writeOperand(writer, op, source, opts);
    }
    return width;
}

/// One operand. Registers + indirect-via-register use the enum
/// `@tagName` (deterministic). HexLit / AddrLit operands re-emit
/// from their parsed `u16` value with `opts.hex_case`. Everything
/// else slices its span from `source`.
fn writeOperand(
    writer: *std.Io.Writer,
    op: ast.Operand,
    source: []const u8,
    opts: PrintOptions,
) std.Io.Writer.Error!usize {
    return switch (op) {
        .register => |r| blk: {
            const name = @tagName(r.id);
            try writer.writeAll(name);
            break :blk name.len;
        },
        .indirect => |i| blk: {
            const name = @tagName(i.reg.id);
            try writer.print("[{s}]", .{name});
            break :blk name.len + 2;
        },
        .immediate => |e| try writeExpr(writer, e, source, opts),
        .addr_lit => |a| try writeAddrLit(writer, a, source, opts),
        .sym_ref => |s| blk: {
            const text = slice(source, s.span);
            try writer.writeAll(text);
            break :blk text.len;
        },
        .label_ref => |l| blk: {
            const text = slice(source, l.span);
            try writer.writeAll(text);
            break :blk text.len;
        },
        .addr_expr => |a| blk: {
            const text = slice(source, a.span);
            try writer.writeAll(text);
            break :blk text.len;
        },
        .indexed => |i| blk: {
            const text = slice(source, i.span);
            try writer.writeAll(text);
            break :blk text.len;
        },
        .cast => |c| blk: {
            const text = slice(source, c.span);
            try writer.writeAll(text);
            break :blk text.len;
        },
    };
}

/// Emit one `Expr`. Direct `HexLit` / `AddrLit` go through the
/// hex-case re-emitter; composite forms (binary / unary / paren /
/// ident / sym_ref / char) source-slice verbatim to preserve the
/// user's operator spacing + grouping.
fn writeExpr(
    writer: *std.Io.Writer,
    e: *const ast.Expr,
    source: []const u8,
    opts: PrintOptions,
) std.Io.Writer.Error!usize {
    return switch (e.*) {
        .hex => |h| try writeHexLit(writer, h, source, opts),
        .addr_lit => |a| try writeAddrLit(writer, a, source, opts),
        else => blk: {
            const text = slice(source, e.span());
            try writer.writeAll(text);
            break :blk text.len;
        },
    };
}

/// `$XX` / `$XXXX` — re-emit from `value` so case normalization
/// is applied. Width follows the value: 2 digits when it fits in
/// a byte, 4 when it needs the full word.
fn writeHexLit(
    writer: *std.Io.Writer,
    h: ast.HexLit,
    source: []const u8,
    opts: PrintOptions,
) std.Io.Writer.Error!usize {
    if (opts.hex_case == .preserve) {
        const text = slice(source, h.span);
        try writer.writeAll(text);
        return text.len;
    }
    // `.preserve` was short-circuited above; only `.upper`/`.lower`
    // reach here. A plain `if` avoids the third-arm `unreachable`
    // that zig fmt won't let live on its own line with a comment.
    if (h.value <= 0xFF) {
        if (opts.hex_case == .upper) {
            try writer.print("${X:0>2}", .{h.value});
        } else {
            try writer.print("${x:0>2}", .{h.value});
        }
        return "$XX".len;
    }
    if (opts.hex_case == .upper) {
        try writer.print("${X:0>4}", .{h.value});
    } else {
        try writer.print("${x:0>4}", .{h.value});
    }
    return "$XXXX".len;
}

/// `&XXXX` — always 4 hex digits per asm convention; only the case
/// policy varies.
fn writeAddrLit(
    writer: *std.Io.Writer,
    a: ast.AddrLit,
    source: []const u8,
    opts: PrintOptions,
) std.Io.Writer.Error!usize {
    if (opts.hex_case == .preserve) {
        const text = slice(source, a.span);
        try writer.writeAll(text);
        return text.len;
    }
    if (opts.hex_case == .upper) {
        try writer.print("&{X:0>4}", .{a.value});
    } else {
        try writer.print("&{x:0>4}", .{a.value});
    }
    return "&XXXX".len;
}

inline fn slice(source: []const u8, span: ast.Span) []const u8 {
    return source[span.start..span.end];
}
