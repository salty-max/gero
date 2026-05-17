/// Specs for `typecheck/relations` — `assignable` and `canCast`.
/// Both are pure functions over `types.Type` pairs with no
/// `Checker` state, so every spec is a direct unit call. Covers
/// the structural-assignability matrix (primitive identity,
/// nil-to-optional, T-to-T?, per-slot tuple recursion) and the
/// §3.5.1 cast conversion table.
const std = @import("std");
const gero = @import("gero");

const relations = gero.lang.internal.typechecker.relations;
const types = gero.lang.types;

const alloc = std.testing.allocator;

// ---------- small constructors for fixture types ----------

fn prim(p: types.Primitive) types.Type {
    return .{ .primitive = p };
}

// ---------- module reachability ----------

test "typecheck/relations: module compiles through the barrel" {
    _ = relations;
}

// ---------- assignable: identity ----------

test "typecheck/relations: assignable accepts identical primitives" {
    try std.testing.expect(relations.assignable(prim(.i16), prim(.i16)));
    try std.testing.expect(relations.assignable(prim(.bool_), prim(.bool_)));
    try std.testing.expect(relations.assignable(prim(.str), prim(.str)));
}

test "typecheck/relations: assignable rejects different-width integers" {
    // §3.5: no implicit narrowing OR widening. Cast required.
    try std.testing.expect(!relations.assignable(prim(.i8), prim(.i16)));
    try std.testing.expect(!relations.assignable(prim(.i16), prim(.i8)));
    try std.testing.expect(!relations.assignable(prim(.u8), prim(.u16)));
}

test "typecheck/relations: assignable rejects signed/unsigned mix at same width" {
    try std.testing.expect(!relations.assignable(prim(.i16), prim(.u16)));
    try std.testing.expect(!relations.assignable(prim(.u8), prim(.i8)));
}

test "typecheck/relations: assignable rejects across primitive classes" {
    try std.testing.expect(!relations.assignable(prim(.bool_), prim(.i16)));
    try std.testing.expect(!relations.assignable(prim(.i16), prim(.bool_)));
    try std.testing.expect(!relations.assignable(prim(.str), prim(.i16)));
    try std.testing.expect(!relations.assignable(prim(.fixed), prim(.i16)));
    try std.testing.expect(!relations.assignable(prim(.char), prim(.u8)));
}

// ---------- assignable: nil → optional ----------

test "typecheck/relations: assignable accepts nil into a nullable slot" {
    const inner = try types.mkPrimitive(alloc, .str);
    defer alloc.destroy(inner);
    const opt = types.Type{ .optional = inner };
    try std.testing.expect(relations.assignable(prim(.nil_), opt));
}

test "typecheck/relations: assignable rejects nil into a non-nullable slot" {
    // The nil-to-optional path is the *only* widening assignable
    // grants over identity. Bare nil-into-str must reject.
    try std.testing.expect(!relations.assignable(prim(.nil_), prim(.str)));
    try std.testing.expect(!relations.assignable(prim(.nil_), prim(.i16)));
}

// ---------- assignable: T → T? ----------

test "typecheck/relations: assignable accepts T into T? when inner matches" {
    const inner = try types.mkPrimitive(alloc, .str);
    defer alloc.destroy(inner);
    const opt = types.Type{ .optional = inner };
    try std.testing.expect(relations.assignable(prim(.str), opt));
}

test "typecheck/relations: assignable rejects T into T? when inner differs" {
    const inner = try types.mkPrimitive(alloc, .str);
    defer alloc.destroy(inner);
    const opt = types.Type{ .optional = inner };
    // `i16` is not assignable to `str?` — the inner types must match.
    try std.testing.expect(!relations.assignable(prim(.i16), opt));
}

test "typecheck/relations: assignable rejects optional → non-optional (no auto-unwrap)" {
    const inner = try types.mkPrimitive(alloc, .str);
    defer alloc.destroy(inner);
    const opt = types.Type{ .optional = inner };
    try std.testing.expect(!relations.assignable(opt, prim(.str)));
}

// ---------- assignable: tuple per-slot recursion ----------

