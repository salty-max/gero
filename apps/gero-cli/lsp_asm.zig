//! What a name in a `.gas` document refers to.
//!
//! The assembler already records where each label and constant was
//! declared (`asm.Symbol.decl_start`) and what it evaluates to, so a
//! declaration needs no second implementation here. References are the
//! missing half: the assembler resolves a name to a value without
//! caring where it was written, so the use sites are collected from
//! the parse tree instead — which keeps the walk out of every
//! `gero asm` run, where it would pay for a question nobody asked.
//!
//! Asm has no scoping to get wrong. A global name means one thing
//! across a program, and a local label means one thing within its
//! parent, so a name plus the label it sits under is the whole story.

const std = @import("std");
const gero = @import("gero");

const analysis = @import("lsp_analysis.zig");

/// A name written somewhere in the fused source.
pub const Reference = struct {
    /// Span of the name as written, without a leading `@`.
    span: gero.asm_.Span,
    /// The symbol-table key it resolves to — a local label carries
    /// its parent, so `.loop` under `main` is `main.loop`.
    key: []const u8,
};

/// Every reference in `tree`, in source order.
///
/// A local label is mangled against the most recent global label, the
/// same way codegen does it, so a reference and its declaration agree
/// on one key.
pub fn collectReferences(
    arena: std.mem.Allocator,
    source: []const u8,
    tree: gero.asm_.ParseTree,
) std.mem.Allocator.Error![]const Reference {
    var out: std.ArrayList(Reference) = .empty;
    var parent: ?[]const u8 = null;
    for (tree.program.statements) |stmt| switch (stmt) {
        .label => |l| {
            const name = source[l.name.start..l.name.end];
            // A global label opens a new scope for the locals under it;
            // the declaration itself is in the symbol table already.
            if (name.len > 0 and name[0] != '.') parent = name;
        },
        .instruction => |ins| {
            for (ins.operands) |op| try walkOperand(arena, source, parent, op, &out);
        },
        .const_decl => |c| try walkExpr(arena, source, parent, c.expr, &out),
        // `data16 PTR = @target` is how a program gets a label's
        // address into memory, so these carry real references.
        .data8, .data16 => |d| {
            for (d.values) |v| switch (v) {
                .expr => |e| try walkExpr(arena, source, parent, e.expr, &out),
                .sym_ref => |sr| try add(arena, source, parent, sr.span, true, &out),
                .reserve => |r| try walkExpr(arena, source, parent, r.count_expr, &out),
                .addr_lit, .string => {},
            };
        },
        .org => |o| try walkExpr(arena, source, parent, o.addr_expr, &out),
        .heap => |h| try walkExpr(arena, source, parent, h.addr_expr, &out),
        else => {},
    };
    return out.toOwnedSlice(arena);
}

fn walkOperand(
    arena: std.mem.Allocator,
    source: []const u8,
    parent: ?[]const u8,
    op: gero.asm_.Operand,
    out: *std.ArrayList(Reference),
) std.mem.Allocator.Error!void {
    switch (op) {
        .label_ref => |l| try add(arena, source, parent, l.span, false, out),
        .sym_ref => |sr| try add(arena, source, parent, sr.span, true, out),
        .immediate => |e| try walkExpr(arena, source, parent, e, out),
        .addr_expr => |a| try walkExpr(arena, source, parent, a.expr, out),
        .indexed => |ix| try walkExpr(arena, source, parent, ix.addr, out),
        .cast => |c| try add(arena, source, parent, c.sym_ref.span, true, out),
        .register, .indirect, .reg_offset, .addr_lit => {},
    }
}

fn walkExpr(
    arena: std.mem.Allocator,
    source: []const u8,
    parent: ?[]const u8,
    e: *const gero.asm_.Expr,
    out: *std.ArrayList(Reference),
) std.mem.Allocator.Error!void {
    switch (e.*) {
        .sym_ref => |sr| try add(arena, source, parent, sr.span, true, out),
        .ident => |i| try add(arena, source, parent, i.span, false, out),
        .paren => |p| try walkExpr(arena, source, parent, p.inner, out),
        .unary => |u| try walkExpr(arena, source, parent, u.operand, out),
        .binary => |b| {
            try walkExpr(arena, source, parent, b.lhs, out);
            try walkExpr(arena, source, parent, b.rhs, out);
        },
        .hex, .char, .addr_lit => {},
    }
}

