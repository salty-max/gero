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

/// A name an editor may offer at a position.
pub const Completion = struct {
    name: []const u8,
    kind: gero.lang.scope.SymbolKind,
};

/// Names visible at `pos`.
///
/// A name is offered when the scope it was declared in covers the
/// cursor, and when it was declared before the cursor — a `let` is not
/// in scope on the line above itself. Module-level declarations carry
/// no scope range and are visible throughout the file, including
/// before the line that declares them, which is how `def` works.
pub fn completionsAt(
    arena: std.mem.Allocator,
    src: []const u8,
    pos: Position,
) ![]Completion {
    const offset = offsetOf(src, pos) orelse return &.{};

    const stream = try gero.lang.tokenize(arena, src);
    const tree = try gero.lang.parse(arena, src, stream);
    var checked = try gero.lang.typecheck(arena, src, &tree.program);
    defer checked.deinit();

    // After a dot, only the receiver's members can follow. Offering
    // what happens to be in scope there is worse than offering
    // nothing: none of it can legally appear.
    if (receiverBefore(src, offset)) |recv| {
        return try membersOf(arena, &checked, src, recv);
    }

    var seen: std.StringHashMapUnmanaged(void) = .{};
    var out: std.ArrayList(Completion) = .empty;
    for (checked.visible) |v| {
        if (v.scope_span) |sp| {
            if (offset < sp.start or offset > sp.end) continue;
            // A local is not in scope above its own declaration.
            if (offset < v.decl_span.start) continue;
        }
        // The innermost declaration of a shadowed name is the one the
        // checker met last, so a later entry replaces an earlier one.
        const gop = try seen.getOrPut(arena, v.name);
        if (gop.found_existing) continue;
        try out.append(arena, .{
            .name = try arena.dupe(u8, v.name),
            .kind = v.kind,
        });
    }
    std.mem.sort(Completion, out.items, {}, completionLess);
    return out.toOwnedSlice(arena);
}

fn completionLess(_: void, a: Completion, b: Completion) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// The LSP `CompletionItemKind` for a declaration.
pub fn completionKind(k: gero.lang.scope.SymbolKind) u8 {
    return switch (k) {
        .let_binding, .const_binding => 6, // Variable
        .param => 6,
        .function => 3, // Function
        .class => 7, // Class
        .struct_ => 22, // Struct
        .enum_ => 13, // Enum
        .module_alias, .imported => 9, // Module
        .field => 5, // Field
    };
}

/// The identifier immediately before a `.` the cursor sits after, or
/// null when the cursor does not follow one.
///
/// Read from the text rather than the tree: the tree at this instant
/// describes `p.` with an empty member, and what is wanted is the
/// receiver beside the dot, which the characters give directly.
fn receiverBefore(src: []const u8, offset: u32) ?gero.lang.ast.Span {
    var i: usize = @min(@as(usize, offset), src.len);
    // Step back over a partly-typed member name.
    while (i > 0 and isWordByte(src[i - 1])) i -= 1;
    if (i == 0 or src[i - 1] != '.') return null;
    const dot = i - 1;
    var j = dot;
    while (j > 0 and isWordByte(src[j - 1])) j -= 1;
    if (j == dot) return null;
    // @as: offsets into a source buffer.
    return .{ .start = @intCast(j), .end = @intCast(dot) };
}

/// Members of whatever `recv` names — a value's type, or a container
/// named directly, as in `Colour.Red`.
fn membersOf(
    arena: std.mem.Allocator,
    checked: *const gero.lang.CheckedProgram,
    src: []const u8,
    recv: gero.lang.ast.Span,
) ![]Completion {
    const text = src[recv.start..recv.end];

    // `Point.` — the receiver is the container itself.
    var owner: []const u8 = text;
    // `p.` — the receiver is a value, so its type names the container.
    if (checked.bindings.get(recv.start)) |b| {
        if (checked.binder_types.get(b.decl_span.start)) |ty| {
            if (namedOf(ty.*)) |n| owner = n;
        }
    }

    var out: std.ArrayList(Completion) = .empty;
    for (checked.members) |m| {
        if (!std.mem.eql(u8, m.owner, owner)) continue;
        try out.append(arena, .{ .name = try arena.dupe(u8, m.name), .kind = m.kind });
    }
    std.mem.sort(Completion, out.items, {}, completionLess);
    return out.toOwnedSlice(arena);
}

/// The container name a type refers to, looking through a reference or
/// an optional so `p` and `p?` offer the same members.
fn namedOf(t: gero.lang.types.Type) ?[]const u8 {
    return switch (t) {
        .named => |n| n.name,
        .reference => |r| namedOf(r.*),
        .optional => |o| namedOf(o.*),
        else => null,
    };
}

// ---------- code actions ----------

