// Diagnostic emission + symbol-suggestion helpers. The thin layer every
// checking pass funnels errors and "did you mean" hints through.

const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const diag_mod = @import("../diagnostic.zig");
const typecheck = @import("../typecheck.zig");
const suggestions = @import("suggestions.zig");
const relations = @import("relations.zig");
const scope_mod = @import("../scope.zig");

const Checker = typecheck.Checker;
const Scope = scope_mod.Scope;
const WalkError = error{OutOfMemory};

/// Emit a fatal diagnostic at `span`.
pub fn emitSpan(
    self: *Checker,
    code: []const u8,
    span: ast.Span,
    message: []const u8,
) WalkError!void {
    try self.diagnostics.append(self.diag_alloc, .{
        .severity = .fatal,
        .code = code,
        .message = message,
        .span = span,
    });
}

/// Like `emitSpan` plus a `help:` block.
pub fn emitSpanHelp(
    self: *Checker,
    code: []const u8,
    span: ast.Span,
    message: []const u8,
    help: []const u8,
) WalkError!void {
    try self.diagnostics.append(self.diag_alloc, .{
        .severity = .fatal,
        .code = code,
        .message = message,
        .span = span,
        .help = help,
    });
}

/// Emit `E_TYPE_MISMATCH` for an expected-vs-actual mismatch
/// at a single span.
pub fn emitMismatch(
    self: *Checker,
    span: ast.Span,
    expected_ty: *const types.Type,
    actual_ty: *const types.Type,
) WalkError!void {
    const expected_s = try types.render(self.arena, expected_ty.*);
    const actual_s = try types.render(self.arena, actual_ty.*);
    const msg = try std.fmt.allocPrint(
        self.arena,
        "type mismatch: expected `{s}`, found `{s}`",
        .{ expected_s, actual_s },
    );
    try self.emitSpan("E_TYPE_MISMATCH", span, msg);
}

/// Like `emitMismatch` but anchors the expected type to a
/// `: T` annotation span via a secondary label.
pub fn emitMismatchAnnotated(
    self: *Checker,
    span: ast.Span,
    expected_ty: *const types.Type,
    actual_ty: *const types.Type,
    annotation_span: ast.Span,
) WalkError!void {
    const expected_s = try types.render(self.arena, expected_ty.*);
    const actual_s = try types.render(self.arena, actual_ty.*);
    const msg = try std.fmt.allocPrint(
        self.arena,
        "type mismatch: expected `{s}`, found `{s}`",
        .{ expected_s, actual_s },
    );
    const label_msg = try std.fmt.allocPrint(
        self.arena,
        "expected `{s}` because of this annotation",
        .{expected_s},
    );
    const sec = try self.singleSecondary(annotation_span, label_msg, .underline);
    try self.diagnostics.append(self.diag_alloc, .{
        .severity = .fatal,
        .code = "E_TYPE_MISMATCH",
        .message = msg,
        .span = span,
        .secondary = sec,
    });
}

/// Allocate a one-element `SpanLabel` slice on `self.arena`,
/// suitable for `Diagnostic.secondary`.
pub fn singleSecondary(
    self: *Checker,
    span: ast.Span,
    message: []const u8,
    decoration: diag_mod.SpanLabel.Decoration,
) WalkError![]const diag_mod.SpanLabel {
    const sec = try self.arena.alloc(diag_mod.SpanLabel, 1);
    sec[0] = .{ .span = span, .message = message, .decoration = decoration };
    return sec;
}

/// Assignability + narrowing check for "store into a typed
/// slot" sites (let-init, assignment, call arg, return).
/// Routes per spec §3.5.1:
/// - Assignable → no diagnostic.
/// - Integer narrowing without `as` → `E_CAST_PRECISION_LOSS`
///   (warning).
/// - Otherwise → `E_TYPE_MISMATCH` (fatal).
pub fn checkStoreCompat(
    self: *Checker,
    span: ast.Span,
    expected: *const types.Type,
    actual: *const types.Type,
) WalkError!void {
    if (relations.assignable(actual.*, expected.*)) return;
    if (self.isClassSubtype(actual.*, expected.*)) return;
    if (relations.isNarrowingInt(actual.*, expected.*)) {
        try emitNarrowingWarning(self, span, expected, actual);
        return;
    }
    try self.emitMismatch(span, expected, actual);
}

/// `true` when `actual` is a class derived from `expected`
/// (transitively, via `extends`). Also covers `&Sub` → `&Sup`
/// reference subtyping by peeling one layer per side.
pub fn isClassSubtype(self: *const Checker, actual: types.Type, expected: types.Type) bool {
    const a = if (actual == .reference) actual.reference.* else actual;
    const e = if (expected == .reference) expected.reference.* else expected;
    if (a != .named or e != .named) return false;
    const expected_name = e.named.name;
    var cur = self.class_registry.get(a.named.name) orelse return false;
    while (cur.extends) |ext| {
        const parent_name = self.lexeme(ext);
        if (std.mem.eql(u8, parent_name, expected_name)) return true;
        cur = self.class_registry.get(parent_name) orelse return false;
    }
    return false;
}

