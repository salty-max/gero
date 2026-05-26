const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const typecheck = @import("../typecheck.zig");
const type_resolve = @import("type_resolve.zig");
const predicates = @import("predicates.zig");
const relations = @import("relations.zig");

const Checker = typecheck.Checker;
const WalkError = error{OutOfMemory};

/// Type-check a unary expression. Routes `neg` / `log_not` /
/// `bit_not` through their primitive-class constraint and
/// returns the operand type (or `bool` for `not`).
pub fn checkUnary(self: *Checker, u: ast.UnaryExpr, hint: ?*const types.Type) WalkError!?*const types.Type {
    const op_hint: ?*const types.Type = if (u.op == .log_not)
        try self.primitive(.bool_)
    else
        hint;
    const operand_ty = try self.inferExpr(u.operand, op_hint);
    if (operand_ty == null) return null;
    const ot = operand_ty.?;
    switch (u.op) {
        .neg => {
            if (!predicates.isNumericType(ot.*)) {
                try emitOperatorRequires(self, u.span, "negation `-`", "a numeric type", ot);
                return null;
            }
            return ot;
        },
        .log_not => {
            if (!predicates.isBoolType(ot.*)) {
                try emitOperatorRequires(self, u.span, "logical `not`", "`bool`", ot);
                return null;
            }
            return try self.primitive(.bool_);
        },
        .bit_not => {
            if (!predicates.isIntegerType(ot.*)) {
                try emitOperatorRequires(self, u.span, "bitwise `~`", "an integer type", ot);
                return null;
            }
            return ot;
        },
    }
}

/// Type-check a binary expression. Dispatches per operator
/// class — arithmetic / shift / bitwise / comparison / logical.
pub fn checkBinary(self: *Checker, b: ast.BinaryExpr, hint: ?*const types.Type) WalkError!?*const types.Type {
    return switch (b.op) {
        .add, .sub, .mul, .div, .mod => try checkArith(self, b, hint),
        .shl, .shr => try checkShift(self, b, hint),
        .bit_and, .bit_or, .bit_xor => try checkBitwise(self, b, hint),
        .eq, .neq, .lt, .lte, .gt, .gte => try checkComparison(self, b),
        .log_and, .log_or => try checkLogical(self, b),
    };
}

fn checkArith(self: *Checker, b: ast.BinaryExpr, hint: ?*const types.Type) WalkError!?*const types.Type {
    const lhs_ty = try self.inferExpr(b.lhs, hint);
    // Pin RHS to LHS once known; otherwise fall back to the outer hint.
    const rhs_hint = lhs_ty orelse hint;
    const rhs_ty = try self.inferExpr(b.rhs, rhs_hint);
    if (lhs_ty == null or rhs_ty == null) return lhs_ty orelse rhs_ty;
    // String concatenation: only `+`, both sides `str`.
    if (b.op == .add and predicates.isStrType(lhs_ty.?.*) and predicates.isStrType(rhs_ty.?.*)) {
        return try self.primitive(.str);
    }
    if (!predicates.isNumericType(lhs_ty.?.*)) {
        try emitOperatorRequires(self, b.span, predicates.opLexeme(b.op), "a numeric type", lhs_ty.?);
        return null;
    }
    if (!predicates.isNumericType(rhs_ty.?.*)) {
        try emitOperatorRequires(self, b.span, predicates.opLexeme(b.op), "a numeric type", rhs_ty.?);
        return null;
    }
    if (!lhs_ty.?.eql(rhs_ty.?.*)) {
        try self.emitMismatch(b.rhs.span(), lhs_ty.?, rhs_ty.?);
    }
    return lhs_ty;
}

fn checkShift(self: *Checker, b: ast.BinaryExpr, hint: ?*const types.Type) WalkError!?*const types.Type {
    const lhs_ty = try self.inferExpr(b.lhs, hint);
    // Shift count is itself an integer; default to u8-ish via i16 (no specific hint).
    const rhs_ty = try self.inferExpr(b.rhs, null);
    if (lhs_ty == null or rhs_ty == null) return lhs_ty;
    if (!predicates.isIntegerType(lhs_ty.?.*)) {
        try emitOperatorRequires(self, b.span, predicates.opLexeme(b.op), "an integer type", lhs_ty.?);
        return null;
    }
    if (!predicates.isIntegerType(rhs_ty.?.*)) {
        try emitOperatorRequires(self, b.span, predicates.opLexeme(b.op), "an integer shift count", rhs_ty.?);
        return null;
    }
    return lhs_ty;
}

