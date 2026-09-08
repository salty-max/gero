const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const scope_mod = @import("../scope.zig");
const typecheck = @import("../typecheck.zig");

const Scope = scope_mod.Scope;
const Checker = typecheck.Checker;
const WalkError = error{OutOfMemory};

/// Type-check a `match` statement: infer the scrutinee type,
/// walk every arm's pattern + guard + body, and (for enum or
/// `bool` scrutinees) check that every value is covered.
/// How a `match` in value position (§4.8.4) collects its arm types:
/// each arm's tail is typed inside the scope holding that arm's pattern
/// bindings, which a second walk from outside would not see.
pub const ValueMode = struct {
    hint: ?*const types.Type,
    out: *std.ArrayList(?*const types.Type),
};

/// Check a `match` at statement position: arm patterns, guards,
/// bodies, and exhaustiveness (§4.8.3).
pub fn checkMatch(self: *Checker, ms: ast.MatchStmt) WalkError!void {
    return checkMatchInner(self, ms, null);
}

/// `checkMatch` plus the per-arm value type, for the expression form.
pub fn checkMatchValue(self: *Checker, ms: ast.MatchStmt, value: ValueMode) WalkError!void {
    return checkMatchInner(self, ms, value);
}

fn checkMatchInner(self: *Checker, ms: ast.MatchStmt, value: ?ValueMode) WalkError!void {
    const scrut_ty = try self.inferExpr(ms.scrutinee, null);

    // Lookup the enum being matched. Prefer the scrutinee's inferred
    // type; fall back to a variant arm's path (`EnumName.Variant`) so
    // payload binders are still typed when the scrutinee form doesn't
    // surface a type (e.g. an inline constructor call).
    const enum_decl: ?*const ast.EnumDecl = resolveMatchEnum(self, ms, scrut_ty);
    // `bool` is the only primitive with a closed value set the
    // checker reasons about; track it the same way as enums.
    const is_bool: bool = if (scrut_ty) |st|
        st.* == .primitive and st.primitive == .bool_
    else
        false;

    // Track variant-name coverage when scrutinee is an enum.
    var covered: std.StringHashMapUnmanaged(void) = .{};
    defer covered.deinit(self.arena);
    var has_wildcard: bool = false;
    var bool_true_covered: bool = false;
    var bool_false_covered: bool = false;

    for (ms.arms) |arm| {
        // Exhaustiveness + reachability checks (per scrutinee kind).
        if (enum_decl) |ed| try recordArmCoverage(self, arm, ed, &covered, &has_wildcard);
        if (is_bool) try recordBoolArmCoverage(self, arm, &bool_true_covered, &bool_false_covered, &has_wildcard);

        const saved = self.current_scope;
        var child: Scope = .init(self.arena, saved);
        self.current_scope = &child;
        defer self.current_scope = saved;
        try self.registerBindingsFromType(arm.pattern, scrut_ty);
        if (arm.guard) |g| try self.requireBool(g);
        if (value) |v| {
            try v.out.append(self.arena, try self.doBlockType(arm.body, v.hint));
        } else {
            try self.walkStatementSequence(arm.body);
        }
    }

    // Exhaustiveness: every variant / bool case must be covered
    // unless a wildcard catches the rest.
    if (enum_decl) |ed| if (!has_wildcard) {
        try checkExhaustiveness(self, ms.span, ed, &covered);
    };
    if (is_bool and !has_wildcard) {
        try checkBoolExhaustiveness(self, ms.span, bool_true_covered, bool_false_covered);
    }
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
    // A `when`-guarded arm only conditionally matches, so it doesn't
    // cover its variant — a later unguarded same-variant arm is the
    // legitimate fallback. The arm is still flagged unreachable if a
    // prior *unguarded* arm already fully covered it.
    try walkArmPattern(self, arm.pattern, ed, covered, has_wildcard, arm.guard == null);
}

fn walkArmPattern(
    self: *Checker,
    pat: *const ast.Pattern,
    ed: *const ast.EnumDecl,
    covered: *std.StringHashMapUnmanaged(void),
    has_wildcard: *bool,
    adds_coverage: bool,
) WalkError!void {
    switch (pat.*) {
        .wildcard, .ident => {
            // Bare ident in match-arm position binds the value
            // — equivalent to `_` from the exhaustiveness POV.
            if (adds_coverage) has_wildcard.* = true;
        },
        .variant_pattern => |vp| {
            const split = splitPath(self.lexeme(vp.path));
            // Verify the head matches the enum name (skip when
            // it doesn't — pattern targets a different enum). An
            // import alias resolves to the real enum name first.
            const head = self.resolveImportAlias(split.head);
            if (head.len > 0 and !std.mem.eql(u8, head, self.lexeme(ed.name))) return;
            // Verify variant exists on this enum.
            if (!variantExists(self, ed, split.tail)) return;
            if (covered.contains(split.tail)) {
                const msg = try std.fmt.allocPrint(
                    self.arena,
                    "variant `{s}.{s}` is already handled by an earlier arm",
                    .{ self.lexeme(ed.name), split.tail },
                );
                try self.emitSpan("E_MATCH_UNREACHABLE_ARM", pat.span(), msg);
            } else if (adds_coverage) {
                try covered.put(self.arena, split.tail, {});
            }
        },
        .or_pattern => |op| {
            for (op.alts) |alt| try walkArmPattern(self, alt, ed, covered, has_wildcard, adds_coverage);
        },
        else => {
            // Literal / range / tuple / struct patterns don't
            // contribute to enum-variant coverage and don't
            // qualify as a catch-all.
        },
    }
}

