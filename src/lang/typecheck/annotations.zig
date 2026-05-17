/// Annotation validation per `docs/gero-lang.md` §3.7 — the
/// `T` target bit-flags, the `AnnotationSpec` table, and the
/// `validateAnnotations` / `validateAnnotationArgs` walkers
/// invoked from every decl-registration site. Also hosts
/// `defHasNoCapture`, the small predicate that scans a `def`'s
/// annotation list for `@no_capture`.
const std = @import("std");
const ast = @import("../ast.zig");
const typecheck = @import("../typecheck.zig");

const Checker = typecheck.Checker;
const WalkError = error{OutOfMemory};

/// Bit flags for annotation `targets:` — which decl kinds an
/// annotation may attach to. Combined with `|` in the spec table.
pub const T = struct {
    /// `let` decl.
    pub const LET: u32 = 1 << 0;
    /// `const` decl.
    pub const CONST: u32 = 1 << 1;
    /// `def` (function) decl.
    pub const DEF: u32 = 1 << 2;
    /// `class` decl.
    pub const CLASS: u32 = 1 << 3;
    /// `struct` decl.
    pub const STRUCT: u32 = 1 << 4;
    /// `enum` decl.
    pub const ENUM: u32 = 1 << 5;
    /// Field inside a `class` decl.
    pub const CLASS_FIELD: u32 = 1 << 6;
};

/// Shape an annotation's args must take.
pub const ArgRule = enum {
    none, // no args (marker)
    int_lit, // single int literal
    int_lit_pow2, // single int literal, power of two
};

/// Specification for one annotation: which targets it may attach
/// to, what arg shape it expects, and which sibling annotations
/// it conflicts with.
pub const AnnotationSpec = struct {
    name: []const u8,
    targets: u32,
    args: ArgRule,
    /// Annotation names that conflict with this one when both are
    /// applied to the same decl.
    conflicts_with: []const []const u8 = &.{},
};

/// Spec inventory per `docs/gero-lang.md` §3.7.
pub const annotation_specs = [_]AnnotationSpec{
    // Memory placement (§3.7.1)
    .{ .name = "bank", .targets = T.DEF | T.LET | T.CONST, .args = .int_lit },
    .{ .name = "zero_page", .targets = T.LET, .args = .none },
    .{ .name = "addr", .targets = T.LET, .args = .int_lit },
    .{ .name = "volatile", .targets = T.LET, .args = .none },
    .{ .name = "align", .targets = T.LET | T.CONST | T.STRUCT, .args = .int_lit_pow2 },
    // Codegen control (§3.7.2)
    .{ .name = "inline", .targets = T.DEF, .args = .none },
    .{ .name = "cold", .targets = T.DEF, .args = .none },
    .{ .name = "no_capture", .targets = T.DEF, .args = .none },
    // Misc
    .{ .name = "noreturn", .targets = T.DEF, .args = .none },
    .{ .name = "interrupt", .targets = T.DEF, .args = .int_lit },
    .{ .name = "test", .targets = T.DEF, .args = .none },
    .{ .name = "bench", .targets = T.DEF, .args = .none },
    // OOP (§6)
    .{
        .name = "override",
        .targets = T.DEF,
        .args = .none,
        .conflicts_with = &.{ "final", "abstract" },
    },
    .{
        .name = "final",
        .targets = T.DEF | T.CLASS,
        .args = .none,
        .conflicts_with = &.{ "override", "abstract" },
    },
    .{
        .name = "abstract",
        .targets = T.DEF | T.CLASS,
        .args = .none,
        .conflicts_with = &.{ "override", "final", "static" },
    },
    .{
        .name = "static",
        .targets = T.DEF,
        .args = .none,
        .conflicts_with = &.{ "abstract", "override" },
    },
    .{ .name = "private", .targets = T.DEF | T.LET | T.CLASS_FIELD, .args = .none },
};

