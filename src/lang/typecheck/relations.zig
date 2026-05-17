/// Type-to-type relations: assignability (used by return /
/// let-init / assignment / call-arg checks) and cast
/// convertibility (used by the `as` expression). Both are pure
/// functions over `types.Type` pairs — no `Checker` state.
const types = @import("../types.zig");
const predicates = @import("predicates.zig");

/// `true` when an `actual` typed value can be stored / returned /
/// passed into an `expected` slot. Wider than `Type.eql` — allows
/// `T → T?` (non-nil to nullable) and recurses into tuples for
/// per-slot assignability. Used by return / let-init / assignment
/// / call-arg checks; operator arms keep strict equality.
pub fn assignable(actual: types.Type, expected: types.Type) bool {
    if (actual.eql(expected)) return true;
    if (expected == .optional) {
        if (actual == .primitive and actual.primitive == .nil_) return true;
        if (assignable(actual, expected.optional.*)) return true;
    }
    if (expected == .tuple and actual == .tuple and expected.tuple.len == actual.tuple.len) {
        for (expected.tuple, actual.tuple) |e, a| {
            if (!assignable(a.*, e.*)) return false;
        }
        return true;
    }
    return false;
}

/// Spec §3.5.1 conversion table. Allows integer ↔ integer (any
/// width / sign), bool ↔ integer, fixed ↔ integer, u8 ↔ char, and
/// any same-primitive identity cast. Rejects everything else
/// (class casts, function-pointer reinterpret, reference casts).
pub fn canCast(from: types.Type, to: types.Type) bool {
    if (from != .primitive or to != .primitive) return false;
    const f = from.primitive;
    const t = to.primitive;
    if (f == t) return true;
    const f_int = predicates.isIntegerPrimitive(f);
    const t_int = predicates.isIntegerPrimitive(t);
    if (f_int and t_int) return true;
    if (f == .bool_ and t_int) return true;
    if (f_int and t == .bool_) return true;
    if (f == .fixed and t_int) return true;
    if (f_int and t == .fixed) return true;
    if ((f == .u8 and t == .char) or (f == .char and t == .u8)) return true;
    return false;
}