test "typecheck/relations: assignable on tuples requires same arity and per-slot assignable" {
    const i16t = try types.mkPrimitive(alloc, .i16);
    defer alloc.destroy(i16t);
    const u8t = try types.mkPrimitive(alloc, .u8);
    defer alloc.destroy(u8t);

    const a_elems = [_]*const types.Type{ i16t, u8t };
    const b_elems = [_]*const types.Type{ i16t, u8t };
    const a = types.Type{ .tuple = &a_elems };
    const b = types.Type{ .tuple = &b_elems };
    try std.testing.expect(relations.assignable(a, b));
}

test "typecheck/relations: assignable on tuples rejects arity mismatch" {
    const i16t = try types.mkPrimitive(alloc, .i16);
    defer alloc.destroy(i16t);
    const u8t = try types.mkPrimitive(alloc, .u8);
    defer alloc.destroy(u8t);

    const a_elems = [_]*const types.Type{ i16t, u8t };
    const b_elems = [_]*const types.Type{i16t};
    const a = types.Type{ .tuple = &a_elems };
    const b = types.Type{ .tuple = &b_elems };
    try std.testing.expect(!relations.assignable(a, b));
}

test "typecheck/relations: assignable on tuples rejects slot type mismatch" {
    const i16t = try types.mkPrimitive(alloc, .i16);
    defer alloc.destroy(i16t);
    const u8t = try types.mkPrimitive(alloc, .u8);
    defer alloc.destroy(u8t);
    const strt = try types.mkPrimitive(alloc, .str);
    defer alloc.destroy(strt);

    const expected_elems = [_]*const types.Type{ i16t, u8t };
    const actual_elems = [_]*const types.Type{ i16t, strt };
    const expected = types.Type{ .tuple = &expected_elems };
    const actual = types.Type{ .tuple = &actual_elems };
    try std.testing.expect(!relations.assignable(actual, expected));
}

test "typecheck/relations: assignable allows nil in a tuple slot when expected is nullable" {
    // (nil, u8) assignable to (str?, u8) — slot recursion runs the
    // nil-to-optional path per-element.
    const u8t = try types.mkPrimitive(alloc, .u8);
    defer alloc.destroy(u8t);
    const strt = try types.mkPrimitive(alloc, .str);
    defer alloc.destroy(strt);
    const opt_str = types.Type{ .optional = strt };
    const nil_t = try types.mkPrimitive(alloc, .nil_);
    defer alloc.destroy(nil_t);

    const expected_elems = [_]*const types.Type{ &opt_str, u8t };
    const actual_elems = [_]*const types.Type{ nil_t, u8t };
    const expected = types.Type{ .tuple = &expected_elems };
    const actual = types.Type{ .tuple = &actual_elems };
    try std.testing.expect(relations.assignable(actual, expected));
}

// ---------- assignable: aggregate / reference rejections ----------

test "typecheck/relations: assignable rejects vec/reference/function pairs without identity" {
    const u8t = try types.mkPrimitive(alloc, .u8);
    defer alloc.destroy(u8t);
    const i16t = try types.mkPrimitive(alloc, .i16);
    defer alloc.destroy(i16t);

    const vec_u8 = types.Type{ .vec = u8t };
    const vec_i16 = types.Type{ .vec = i16t };
    try std.testing.expect(!relations.assignable(vec_u8, vec_i16));

    const ref_u8 = types.Type{ .reference = u8t };
    const ref_i16 = types.Type{ .reference = i16t };
    try std.testing.expect(!relations.assignable(ref_u8, ref_i16));
}

test "typecheck/relations: assignable rejects across named types with different lexemes" {
    const a = types.Type{ .named = .{ .name = "Player", .span = .{ .start = 0, .end = 6 } } };
    const b = types.Type{ .named = .{ .name = "Enemy", .span = .{ .start = 0, .end = 5 } } };
    try std.testing.expect(!relations.assignable(a, b));
}

// ---------- canCast: identity ----------

test "typecheck/relations: canCast accepts same-primitive identity for every primitive" {
    inline for (.{ .i8, .u8, .i16, .u16, .bool_, .nil_, .str, .fixed, .char }) |p| {
        try std.testing.expect(relations.canCast(prim(p), prim(p)));
    }
}