/// Record one reference. `sigil` drops a leading `@`, which the span
/// of a `@sym` token includes.
fn add(
    arena: std.mem.Allocator,
    source: []const u8,
    parent: ?[]const u8,
    span: gero.asm_.Span,
    sigil: bool,
    out: *std.ArrayList(Reference),
) std.mem.Allocator.Error!void {
    const start = if (sigil) span.start + 1 else span.start;
    if (start >= span.end) return;
    const name = source[start..span.end];
    try out.append(arena, .{
        .span = .{ .start = start, .end = span.end },
        .key = try keyFor(arena, name, parent),
    });
}

/// The symbol-table key `name` resolves to under `parent`.
pub fn keyFor(
    arena: std.mem.Allocator,
    name: []const u8,
    parent: ?[]const u8,
) std.mem.Allocator.Error![]const u8 {
    if (name.len == 0 or name[0] != '.') return name;
    const p = parent orelse return name;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ p, name });
}

// ---------- queries ----------

/// What a name at a position refers to.
pub const Resolved = struct {
    /// The reference's own span, so an editor can highlight it.
    ref: gero.asm_.Span,
    /// The symbol-table key it resolves to.
    key: []const u8,
    /// What the assembler recorded for that key.
    symbol: gero.asm_.Symbol,
};

/// The symbol named at `offset`, or `null` where no name sits.
///
/// A declaration resolves to itself, so asking on `main:` answers the
/// same as asking on a `call main` that reaches it.
pub fn resolveAt(
    arena: std.mem.Allocator,
    program: analysis.GasProgram,
    offset: u32,
) std.mem.Allocator.Error!?Resolved {
    if (try declarationAt(arena, program, offset)) |hit| return hit;
    for (try collectReferences(arena, program.source, program.tree)) |r| {
        if (offset < r.span.start or offset > r.span.end) continue;
        const sym = program.symbols.get(r.key) orelse continue;
        return .{ .ref = r.span, .key = r.key, .symbol = sym };
    }
    return null;
}

/// The declaration whose name covers `offset`, for a cursor resting on
/// a `label:` or a `const NAME` rather than on a use of it.
fn declarationAt(
    arena: std.mem.Allocator,
    program: analysis.GasProgram,
    offset: u32,
) std.mem.Allocator.Error!?Resolved {
    var parent: ?[]const u8 = null;
    for (program.tree.program.statements) |stmt| {
        const name_span: gero.asm_.Span = switch (stmt) {
            .label => |l| l.name,
            .const_decl => |c| c.name,
            .data8, .data16 => |d| d.name,
            else => continue,
        };
        const text = program.source[name_span.start..name_span.end];
        if (stmt == .label and text.len > 0 and text[0] != '.') {
            if (offset >= name_span.start and offset <= name_span.end) {
                const sym = program.symbols.get(text) orelse return null;
                return .{ .ref = name_span, .key = text, .symbol = sym };
            }
            parent = text;
            continue;
        }
        if (offset < name_span.start or offset > name_span.end) continue;
        const key = try keyFor(arena, text, parent);
        const sym = program.symbols.get(key) orelse return null;
        return .{ .ref = name_span, .key = key, .symbol = sym };
    }
    return null;
}

/// Every span naming the symbol at `offset`, in source order.
///
/// `include_decl` decides whether the declaration itself is among
/// them; some editors list it, some want only the uses.
pub fn referencesTo(
    arena: std.mem.Allocator,
    program: analysis.GasProgram,
    offset: u32,
    include_decl: bool,
) std.mem.Allocator.Error!?[]const gero.asm_.Span {
    const hit = (try resolveAt(arena, program, offset)) orelse return null;

    var out: std.ArrayList(gero.asm_.Span) = .empty;
    if (include_decl) {
        if (hit.symbol.decl_start) |at| {
            // The table records where the name starts; its length is
            // the key's, or the tail past the parent for a local.
            const len: u32 = @intCast(declLen(hit.key));
            try out.append(arena, .{ .start = at, .end = at + len });
        }
    }
    for (try collectReferences(arena, program.source, program.tree)) |r| {
        if (!std.mem.eql(u8, r.key, hit.key)) continue;
        try out.append(arena, r.span);
    }
    std.mem.sort(gero.asm_.Span, out.items, {}, spanLess);
    return try out.toOwnedSlice(arena);
}

