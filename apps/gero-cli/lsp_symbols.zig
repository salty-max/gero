//! What the name under a cursor resolves to.
//!
//! The type-checker records every reference's binding (`lang.Binding`),
//! keyed by the reference's start offset. An editor asks in line and
//! character and wants a range back, so this is the translation between
//! the two, plus the lookup in between.
//!
//! Nothing here re-derives anything: a second implementation of name
//! resolution would agree with whatever its author believed rather than
//! with the checker, which is the drift `docs/lsp.md` §6 was written to
//! avoid.

const std = @import("std");
const gero = @import("gero");

const analysis = @import("lsp_analysis.zig");

/// A zero-based LSP position.
pub const Position = struct {
    line: u32,
    character: u32,
};

/// A resolved reference: where it is, and what it names.
pub const Resolved = struct {
    /// The reference's own span, so the editor can highlight it.
    ref: gero.lang.ast.Span,
    /// The declaration it binds to.
    binding: gero.lang.Binding,
    /// The reference's inferred type, rendered, when there is one.
    /// Absent for a name the checker could not type — which is normal
    /// in a buffer the user is still writing.
    type_text: ?[]const u8,
};

/// Byte offset of a zero-based line/character pair.
///
/// Characters are counted as UTF-8 bytes rather than UTF-16 code
/// units. The two agree for ASCII, which every `.gr` and `.gas`
/// keyword and identifier is; a multi-byte character earlier on the
/// line shifts the result, and the caller lands on a neighbouring
/// byte rather than on nothing.
pub fn offsetOf(src: []const u8, pos: Position) ?u32 {
    var line: u32 = 0;
    var i: usize = 0;
    while (line < pos.line) : (i += 1) {
        if (i >= src.len) return null;
        if (src[i] == '\n') line += 1;
    }
    const col_end = @min(i + pos.character, src.len);
    // @as: an offset into a source buffer, bounded by the file size.
    return @intCast(col_end);
}

/// Zero-based line/character of a byte offset.
pub fn positionOf(src: []const u8, offset: u32) Position {
    var line: u32 = 0;
    var last_nl: usize = 0;
    var i: usize = 0;
    const target = @min(@as(usize, offset), src.len);
    while (i < target) : (i += 1) {
        if (src[i] == '\n') {
            line += 1;
            last_nl = i + 1;
        }
    }
    // @as: a column within one line, bounded by the file size.
    return .{ .line = line, .character = @intCast(target - last_nl) };
}

/// The binding whose reference covers `offset`.
///
/// Bindings are keyed by a reference's first byte, and a cursor is
/// usually somewhere in the middle of the word it is on, so this scans
/// for the entry whose span contains the offset rather than indexing
/// directly.
pub fn bindingAt(
    checked: *const gero.lang.CheckedProgram,
    src: []const u8,
    offset: u32,
) ?struct { ref: gero.lang.ast.Span, binding: gero.lang.Binding } {
    const start = wordStart(src, offset) orelse return null;
    if (checked.bindings.get(start)) |b| {
        return .{ .ref = .{ .start = start, .end = start + wordLen(src, start) }, .binding = b };
    }
    return null;
}

/// First byte of the identifier `offset` sits in, or null when it sits
/// on something that is not one.
fn wordStart(src: []const u8, offset: u32) ?u32 {
    const at = @min(@as(usize, offset), src.len);
    if (at >= src.len or !isWordByte(src[at])) {
        // A cursor just past the last character still means that word,
        // which is where it lands after typing one.
        if (at == 0 or !isWordByte(src[at - 1])) return null;
    }
    var i = at;
    if (i == src.len or !isWordByte(src[i])) i -= 1;
    while (i > 0 and isWordByte(src[i - 1])) i -= 1;
    // @as: an offset into a source buffer.
    return @intCast(i);
}

