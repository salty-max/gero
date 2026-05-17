/// `match` typechecking — walks each arm's pattern, validates
/// arm-body bindings, and runs the exhaustiveness +
/// reachability checks for enum-typed scrutinees.
const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const scope_mod = @import("../scope.zig");
const typecheck = @import("../typecheck.zig");

const Scope = scope_mod.Scope;
const Checker = typecheck.Checker;
const WalkError = error{OutOfMemory};

/// Type-check a `match` statement: infer the scrutinee type,
/// walk every arm's pattern + guard + body, and (for enum
/// scrutinees) check that every variant is covered.
pub fn checkMatch(self: *Checker, ms: ast.MatchStmt) WalkError!void {
    const scrut_ty = try self.inferExpr(ms.scrutinee, null);

    // Lookup enum decl when scrutinee resolves to a named-enum.
    const enum_decl: ?*const ast.EnumDecl = if (scrut_ty) |st|
        enumDeclForType(self, st.*)
    else
        null;

    // Track variant-name coverage when scrutinee is an enum.
    var covered: std.StringHashMapUnmanaged(void) = .{};
    defer covered.deinit(self.arena);
    var has_wildcard: bool = false;

    for (ms.arms) |arm| {
        // Exhaustiveness + reachability checks (enum scrutinee only).
        if (enum_decl) |ed| try recordArmCoverage(self, arm, ed, &covered, &has_wildcard);

        const saved = self.current_scope;
        var child: Scope = .init(self.arena, saved);
        self.current_scope = &child;
        defer self.current_scope = saved;
        try self.registerPatternBindings(arm.pattern);
        if (arm.guard) |g| _ = try self.inferExpr(g, null);
        try self.walkStatementSequence(arm.body);
    }

    // Exhaustiveness: every variant must be covered (or wildcard).
    if (enum_decl) |ed| if (!has_wildcard) {
        try checkExhaustiveness(self, ms.span, ed, &covered);
    };
}

/// Resolve `ty` to its underlying enum decl (when `ty` is a
/// `Named(EnumName)` whose name maps to a registered enum
/// declaration). Returns `null` otherwise.
pub fn enumDeclForType(self: *const Checker, ty: types.Type) ?*const ast.EnumDecl {
    if (ty != .named) return null;
    return self.enum_registry.get(ty.named.name);
}

/// `true` when `name` is one of `ed`'s declared variant names.
/// Names compare by the source-buffer lexeme.
pub fn variantExists(self: *const Checker, ed: *const ast.EnumDecl, name: []const u8) bool {
    for (ed.variants) |v| {
        if (std.mem.eql(u8, self.lexeme(v.name), name)) return true;
    }
    return false;
}

/// Walk one match arm's pattern (including or-pattern
/// alternatives) and record which variant names it covers.
/// Emits `E_MATCH_UNREACHABLE_ARM` on duplicates and on any arm
/// that follows a wildcard.
fn recordArmCoverage(
    self: *Checker,
    arm: ast.MatchArm,
    ed: *const ast.EnumDecl,
    covered: *std.StringHashMapUnmanaged(void),
    has_wildcard: *bool,
) WalkError!void {
    if (has_wildcard.*) {
        try self.emitSpan("E_MATCH_UNREACHABLE_ARM", arm.span, "this arm cannot be reached — a wildcard `_` arm above already handles every remaining variant");
    }
    try walkArmPattern(self, arm.pattern, ed, covered, has_wildcard);
}

fn walkArmPattern(
    self: *Checker,
    pat: *const ast.Pattern,
    ed: *const ast.EnumDecl,
    covered: *std.StringHashMapUnmanaged(void),
    has_wildcard: *bool,
) WalkError!void {
    switch (pat.*) {
        .wildcard, .ident => {
            // Bare ident in match-arm position binds the value
            // — equivalent to `_` from the exhaustiveness POV.
            has_wildcard.* = true;
        },
        .variant_pattern => |vp| {
            const split = splitPath(self.lexeme(vp.path));
            // Verify the head matches the enum name (skip when
            // it doesn't — pattern targets a different enum).
            if (split.head.len > 0 and !std.mem.eql(u8, split.head, self.lexeme(ed.name))) return;
            // Verify variant exists on this enum.
            if (!variantExists(self, ed, split.tail)) return;
            const gop = try covered.getOrPut(self.arena, split.tail);
            if (gop.found_existing) {
                const msg = try std.fmt.allocPrint(
                    self.arena,
                    "variant `{s}.{s}` is already handled by an earlier arm",
                    .{ self.lexeme(ed.name), split.tail },
                );
                try self.emitSpan("E_MATCH_UNREACHABLE_ARM", pat.span(), msg);
            }
        },
        .or_pattern => |op| {
            for (op.alts) |alt| try walkArmPattern(self, alt, ed, covered, has_wildcard);
        },
        else => {
            // Literal / range / tuple / struct patterns don't
            // contribute to enum-variant coverage and don't
            // qualify as a catch-all.
        },
    }
}

fn checkExhaustiveness(
    self: *Checker,
    match_span: ast.Span,
    ed: *const ast.EnumDecl,
    covered: *const std.StringHashMapUnmanaged(void),
) WalkError!void {
    // Collect uncovered variant names for the message body.
    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(self.arena);
    for (ed.variants) |v| {
        const name = self.lexeme(v.name);
        if (!covered.contains(name)) try missing.append(self.arena, name);
    }
    if (missing.items.len == 0) return;

    // Render "A, B, C" (cap at 3 to keep messages compact).
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.arena);
    const limit: usize = @min(missing.items.len, 3);
    for (missing.items[0..limit], 0..) |name, i| {
        if (i > 0) try buf.appendSlice(self.arena, ", ");
        try buf.appendSlice(self.arena, name);
    }
    if (missing.items.len > limit) try buf.appendSlice(self.arena, ", …");

    const suffix: []const u8 = if (missing.items.len == 1) "" else "s";
    const msg = try std.fmt.allocPrint(
        self.arena,
        "non-exhaustive match on enum `{s}` — missing variant{s}: {s}",
        .{ self.lexeme(ed.name), suffix, buf.items },
    );
    try self.emitSpan("E_MATCH_NON_EXHAUSTIVE", match_span, msg);
}

/// Split a dotted path like `Enum.Variant` into `(head="Enum",
/// tail="Variant")`. Returns an empty head when there is no
/// `.` in the path.
pub fn splitPath(text: []const u8) struct { head: []const u8, tail: []const u8 } {
    if (std.mem.lastIndexOfScalar(u8, text, '.')) |dot| {
        return .{ .head = text[0..dot], .tail = text[dot + 1 ..] };
    }
    return .{ .head = "", .tail = text };
}