/// One quick-fix the editor can offer: a title to show, and the edit
/// that applies it.
pub const CodeAction = struct {
    title: []const u8,
    /// The diagnostic this fixes, so the editor can pair them.
    diagnostic: analysis.Diagnostic,
    /// Range the edit replaces. The diagnostic's own span for a
    /// rename, a zero-width point for an inserted import, the whole
    /// line for a removed one.
    start: Position,
    end: Position,
    /// Text that replaces `start`..`end`. Empty for a removal.
    new_text: []const u8,
};

/// Quick-fixes for every diagnostic overlapping the requested range
/// that the checker worked out a correction for.
///
/// The correction is the checker's own `fix`. Nothing here decides
/// *what* to change, so an action can never disagree with the
/// diagnostic that offered it. What this does decide is where the
/// text goes, which is a property of the buffer rather than of the
/// program: an import belongs after the `use` lines already there.
pub fn codeActionsAt(
    arena: std.mem.Allocator,
    text: []const u8,
    diags: []const analysis.Diagnostic,
    start: Position,
    end: Position,
) std.mem.Allocator.Error![]const CodeAction {
    var out: std.ArrayList(CodeAction) = .empty;
    for (diags) |d| {
        const fix = d.fix orelse continue;
        if (!overlaps(d, start, end)) continue;
        switch (fix) {
            .rename => |name| try out.append(arena, .{
                .title = try std.fmt.allocPrint(arena, "Change to `{s}`", .{name}),
                .diagnostic = d,
                .start = .{ .line = d.line, .character = d.character },
                .end = .{ .line = d.end_line, .character = d.end_character },
                .new_text = name,
            }),
            .import => |imp| {
                const at = useInsertLine(text);
                try out.append(arena, .{
                    .title = try std.fmt.allocPrint(arena, "Import `{s}` from {s}", .{ imp.name, imp.module }),
                    .diagnostic = d,
                    .start = .{ .line = at, .character = 0 },
                    .end = .{ .line = at, .character = 0 },
                    .new_text = try std.fmt.allocPrint(arena, "use {s} from {s}\n", .{ imp.name, imp.module }),
                });
            },
            .remove_import => try out.append(arena, .{
                .title = "Remove unused import",
                .diagnostic = d,
                // Through to the start of the next line, so the blank
                // the line occupied goes with it.
                .start = .{ .line = d.line, .character = 0 },
                .end = .{ .line = d.line + 1, .character = 0 },
                .new_text = "",
            }),
        }
    }
    return out.toOwnedSlice(arena);
}

/// The line a new `use` belongs on: after the last one already at the
/// top of the file, else above the first line of actual code.
///
/// Only the run of `use` lines the file opens with counts. A `use`
/// further down is unusual enough that following it would scatter the
/// imports rather than group them.
fn useInsertLine(text: []const u8) u32 {
    var line: u32 = 0;
    var after_last_use: u32 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| : (line += 1) {
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (trimmed.len == 0) continue;
        // A leading comment block belongs above the imports.
        if (std.mem.startsWith(u8, trimmed, "--")) continue;
        if (isUseLine(trimmed)) {
            after_last_use = line + 1;
            continue;
        }
        break;
    }
    return after_last_use;
}

/// `true` when `trimmed` opens with the `use` keyword rather than an
/// identifier that merely starts with those letters (`user`).
fn isUseLine(trimmed: []const u8) bool {
    if (!std.mem.startsWith(u8, trimmed, "use")) return false;
    if (trimmed.len == 3) return true;
    return trimmed[3] == ' ' or trimmed[3] == '\t' or trimmed[3] == '"';
}

/// Whether a diagnostic's range intersects `start`..`end`. An editor
/// asks with the selection, which is usually an empty range at the
/// cursor, so touching at an endpoint counts.
fn overlaps(d: analysis.Diagnostic, start: Position, end: Position) bool {
    return !before(d.end_line, d.end_character, start.line, start.character) and
        !before(end.line, end.character, d.line, d.character);
}

fn before(l0: u32, c0: u32, l1: u32, c1: u32) bool {
    return l0 < l1 or (l0 == l1 and c0 < c1);
}

fn diagAt(l0: u32, c0: u32, c1: u32, fix: ?gero.lang.Fix) analysis.Diagnostic {
    return .{
        .line = l0,
        .character = c0,
        .end_line = l0,
        .end_character = c1,
        .severity = 1,
        .code = "E_UNDEFINED_SYMBOL",
        .message = "undefined symbol",
        .fix = fix,
    };
}

test "codeActionsAt: a diagnostic with a suggestion offers replacing its own range" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const diags = [_]analysis.Diagnostic{diagAt(2, 15, 21, .{ .rename = "helo" })};
    const actions = try codeActionsAt(arena, "", &diags, .{ .line = 2, .character = 17 }, .{ .line = 2, .character = 17 });
    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("helo", actions[0].new_text);
    try std.testing.expectEqualStrings("Change to `helo`", actions[0].title);
    try std.testing.expectEqual(@as(u32, 15), actions[0].diagnostic.character);
}