/// Walk one bool-match arm and update coverage for the two
/// reachable values + the wildcard flag. Mirrors
/// `recordArmCoverage` but for the `bool` primitive — there are
/// exactly two values (`true`, `false`) so the "covered set" is
/// just two booleans.
fn recordBoolArmCoverage(
    self: *Checker,
    arm: ast.MatchArm,
    has_true: *bool,
    has_false: *bool,
    has_wildcard: *bool,
) WalkError!void {
    if (has_wildcard.*) {
        try self.emitSpan("E_MATCH_UNREACHABLE_ARM", arm.span, "this arm cannot be reached — a wildcard `_` arm above already handles every remaining case");
    } else if (has_true.* and has_false.*) {
        try self.emitSpan("E_MATCH_UNREACHABLE_ARM", arm.span, "this arm cannot be reached — both `true` and `false` are already handled");
    }
    // A guarded arm only conditionally matches — it doesn't cover its
    // value (a later unguarded arm is the fallback), but is still flagged
    // unreachable if an earlier unguarded arm already covered it.
    try walkBoolArmPattern(self, arm.pattern, has_true, has_false, has_wildcard, arm.guard == null);
}

fn walkBoolArmPattern(
    self: *Checker,
    pat: *const ast.Pattern,
    has_true: *bool,
    has_false: *bool,
    has_wildcard: *bool,
    adds_coverage: bool,
) WalkError!void {
    switch (pat.*) {
        .wildcard, .ident => {
            // Bare ident in match-arm position binds the value —
            // equivalent to `_` from the exhaustiveness POV.
            if (adds_coverage) has_wildcard.* = true;
        },
        .bool_lit => |bl| {
            const slot = if (bl.value) has_true else has_false;
            if (slot.*) {
                const msg = if (bl.value) "`true` is already handled by an earlier arm" else "`false` is already handled by an earlier arm";
                try self.emitSpan("E_MATCH_UNREACHABLE_ARM", pat.span(), msg);
            } else if (adds_coverage) {
                slot.* = true;
            }
        },
        .or_pattern => |op| {
            for (op.alts) |alt| try walkBoolArmPattern(self, alt, has_true, has_false, has_wildcard, adds_coverage);
        },
        else => {
            // Non-bool patterns (literal int, range, variant, …)
            // get caught elsewhere as a type mismatch — they don't
            // contribute to bool-value coverage either way.
        },
    }
}

fn checkBoolExhaustiveness(
    self: *Checker,
    match_span: ast.Span,
    has_true: bool,
    has_false: bool,
) WalkError!void {
    if (has_true and has_false) return;
    const missing: []const u8 = if (!has_true and !has_false)
        "true, false"
    else if (!has_true)
        "true"
    else
        "false";
    const msg = try std.fmt.allocPrint(
        self.arena,
        "non-exhaustive match on `bool` — missing: {s}",
        .{missing},
    );
    try self.emitSpan("E_MATCH_NON_EXHAUSTIVE", match_span, msg);
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
/// Resolve the enum a `match` dispatches on: the scrutinee's inferred
/// type when available, else a variant arm's enum (`EnumName.Variant`).
fn resolveMatchEnum(self: *Checker, ms: ast.MatchStmt, scrut_ty: ?*const types.Type) ?*const ast.EnumDecl {
    if (scrut_ty) |st| if (enumDeclForType(self, st.*)) |ed| return ed;
    for (ms.arms) |arm| {
        if (arm.pattern.* != .variant_pattern) continue;
        const head = self.resolveImportAlias(splitPath(self.lexeme(arm.pattern.variant_pattern.path)).head);
        if (head.len > 0) if (self.enum_registry.get(head)) |ed| return ed;
    }
    return null;
}

/// Split a variant path `EnumName.Variant` at the last `.` into its
/// head (`EnumName`) and tail (`Variant`). Head is empty when the
/// text carries no `.`.
pub fn splitPath(text: []const u8) struct { head: []const u8, tail: []const u8 } {
    if (std.mem.lastIndexOfScalar(u8, text, '.')) |dot| {
        return .{ .head = text[0..dot], .tail = text[dot + 1 ..] };
    }
    return .{ .head = "", .tail = text };
}