fn emitNarrowingWarning(
    self: *Checker,
    span: ast.Span,
    expected_ty: *const types.Type,
    actual_ty: *const types.Type,
) WalkError!void {
    const expected_s = try types.render(self.arena, expected_ty.*);
    const actual_s = try types.render(self.arena, actual_ty.*);
    const msg = try std.fmt.allocPrint(
        self.arena,
        "implicit narrowing from `{s}` to `{s}` may lose precision — use an explicit `as {s}` cast to silence this warning",
        .{ actual_s, expected_s, expected_s },
    );
    try self.diagnostics.append(self.diag_alloc, .{
        .severity = .warning,
        .code = "E_CAST_PRECISION_LOSS",
        .message = msg,
        .span = span,
    });
}

/// Return the source-text slice for `span`.
pub fn lexeme(self: *const Checker, span: ast.Span) []const u8 {
    return self.source[span.start..span.end];
}

/// Closest near-spelling match for an undefined symbol across
/// the scope chain + type registries. `null` when nothing is
/// within `suggestions.max_distance`.
pub fn suggestSymbol(self: *Checker, name: []const u8) WalkError!?[]const u8 {
    var pool: std.ArrayList([]const u8) = .empty;
    defer pool.deinit(self.arena);
    var scope: ?*const Scope = self.current_scope;
    while (scope) |s| : (scope = s.parent) {
        var it = s.entries.keyIterator();
        while (it.next()) |k| try pool.append(self.arena, k.*);
    }
    return suggestions.bestMatch(name, pool.items);
}

/// Same pool as `suggestSymbol` plus the primitive type names —
/// used by `E_TYPE_UNDEFINED` when an unknown type name shows
/// up in an annotation / struct-lit position.
pub fn suggestTypeName(self: *Checker, name: []const u8) WalkError!?[]const u8 {
    var pool: std.ArrayList([]const u8) = .empty;
    defer pool.deinit(self.arena);
    // Primitives matched first so `let x: i8` wins over a stray
    // `i9` local. Mirrors `types.primitiveFromName`.
    const primitives = [_][]const u8{ "i8", "u8", "i16", "u16", "int", "uint", "bool", "nil", "str", "fixed", "char" };
    for (primitives) |p| try pool.append(self.arena, p);
    var struct_it = self.struct_registry.keyIterator();
    while (struct_it.next()) |k| try pool.append(self.arena, k.*);
    var class_it = self.class_registry.keyIterator();
    while (class_it.next()) |k| try pool.append(self.arena, k.*);
    var enum_it = self.enum_registry.keyIterator();
    while (enum_it.next()) |k| try pool.append(self.arena, k.*);
    return suggestions.bestMatch(name, pool.items);
}

/// Best-match field name on a struct.
pub fn suggestStructField(self: *Checker, sd: *const ast.StructDecl, name: []const u8) WalkError!?[]const u8 {
    var pool: std.ArrayList([]const u8) = .empty;
    defer pool.deinit(self.arena);
    for (sd.fields) |f| try pool.append(self.arena, self.lexeme(f.name));
    return suggestions.bestMatch(name, pool.items);
}

/// Best-match field name across a class and its parents.
pub fn suggestClassField(self: *Checker, cd: *const ast.ClassDecl, name: []const u8) WalkError!?[]const u8 {
    var pool: std.ArrayList([]const u8) = .empty;
    defer pool.deinit(self.arena);
    var cur: ?*const ast.ClassDecl = cd;
    while (cur) |c| {
        for (c.fields) |f| try pool.append(self.arena, self.lexeme(f.name));
        cur = if (c.extends) |ext| self.class_registry.get(self.lexeme(ext)) else null;
    }
    return suggestions.bestMatch(name, pool.items);
}

/// Best-match method name across a class and its parents.
pub fn suggestClassMethod(self: *Checker, cd: *const ast.ClassDecl, name: []const u8) WalkError!?[]const u8 {
    var pool: std.ArrayList([]const u8) = .empty;
    defer pool.deinit(self.arena);
    var cur: ?*const ast.ClassDecl = cd;
    while (cur) |c| {
        for (c.methods) |m| try pool.append(self.arena, self.lexeme(m.name));
        cur = if (c.extends) |ext| self.class_registry.get(self.lexeme(ext)) else null;
    }
    return suggestions.bestMatch(name, pool.items);
}

/// Emit a fatal diagnostic; appends `help: did you mean \`X\`?`
/// when `candidate` is non-null.
pub fn emitSpanWithSuggestion(
    self: *Checker,
    code: []const u8,
    span: ast.Span,
    message: []const u8,
    candidate: ?[]const u8,
) WalkError!void {
    const name = candidate orelse return self.emitSpan(code, span, message);
    const help = try std.fmt.allocPrint(self.arena, "did you mean `{s}`?", .{name});
    try self.emitSpanHelp(code, span, message, help);
}