fn wordLen(src: []const u8, start: u32) u32 {
    var i: usize = start;
    while (i < src.len and isWordByte(src[i])) i += 1;
    // @as: a single identifier's length.
    return @intCast(i - start);
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Resolve the name at `pos` in a `.gr` buffer.
///
/// Re-checks the buffer: a language server is asked this while the
/// user types, so the answer has to come from the text in the editor
/// rather than from whatever was last saved. `arena` owns everything
/// returned.
pub fn resolveGr(
    arena: std.mem.Allocator,
    src: []const u8,
    pos: Position,
) !?Resolved {
    const offset = offsetOf(src, pos) orelse return null;

    const stream = try gero.lang.tokenize(arena, src);
    const tree = try gero.lang.parse(arena, src, stream);
    var checked = try gero.lang.typecheck(arena, src, &tree.program);
    // A `CheckedProgram` owns its own arena, so what it hands back
    // dies with it. Everything the caller keeps is copied into
    // `arena` first, and the program is released on the way out
    // rather than left to the request arena to mop up.
    defer checked.deinit();

    const hit = bindingAt(&checked, src, offset) orelse return null;
    const type_text = try typeTextAt(arena, &checked, hit.ref.start);
    return .{
        .ref = hit.ref,
        .binding = .{
            .kind = hit.binding.kind,
            .decl_span = hit.binding.decl_span,
            .name = try arena.dupe(u8, hit.binding.name),
            .module = if (hit.binding.module) |m| try arena.dupe(u8, m) else null,
        },
        .type_text = type_text,
    };
}

/// The rendered type of the expression starting at `start`, when the
/// checker inferred one.
fn typeTextAt(
    arena: std.mem.Allocator,
    checked: *const gero.lang.CheckedProgram,
    start: u32,
) !?[]const u8 {
    var it = checked.expr_types.iterator();
    while (it.next()) |e| {
        if (e.key_ptr.*.span().start == start) {
            // Rendered into `arena` so it outlives the program below.
            return try gero.lang.types.render(arena, e.value_ptr.*.*);
        }
    }
    return null;
}

/// An inferred type to show after a binder the source did not annotate.
pub const Hint = struct {
    /// Just past the binder's name, where `: T` would have been typed.
    at: u32,
    /// The rendered type, without the leading colon.
    text: []const u8,
};

/// Inferred types for every `let` the source left unannotated.
///
/// Only unannotated binders get one: repeating a type the author
/// already wrote is noise, and the point of a hint is to show what was
/// inferred rather than what was stated. `binder_types` supplies the
/// type, keyed by the declaring identifier's offset — which is also
/// where the hint belongs.
pub fn inlayHints(arena: std.mem.Allocator, src: []const u8) ![]Hint {
    const stream = try gero.lang.tokenize(arena, src);
    const tree = try gero.lang.parse(arena, src, stream);
    var checked = try gero.lang.typecheck(arena, src, &tree.program);
    defer checked.deinit();

    var out: std.ArrayList(Hint) = .empty;
    try collectHints(arena, &out, &checked, tree.program.statements);
    return out.toOwnedSlice(arena);
}

fn collectHints(
    arena: std.mem.Allocator,
    out: *std.ArrayList(Hint),
    checked: *const gero.lang.CheckedProgram,
    statements: []const gero.lang.ast.Statement,
) !void {
    for (statements) |st| switch (st) {
        .let_decl => |d| {
            // An annotated binder already says what it is.
            if (d.type_ann != null) continue;
            if (d.pattern.* != .ident) continue;
            const name = d.pattern.ident.name;
            const ty = checked.binder_types.get(name.start) orelse continue;
            try out.append(arena, .{
                .at = name.end,
                .text = try gero.lang.types.render(arena, ty.*),
            });
        },
        .def_decl => |d| try collectHints(arena, out, checked, d.body),
        .block => |b| try collectHints(arena, out, checked, b.body),
        .while_stmt => |w| try collectHints(arena, out, checked, w.body),
        .for_stmt => |f| try collectHints(arena, out, checked, f.body),
        else => {},
    };
}

/// Every reference to the declaration the name at `pos` binds to.
///
/// The binding table read backwards: each entry names the declaration
/// its reference resolves to, so the references to one declaration are
/// the entries pointing at it. Nothing is re-derived, so this cannot
/// disagree with go-to-definition about what binds to what.
pub fn referencesTo(
    arena: std.mem.Allocator,
    src: []const u8,
    pos: Position,
    include_declaration: bool,
) !?[]gero.lang.ast.Span {
    const offset = offsetOf(src, pos) orelse return null;

    const stream = try gero.lang.tokenize(arena, src);
    const tree = try gero.lang.parse(arena, src, stream);
    var checked = try gero.lang.typecheck(arena, src, &tree.program);
    defer checked.deinit();

    // The cursor may be on a reference or on the declaration itself.
    // Both have to reach the same declaration or the two cases would
    // return different sets for the same name.
    const target: gero.lang.ast.Span = if (bindingAt(&checked, src, offset)) |hit|
        hit.binding.decl_span
    else blk: {
        const start = wordStart(src, offset) orelse return null;
        break :blk .{ .start = start, .end = start + wordLen(src, start) };
    };

    var out: std.ArrayList(gero.lang.ast.Span) = .empty;
    var it = checked.bindings.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.decl_span.start != target.start) continue;
        const start = e.key_ptr.*;
        try out.append(arena, .{ .start = start, .end = start + wordLen(src, start) });
    }
    if (include_declaration) try out.append(arena, target);

    // Ascending, so the results list reads in source order rather than
    // in whatever order the map happened to store them.
    std.mem.sort(gero.lang.ast.Span, out.items, {}, spanLess);
    return try out.toOwnedSlice(arena);
}

fn spanLess(_: void, a: gero.lang.ast.Span, b: gero.lang.ast.Span) bool {
    return a.start < b.start;
}