/// How many bytes a declaration's name occupies. A local label is
/// stored under `parent.name` but written as `.name`.
fn declLen(key: []const u8) usize {
    if (std.mem.lastIndexOfScalar(u8, key, '.')) |dot| return key.len - dot;
    return key.len;
}

fn spanLess(_: void, a: gero.asm_.Span, b: gero.asm_.Span) bool {
    return a.start < b.start;
}

/// Markdown describing a symbol: what kind it is, what it evaluates
/// to, and which bank holds it.
///
/// The address is the thing worth showing. In asm a name *is* its
/// value, and "what does this actually resolve to?" is the question a
/// reader has at every use site.
pub fn hoverText(
    arena: std.mem.Allocator,
    key: []const u8,
    sym: gero.asm_.Symbol,
) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "```gero-asm\n");
    switch (sym.kind) {
        .const_value => try out.appendSlice(arena, try std.fmt.allocPrint(
            arena,
            "const {s} = ${X:0>4}",
            .{ key, sym.value },
        )),
        .struct_field => try out.appendSlice(arena, try std.fmt.allocPrint(
            arena,
            "{s} = +{d}",
            .{ key, sym.value },
        )),
        .label, .data => try out.appendSlice(arena, try std.fmt.allocPrint(
            arena,
            "{s} @ ${X:0>4}",
            .{ key, sym.value },
        )),
    }
    try out.appendSlice(arena, "\n```\n\n");
    try out.appendSlice(arena, switch (sym.kind) {
        .label => "a label",
        .data => "a data block",
        .const_value => "a constant",
        .struct_field => "a struct field offset",
    });
    if (sym.bank) |b| {
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, " in bank {d}", .{b}));
    }
    return out.toOwnedSlice(arena);
}

/// One completable symbol.
pub const Completion = struct {
    name: []const u8,
    kind: gero.asm_.SymbolKind,
};

/// Every symbol the program defines, sorted by name.
pub fn completions(
    arena: std.mem.Allocator,
    program: analysis.GasProgram,
) std.mem.Allocator.Error![]const Completion {
    var out: std.ArrayList(Completion) = .empty;
    var it = program.symbols.entries.iterator();
    while (it.next()) |e| {
        try out.append(arena, .{
            .name = try arena.dupe(u8, e.key_ptr.*),
            .kind = e.value_ptr.kind,
        });
    }
    std.mem.sort(Completion, out.items, {}, completionLess);
    return out.toOwnedSlice(arena);
}

fn completionLess(_: void, a: Completion, b: Completion) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// What a symbol is, for a completion item's detail line.
pub fn kindText(k: gero.asm_.SymbolKind) []const u8 {
    return switch (k) {
        .label => "a label",
        .data => "a data block",
        .const_value => "a constant",
        .struct_field => "a struct field offset",
    };
}

/// The LSP `CompletionItemKind` for an assembler symbol.
pub fn completionKind(k: gero.asm_.SymbolKind) u8 {
    return switch (k) {
        .label => 3, // Function — a jump target behaves like one
        .data => 6, // Variable
        .const_value => 21, // Constant
        .struct_field => 5, // Field
    };
}

// ---------- positions across the fused buffer ----------

/// A span resolved back to the file that wrote it.
pub const Placed = struct {
    /// Absolute path, or `null` when the span belongs to the root
    /// buffer — a document with no file behind it has no map.
    path: ?[]const u8,
    /// The text the offsets index, which is that file's own.
    text: []const u8,
    start: u32,
    end: u32,
};

/// Resolve a fused span back to its own file and offsets.
pub fn place(program: analysis.GasProgram, span: gero.asm_.Span) Placed {
    const sm = program.source_map orelse return .{
        .path = null,
        .text = program.source,
        .start = span.start,
        .end = span.end,
    };
    const loc = sm.lookup(span.start) orelse return .{
        .path = null,
        .text = program.source,
        .start = span.start,
        .end = span.end,
    };
    return .{
        .path = loc.file.path,
        .text = loc.file.content,
        .start = loc.file_offset,
        .end = loc.file_offset + (span.end - span.start),
    };
}