// ---------- canCast: integer ↔ integer ----------

test "typecheck/relations: canCast accepts every integer ↔ integer pair" {
    const ints = .{ .i8, .u8, .i16, .u16 };
    inline for (ints) |from| {
        inline for (ints) |to| {
            try std.testing.expect(relations.canCast(prim(from), prim(to)));
        }
    }
}

// ---------- canCast: bool ↔ integer ----------

test "typecheck/relations: canCast accepts bool ↔ integer" {
    try std.testing.expect(relations.canCast(prim(.bool_), prim(.i8)));
    try std.testing.expect(relations.canCast(prim(.bool_), prim(.u16)));
    try std.testing.expect(relations.canCast(prim(.i16), prim(.bool_)));
    try std.testing.expect(relations.canCast(prim(.u8), prim(.bool_)));
}

// ---------- canCast: fixed ↔ integer ----------

test "typecheck/relations: canCast accepts fixed ↔ integer" {
    try std.testing.expect(relations.canCast(prim(.fixed), prim(.i16)));
    try std.testing.expect(relations.canCast(prim(.fixed), prim(.u8)));
    try std.testing.expect(relations.canCast(prim(.i8), prim(.fixed)));
    try std.testing.expect(relations.canCast(prim(.u16), prim(.fixed)));
}

// ---------- canCast: u8 ↔ char ----------

test "typecheck/relations: canCast accepts u8 ↔ char" {
    try std.testing.expect(relations.canCast(prim(.u8), prim(.char)));
    try std.testing.expect(relations.canCast(prim(.char), prim(.u8)));
}

// ---------- canCast: rejections ----------

test "typecheck/relations: canCast rejects str ↔ anything except itself" {
    try std.testing.expect(!relations.canCast(prim(.str), prim(.i16)));
    try std.testing.expect(!relations.canCast(prim(.str), prim(.u8)));
    try std.testing.expect(!relations.canCast(prim(.i16), prim(.str)));
    try std.testing.expect(!relations.canCast(prim(.str), prim(.char)));
}

test "typecheck/relations: canCast rejects nil ↔ anything except itself" {
    try std.testing.expect(!relations.canCast(prim(.nil_), prim(.i16)));
    try std.testing.expect(!relations.canCast(prim(.nil_), prim(.bool_)));
    try std.testing.expect(!relations.canCast(prim(.i16), prim(.nil_)));
}

test "typecheck/relations: canCast rejects bool ↔ fixed (must transit through integer)" {
    // §3.5.1 — fixed is only convertible with integers, not bool directly.
    try std.testing.expect(!relations.canCast(prim(.bool_), prim(.fixed)));
    try std.testing.expect(!relations.canCast(prim(.fixed), prim(.bool_)));
}

test "typecheck/relations: canCast rejects char ↔ non-u8 integer/primitive" {
    // char ↔ u8 is special-cased; char ↔ i16, char ↔ bool, etc. don't qualify.
    try std.testing.expect(!relations.canCast(prim(.char), prim(.i16)));
    try std.testing.expect(!relations.canCast(prim(.char), prim(.bool_)));
    try std.testing.expect(!relations.canCast(prim(.i16), prim(.char)));
}

test "typecheck/relations: canCast rejects non-primitive pairs" {
    const u8t = try types.mkPrimitive(alloc, .u8);
    defer alloc.destroy(u8t);

    const vec = types.Type{ .vec = u8t };
    const ref = types.Type{ .reference = u8t };
    const arr = types.Type{ .array = .{ .elem = u8t, .len = 4 } };
    const named = types.Type{ .named = .{ .name = "Player", .span = .{ .start = 0, .end = 6 } } };

    try std.testing.expect(!relations.canCast(vec, prim(.i16)));
    try std.testing.expect(!relations.canCast(prim(.i16), ref));
    try std.testing.expect(!relations.canCast(arr, prim(.u8)));
    try std.testing.expect(!relations.canCast(named, prim(.i16)));
    // Even named-to-itself (different instance) doesn't qualify — canCast
    // requires both ends to be `.primitive`.
    try std.testing.expect(!relations.canCast(named, named));
}