/// Look up a spec by annotation name. Returns `null` for unknown
/// annotations — callers emit `E_ANN_UNKNOWN` in that case.
pub fn findAnnotationSpec(name: []const u8) ?*const AnnotationSpec {
    for (&annotation_specs) |*s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

/// Human-readable label for a target bit — used in
/// `E_ANN_BAD_TARGET` messages.
pub fn targetLabel(target: u32) []const u8 {
    return switch (target) {
        T.LET => "let",
        T.CONST => "const",
        T.DEF => "def",
        T.CLASS => "class",
        T.STRUCT => "struct",
        T.ENUM => "enum",
        T.CLASS_FIELD => "class field",
        else => "decl",
    };
}

/// Validate every annotation attached to a decl. `target` is the
/// decl's target bit (see the `T` namespace). Emits
/// `E_ANN_UNKNOWN` / `E_ANN_BAD_TARGET` / `E_ANN_BAD_ARG` /
/// `E_ANN_CONFLICT` per the rules in the annotation spec table.
pub fn validateAnnotations(self: *Checker, anns: []const ast.Annotation, target: u32) WalkError!void {
    for (anns) |ann| {
        const name = self.lexeme(ann.name);
        const spec = findAnnotationSpec(name) orelse {
            const msg = try std.fmt.allocPrint(
                self.arena,
                "unknown annotation `@{s}`",
                .{name},
            );
            try self.emitSpan("E_ANN_UNKNOWN", ann.name, msg);
            continue;
        };
        if ((spec.targets & target) == 0) {
            const msg = try std.fmt.allocPrint(
                self.arena,
                "annotation `@{s}` cannot be applied to a {s}",
                .{ name, targetLabel(target) },
            );
            try self.emitSpan("E_ANN_BAD_TARGET", ann.name, msg);
        }
        try validateAnnotationArgs(self, ann, spec);
    }
    // Conflict pairs — second loop so we only emit each conflict
    // once and so we don't false-positive when an earlier
    // annotation was already rejected.
    for (anns, 0..) |a, i| {
        const a_spec = findAnnotationSpec(self.lexeme(a.name)) orelse continue;
        for (anns[i + 1 ..]) |b| {
            const b_name = self.lexeme(b.name);
            for (a_spec.conflicts_with) |c| {
                if (std.mem.eql(u8, c, b_name)) {
                    const msg = try std.fmt.allocPrint(
                        self.arena,
                        "annotations `@{s}` and `@{s}` cannot be combined",
                        .{ self.lexeme(a.name), b_name },
                    );
                    try self.emitSpan("E_ANN_CONFLICT", b.name, msg);
                }
            }
        }
    }
}

/// Check a single annotation's arguments against its spec's
/// `ArgRule`. Emits `E_ANN_BAD_ARG` on shape or value violations.
pub fn validateAnnotationArgs(self: *Checker, ann: ast.Annotation, spec: *const AnnotationSpec) WalkError!void {
    switch (spec.args) {
        .none => {
            if (ann.args.len != 0) {
                const msg = try std.fmt.allocPrint(
                    self.arena,
                    "annotation `@{s}` does not take arguments",
                    .{spec.name},
                );
                try self.emitSpan("E_ANN_BAD_ARG", ann.span, msg);
            }
        },
        .int_lit => {
            if (ann.args.len != 1 or ann.args[0].* != .int_lit) {
                const msg = try std.fmt.allocPrint(
                    self.arena,
                    "annotation `@{s}` expects a single integer literal",
                    .{spec.name},
                );
                try self.emitSpan("E_ANN_BAD_ARG", ann.span, msg);
            }
        },
        .int_lit_pow2 => {
            if (ann.args.len != 1 or ann.args[0].* != .int_lit) {
                const msg = try std.fmt.allocPrint(
                    self.arena,
                    "annotation `@{s}` expects a single integer literal",
                    .{spec.name},
                );
                try self.emitSpan("E_ANN_BAD_ARG", ann.span, msg);
                return;
            }
            const v = ann.args[0].int_lit.value;
            if (v <= 0 or (v & (v - 1)) != 0) {
                const msg = try std.fmt.allocPrint(
                    self.arena,
                    "annotation `@{s}` requires a power-of-two value, got {d}",
                    .{ spec.name, v },
                );
                try self.emitSpan("E_ANN_BAD_ARG", ann.span, msg);
            }
        },
    }
}

/// `true` when `d` carries a `@no_capture` annotation.
pub fn defHasNoCapture(c: *const Checker, d: ast.DefDecl) bool {
    for (d.annotations) |ann| {
        if (std.mem.eql(u8, c.lexeme(ann.name), "no_capture")) return true;
    }
    return false;
}