/// The fused offset a document's own `offset` sits at.
///
/// The map runs fused → file, so this walks it backwards. A document
/// with no map is its own fused buffer and needs no translation.
pub fn fusedOffsetOf(
    program: analysis.GasProgram,
    path: ?[]const u8,
    offset: u32,
) ?u32 {
    const sm = program.source_map orelse return offset;
    const p = path orelse return offset;
    for (sm.regions.items) |r| {
        const file = sm.files.items[r.file_id];
        if (!std.mem.eql(u8, file.path, p)) continue;
        const span = r.fused_end - r.fused_start;
        if (offset < r.file_offset or offset >= r.file_offset + span) continue;
        return r.fused_start + (offset - r.file_offset);
    }
    return null;
}

// ---------- tests ----------

const testing = std.testing;

/// Assemble `src` as a single buffer, so fused offsets are its own.
fn programOf(arena: std.mem.Allocator, src: []const u8) !analysis.GasProgram {
    const tree = try gero.asm_.parse(arena, src);
    const cg = try gero.asm_.assemble(arena, src, tree, .{});
    return .{ .source = src, .source_map = null, .tree = tree, .symbols = cg.symbols };
}

const sample =
    "const PRINT = $10\n" ++
    "main:\n" ++
    "  mov $000A, r1\n" ++
    ".loop:\n" ++
    "  djnz r1, .loop\n" ++
    "  int PRINT\n" ++
    "  call emit\n" ++
    "  hlt\n" ++
    "emit:\n" ++
    "  int PRINT\n" ++
    "  ret\n";

/// Offset of `needle`'s first occurrence after `from`.
fn offsetOfNeedle(src: []const u8, needle: []const u8, from: usize) u32 {
    return @intCast(std.mem.indexOfPos(u8, src, from, needle).?);
}

test "resolveAt: a use resolves to the symbol it names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = try programOf(arena, sample);

    const use = offsetOfNeedle(sample, "emit", std.mem.indexOf(u8, sample, "call ").?);
    const hit = (try resolveAt(arena, p, use)) orelse return error.NoResolution;
    try testing.expectEqualStrings("emit", hit.key);
    try testing.expectEqual(gero.asm_.SymbolKind.label, hit.symbol.kind);
}

test "resolveAt: a local label resolves under its parent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = try programOf(arena, sample);

    const use = offsetOfNeedle(sample, ".loop", std.mem.indexOf(u8, sample, "djnz").?);
    const hit = (try resolveAt(arena, p, use)) orelse return error.NoResolution;
    // Written `.loop`, stored as `main.loop` — a reference and its
    // declaration have to agree on one key.
    try testing.expectEqualStrings("main.loop", hit.key);
}

test "resolveAt: a declaration resolves to itself" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = try programOf(arena, sample);

    const decl = offsetOfNeedle(sample, "emit:", 0);
    const hit = (try resolveAt(arena, p, decl)) orelse return error.NoResolution;
    try testing.expectEqualStrings("emit", hit.key);
}

test "resolveAt: a position on no name resolves to nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = try programOf(arena, sample);

    // The `hlt` mnemonic names no symbol.
    try testing.expect((try resolveAt(arena, p, offsetOfNeedle(sample, "hlt", 0))) == null);
}

test "referencesTo: a constant is found at every use" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = try programOf(arena, sample);

    const use = offsetOfNeedle(sample, "PRINT", std.mem.indexOf(u8, sample, "int ").?);
    const with = (try referencesTo(arena, p, use, true)) orelse return error.NoResolution;
    // The `const` plus both `int PRINT` sites.
    try testing.expectEqual(@as(usize, 3), with.len);

    const without = (try referencesTo(arena, p, use, false)) orelse return error.NoResolution;
    try testing.expectEqual(@as(usize, 2), without.len);
}

test "referencesTo: results come back in source order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = try programOf(arena, sample);

    const use = offsetOfNeedle(sample, "PRINT", std.mem.indexOf(u8, sample, "int ").?);
    const spans = (try referencesTo(arena, p, use, true)) orelse return error.NoResolution;
    var i: usize = 1;
    while (i < spans.len) : (i += 1) {
        try testing.expect(spans[i - 1].start < spans[i].start);
    }
}