fn checkBitwise(self: *Checker, b: ast.BinaryExpr, hint: ?*const types.Type) WalkError!?*const types.Type {
    const lhs_ty = try self.inferExpr(b.lhs, hint);
    const rhs_hint = lhs_ty orelse hint;
    const rhs_ty = try self.inferExpr(b.rhs, rhs_hint);
    if (lhs_ty == null or rhs_ty == null) return lhs_ty orelse rhs_ty;
    if (!predicates.isIntegerType(lhs_ty.?.*)) {
        try emitOperatorRequires(self, b.span, predicates.opLexeme(b.op), "an integer type", lhs_ty.?);
        return null;
    }
    if (!predicates.isIntegerType(rhs_ty.?.*)) {
        try emitOperatorRequires(self, b.span, predicates.opLexeme(b.op), "an integer type", rhs_ty.?);
        return null;
    }
    if (!lhs_ty.?.eql(rhs_ty.?.*)) {
        try self.emitMismatch(b.rhs.span(), lhs_ty.?, rhs_ty.?);
    }
    return lhs_ty;
}

fn checkComparison(self: *Checker, b: ast.BinaryExpr) WalkError!?*const types.Type {
    const lhs_ty = try self.inferExpr(b.lhs, null);
    const rhs_ty = try self.inferExpr(b.rhs, lhs_ty);
    if (lhs_ty != null and rhs_ty != null) {
        // Allow nil-comparison (`x != nil` / `nil == p`) — the
        // canonical nullable idiom per §3.4.1. Strict-equality
        // only when neither side is the nil literal.
        const either_is_nil = predicates.isNilType(lhs_ty.?.*) or predicates.isNilType(rhs_ty.?.*);
        if (!either_is_nil and !lhs_ty.?.eql(rhs_ty.?.*)) {
            try self.emitMismatch(b.rhs.span(), lhs_ty.?, rhs_ty.?);
        }
    }
    return try self.primitive(.bool_);
}

fn checkLogical(self: *Checker, b: ast.BinaryExpr) WalkError!?*const types.Type {
    const bool_ty = try self.primitive(.bool_);
    const lhs_ty = try self.inferExpr(b.lhs, bool_ty);
    const rhs_ty = try self.inferExpr(b.rhs, bool_ty);
    if (lhs_ty) |t| if (!predicates.isBoolType(t.*)) {
        try emitOperatorRequires(self, b.span, predicates.opLexeme(b.op), "`bool`", t);
    };
    if (rhs_ty) |t| if (!predicates.isBoolType(t.*)) {
        try emitOperatorRequires(self, b.span, predicates.opLexeme(b.op), "`bool`", t);
    };
    return bool_ty;
}

fn emitOperatorRequires(
    self: *Checker,
    span: ast.Span,
    op_name: []const u8,
    wants: []const u8,
    actual: *const types.Type,
) WalkError!void {
    const actual_s = try types.render(self.arena, actual.*);
    const msg = try std.fmt.allocPrint(
        self.arena,
        "operator {s} requires {s}, found `{s}`",
        .{ op_name, wants, actual_s },
    );
    try self.emitSpan("E_TYPE_MISMATCH", span, msg);
}

/// Type-check a cast expression (`expr as T`). Resolves `T` via
/// `type_resolve` and validates convertibility through
/// `relations.canCast`. Emits `E_CAST_INVALID` on failure and
/// returns the target type so the surrounding expression keeps
/// type-checking.
pub fn checkCast(self: *Checker, c: ast.CastExpr) WalkError!?*const types.Type {
    const inner_ty = try self.inferExpr(c.inner, null);
    const target_ty = try type_resolve.resolveType(self, c.target_type);
    if (inner_ty) |it| {
        if (!relations.canCast(it.*, target_ty.*)) {
            const from_s = try types.render(self.arena, it.*);
            const to_s = try types.render(self.arena, target_ty.*);
            const msg = try std.fmt.allocPrint(
                self.arena,
                "cannot cast `{s}` to `{s}`",
                .{ from_s, to_s },
            );
            try self.emitSpan("E_CAST_INVALID", c.span, msg);
        }
    }
    return target_ty;
}