test "codeActionsAt: a diagnostic the checker worked out no fix for offers nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const diags = [_]analysis.Diagnostic{diagAt(2, 15, 21, null)};
    const actions = try codeActionsAt(arena, "", &diags, .{ .line = 2, .character = 17 }, .{ .line = 2, .character = 17 });
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "codeActionsAt: a diagnostic elsewhere in the file is not offered" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const diags = [_]analysis.Diagnostic{diagAt(2, 15, 21, .{ .rename = "helo" })};
    const actions = try codeActionsAt(arena, "", &diags, .{ .line = 5, .character = 0 }, .{ .line = 5, .character = 4 });
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "codeActionsAt: a caret resting on either end of the span still matches" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const diags = [_]analysis.Diagnostic{diagAt(2, 15, 21, .{ .rename = "helo" })};
    const at_start = try codeActionsAt(arena, "", &diags, .{ .line = 2, .character = 15 }, .{ .line = 2, .character = 15 });
    try std.testing.expectEqual(@as(usize, 1), at_start.len);
    const at_end = try codeActionsAt(arena, "", &diags, .{ .line = 2, .character = 21 }, .{ .line = 2, .character = 21 });
    try std.testing.expectEqual(@as(usize, 1), at_end.len);
    const past_end = try codeActionsAt(arena, "", &diags, .{ .line = 2, .character = 22 }, .{ .line = 2, .character = 22 });
    try std.testing.expectEqual(@as(usize, 0), past_end.len);
}

test "codeActionsAt: a selection spanning several typos offers a fix for each" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const diags = [_]analysis.Diagnostic{
        diagAt(2, 15, 21, .{ .rename = "helo" }),
        diagAt(3, 4, 8, .{ .rename = "total" }),
    };
    const actions = try codeActionsAt(arena, "", &diags, .{ .line = 2, .character = 0 }, .{ .line = 3, .character = 20 });
    try std.testing.expectEqual(@as(usize, 2), actions.len);
}

test "codeActionsAt: an import fix inserts a `use` line rather than rewriting the name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text =
        \\def main()
        \\  print abs(0 - 1)
        \\end
        \\
    ;
    const diags = [_]analysis.Diagnostic{diagAt(1, 8, 11, .{ .import = .{ .module = "math", .name = "abs" } })};
    const actions = try codeActionsAt(arena, text, &diags, .{ .line = 1, .character = 9 }, .{ .line = 1, .character = 9 });
    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Import `abs` from math", actions[0].title);
    try std.testing.expectEqualStrings("use abs from math\n", actions[0].new_text);
    // Inserted at the top, as a zero-width edit.
    try std.testing.expectEqual(@as(u32, 0), actions[0].start.line);
    try std.testing.expectEqual(actions[0].start.line, actions[0].end.line);
    try std.testing.expectEqual(actions[0].start.character, actions[0].end.character);
}

test "codeActionsAt: an import lands below the `use` lines already there" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text =
        \\-- a leading comment
        \\
        \\use peek from mem
        \\use poke from mem
        \\
        \\def main()
        \\  print abs(0 - 1)
        \\end
        \\
    ;
    const diags = [_]analysis.Diagnostic{diagAt(6, 8, 11, .{ .import = .{ .module = "math", .name = "abs" } })};
    const actions = try codeActionsAt(arena, text, &diags, .{ .line = 6, .character = 9 }, .{ .line = 6, .character = 9 });
    try std.testing.expectEqual(@as(usize, 1), actions.len);
    // Line 4 — after `use poke from mem`, not above the comment.
    try std.testing.expectEqual(@as(u32, 4), actions[0].start.line);
}

test "codeActionsAt: a removal deletes the whole line it sits on" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text =
        \\use min from math
        \\def main()
        \\  print 1
        \\end
        \\
    ;
    const diags = [_]analysis.Diagnostic{diagAt(0, 4, 7, .remove_import)};
    const actions = try codeActionsAt(arena, text, &diags, .{ .line = 0, .character = 5 }, .{ .line = 0, .character = 5 });
    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Remove unused import", actions[0].title);
    try std.testing.expectEqualStrings("", actions[0].new_text);
    // Column 0 through the start of the next line, so no blank is left.
    try std.testing.expectEqual(@as(u32, 0), actions[0].start.line);
    try std.testing.expectEqual(@as(u32, 0), actions[0].start.character);
    try std.testing.expectEqual(@as(u32, 1), actions[0].end.line);
    try std.testing.expectEqual(@as(u32, 0), actions[0].end.character);
}

test "useInsertLine: a file whose first line is code takes the import above it" {
    try std.testing.expectEqual(@as(u32, 0), useInsertLine("def main()\n  print 1\nend\n"));
}

test "useInsertLine: `user` is not mistaken for a `use` directive" {
    try std.testing.expectEqual(@as(u32, 0), useInsertLine("user_thing()\n"));
}
