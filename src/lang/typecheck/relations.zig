/// Type-to-type relations: assignability (used by return /
/// let-init / assignment / call-arg checks) and cast
/// convertibility (used by the `as` expression). Both are pure
/// functions over `types.Type` pairs — no `Checker` state.
const types = @import("../types.zig");
const predicates = @import("predicates.zig");

/// `true` when an `actual` typed value can be stored / returned /
/// passed into an `expected` slot. Wider than `Type.eql` — allows
/// `T → T?` (non-nil to nullable), integer widening conversions
/// (e.g. `u8 → i16`) per spec §3.5.1, and recurses into tuples
/// for per-slot assignability. Used by return / let-init /
/// assignment / call-arg checks; operator arms keep strict equality.
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
    if (actual == .primitive and expected == .primitive and
        isWideningInt(actual.primitive, expected.primitive))
    {
        return true;
    }
    return false;
}

/// `true` when implicitly converting an integer / `char` of type
/// `from` to type `to` is lossless — `from`'s value range is a
/// subset of `to`'s. Per spec §3.5.1: signed widening sign-
/// extends, unsigned widening zero-extends, and `u8 ↔ char` is a
/// no-op. Same-primitive pairs are trivially lossless (returns
/// `true`) — `assignable`'s `eql` short-circuit usually catches
/// them, but `assignable` also reaches here for the `char ↔ u8`
/// path where the source / dest primitive tags differ before
/// normalization.
pub fn isWideningInt(from: types.Primitive, to: types.Primitive) bool {
    const f = normalizeCharToU8(from);
    const t = normalizeCharToU8(to);
    if (f == t) return true; // u8 ↔ char, plus same-primitive identity
    const fr = primitiveIntRange(f) orelse return false;
    const tr = primitiveIntRange(t) orelse return false;
    return fr.min >= tr.min and fr.max <= tr.max;
}

/// `true` when assigning `actual` into `expected` loses precision
/// — both are integer / `char` primitives and `actual`'s range
/// doesn't fit in `expected`'s. Distinct from `assignable`'s
/// widening rule: callers check `isNarrowingInt` only when
/// `assignable` already returned `false`, so this picks up the
/// integer-mismatch cases (`i16 → u8`, sign-flips at equal
/// widths, etc.) without disturbing aggregate / reference shapes.
///
/// Does NOT peel optional layers — integer-optional types
/// (`u8?`, `i16?`) are rejected separately by the nullable rule
/// (§3.4.1: `T?` only applies to pointer-like types), so the
/// narrowing-into-nullable case never arises in a well-typed
/// program.
pub fn isNarrowingInt(actual: types.Type, expected: types.Type) bool {
    if (actual != .primitive or expected != .primitive) return false;
    const a = normalizeCharToU8(actual.primitive);
    const e = normalizeCharToU8(expected.primitive);
    if (primitiveIntRange(a) == null or primitiveIntRange(e) == null) return false;
    return !isWideningInt(a, e);
}

fn normalizeCharToU8(p: types.Primitive) types.Primitive {
    return if (p == .char) .u8 else p;
}

const IntRange = struct { min: i32, max: i32 };

/// Value range of the fixed-width integer primitives. `null` for
/// non-integer primitives. Widened to `i32` so the four ranges
/// share one comparison shape regardless of sign / width.
fn primitiveIntRange(p: types.Primitive) ?IntRange {
    return switch (p) {
        .i8 => .{ .min = -128, .max = 127 },
        .u8 => .{ .min = 0, .max = 255 },
        .i16 => .{ .min = -32768, .max = 32767 },
        .u16 => .{ .min = 0, .max = 65535 },
        else => null,
    };
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