test "referencesTo: a local label's uses do not leak across parents" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        "one:\n" ++
        ".skip:\n" ++
        "  jmp .skip\n" ++
        "two:\n" ++
        ".skip:\n" ++
        "  jmp .skip\n";
    const p = try programOf(arena, src);

    const first = offsetOfNeedle(src, ".skip", std.mem.indexOf(u8, src, "jmp").?);
    const spans = (try referencesTo(arena, p, first, true)) orelse return error.NoResolution;
    // `one.skip`, not `two.skip` — two locals of the same spelling are
    // different labels.
    try testing.expectEqual(@as(usize, 2), spans.len);
    try testing.expect(spans[1].start < std.mem.indexOf(u8, src, "two:").?);
}

test "hoverText: a label shows the address it assembled to" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = try programOf(arena, sample);

    const use = offsetOfNeedle(sample, "emit", std.mem.indexOf(u8, sample, "call ").?);
    const hit = (try resolveAt(arena, p, use)) orelse return error.NoResolution;
    const text = try hoverText(arena, hit.key, hit.symbol);
    try testing.expect(std.mem.indexOf(u8, text, "emit @ $") != null);
    try testing.expect(std.mem.indexOf(u8, text, "a label") != null);
}

test "hoverText: a constant shows its folded value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = try programOf(arena, sample);

    const use = offsetOfNeedle(sample, "PRINT", std.mem.indexOf(u8, sample, "int ").?);
    const hit = (try resolveAt(arena, p, use)) orelse return error.NoResolution;
    const text = try hoverText(arena, hit.key, hit.symbol);
    try testing.expect(std.mem.indexOf(u8, text, "const PRINT = $0010") != null);
    try testing.expect(std.mem.indexOf(u8, text, "a constant") != null);
}

test "completions: every symbol the program defines is offered" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = try programOf(arena, sample);

    const items = try completions(arena, p);
    var saw_label = false;
    var saw_const = false;
    var saw_local = false;
    for (items) |c| {
        if (std.mem.eql(u8, c.name, "emit")) saw_label = true;
        if (std.mem.eql(u8, c.name, "PRINT")) saw_const = true;
        if (std.mem.eql(u8, c.name, "main.loop")) saw_local = true;
    }
    try testing.expect(saw_label);
    try testing.expect(saw_const);
    try testing.expect(saw_local);
}

test "keyFor: a global name is its own key" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("main", try keyFor(arena, "main", null));
    try testing.expectEqualStrings("main", try keyFor(arena, "main", "other"));
    try testing.expectEqualStrings("main.loop", try keyFor(arena, ".loop", "main"));
    // A local with no enclosing label has nothing to mangle against.
    try testing.expectEqualStrings(".loop", try keyFor(arena, ".loop", null));
}

test "collectReferences: a data directive's symbol is a reference" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        "const BASE = $2000\n" ++
        "target:\n" ++
        "  hlt\n" ++
        "data16 PTR = @target\n" ++
        "data16 OFF = BASE\n";
    const p = try programOf(arena, src);

    // `data16 X = @label` is how a program reaches a label's address,
    // so it has to count as a use of it.
    const label = offsetOfNeedle(src, "target", 0);
    const to_label = (try referencesTo(arena, p, label, true)) orelse return error.NoResolution;
    try testing.expectEqual(@as(usize, 2), to_label.len);

    const konst = offsetOfNeedle(src, "BASE", 0);
    const to_const = (try referencesTo(arena, p, konst, true)) orelse return error.NoResolution;
    try testing.expectEqual(@as(usize, 2), to_const.len);
}

test "collectReferences: an `org` operand is a reference" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        "const START = $0200\n" ++
        "org START\n" ++
        "main:\n" ++
        "  hlt\n";
    const p = try programOf(arena, src);

    const konst = offsetOfNeedle(src, "START", 0);
    const spans = (try referencesTo(arena, p, konst, true)) orelse return error.NoResolution;
    try testing.expectEqual(@as(usize, 2), spans.len);
}
