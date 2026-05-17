/// Specs for the pure `typecheck/predicates` sub-module — happy +
/// failure path per fallible predicate. Concrete behavior coverage
/// (integer/numeric arms, `bakeable` recursion, op-lexeme table
/// completeness) lives here; integration coverage is in
/// `tests/lang/typecheck.test.zig`.
const std = @import("std");
const gero = @import("gero");

const predicates = gero.lang.typechecker.internal.predicates;
const types = gero.lang.types;
const ast = gero.lang.ast;

const alloc = std.testing.allocator;

test "typecheck/predicates: module compiles through the barrel" {
    _ = gero.lang.typechecker.internal.predicates;
}

// ---------- isIntegerPrimitive ----------

test "typecheck/predicates: isIntegerPrimitive accepts every integer width" {
    try std.testing.expect(predicates.isIntegerPrimitive(.i8));
    try std.testing.expect(predicates.isIntegerPrimitive(.u8));
    try std.testing.expect(predicates.isIntegerPrimitive(.i16));
    try std.testing.expect(predicates.isIntegerPrimitive(.u16));
}

test "typecheck/predicates: isIntegerPrimitive rejects non-integer primitives" {
    try std.testing.expect(!predicates.isIntegerPrimitive(.fixed));
    try std.testing.expect(!predicates.isIntegerPrimitive(.bool_));
    try std.testing.expect(!predicates.isIntegerPrimitive(.nil_));
    try std.testing.expect(!predicates.isIntegerPrimitive(.str));
    try std.testing.expect(!predicates.isIntegerPrimitive(.char));
}

// ---------- isIntegerType ----------

test "typecheck/predicates: isIntegerType is true for integer primitives" {
    try std.testing.expect(predicates.isIntegerType(.{ .primitive = .i8 }));
    try std.testing.expect(predicates.isIntegerType(.{ .primitive = .u8 }));
    try std.testing.expect(predicates.isIntegerType(.{ .primitive = .i16 }));
    try std.testing.expect(predicates.isIntegerType(.{ .primitive = .u16 }));
}

test "typecheck/predicates: isIntegerType rejects fixed and other primitives" {
    try std.testing.expect(!predicates.isIntegerType(.{ .primitive = .fixed }));
    try std.testing.expect(!predicates.isIntegerType(.{ .primitive = .bool_ }));
    try std.testing.expect(!predicates.isIntegerType(.{ .primitive = .str }));
}

test "typecheck/predicates: isIntegerType rejects aggregate and reference shapes" {
    const elem = try types.mkPrimitive(alloc, .i16);
    defer alloc.destroy(elem);
    const arr = types.Type{ .array = .{ .elem = elem, .len = 4 } };
    try std.testing.expect(!predicates.isIntegerType(arr));

    const vec = types.Type{ .vec = elem };
    try std.testing.expect(!predicates.isIntegerType(vec));

    const ref = types.Type{ .reference = elem };
    try std.testing.expect(!predicates.isIntegerType(ref));

    const opt = types.Type{ .optional = elem };
    try std.testing.expect(!predicates.isIntegerType(opt));

    const named = types.Type{ .named = .{ .name = "Player", .span = .{ .start = 0, .end = 6 } } };
    try std.testing.expect(!predicates.isIntegerType(named));
}

// ---------- isNumericType ----------

test "typecheck/predicates: isNumericType includes fixed but excludes bool" {
    try std.testing.expect(predicates.isNumericType(.{ .primitive = .i8 }));
    try std.testing.expect(predicates.isNumericType(.{ .primitive = .u8 }));
    try std.testing.expect(predicates.isNumericType(.{ .primitive = .i16 }));
    try std.testing.expect(predicates.isNumericType(.{ .primitive = .u16 }));
    try std.testing.expect(predicates.isNumericType(.{ .primitive = .fixed }));

    try std.testing.expect(!predicates.isNumericType(.{ .primitive = .bool_ }));
    try std.testing.expect(!predicates.isNumericType(.{ .primitive = .nil_ }));
    try std.testing.expect(!predicates.isNumericType(.{ .primitive = .str }));
    try std.testing.expect(!predicates.isNumericType(.{ .primitive = .char }));
}

test "typecheck/predicates: isNumericType rejects non-primitive shapes" {
    const elem = try types.mkPrimitive(alloc, .i16);
    defer alloc.destroy(elem);
    const vec = types.Type{ .vec = elem };
    try std.testing.expect(!predicates.isNumericType(vec));
}

// ---------- isBoolType ----------

test "typecheck/predicates: isBoolType accepts bool, rejects others" {
    try std.testing.expect(predicates.isBoolType(.{ .primitive = .bool_ }));

    try std.testing.expect(!predicates.isBoolType(.{ .primitive = .i16 }));
    try std.testing.expect(!predicates.isBoolType(.{ .primitive = .nil_ }));
    try std.testing.expect(!predicates.isBoolType(.{ .primitive = .str }));
}

test "typecheck/predicates: isBoolType rejects non-primitive shapes" {
    const inner = try types.mkPrimitive(alloc, .bool_);
    defer alloc.destroy(inner);
    const opt = types.Type{ .optional = inner };
    try std.testing.expect(!predicates.isBoolType(opt));
}

// ---------- isStrType ----------

test "typecheck/predicates: isStrType accepts str, rejects others" {
    try std.testing.expect(predicates.isStrType(.{ .primitive = .str }));

    try std.testing.expect(!predicates.isStrType(.{ .primitive = .char }));
    try std.testing.expect(!predicates.isStrType(.{ .primitive = .i16 }));
    try std.testing.expect(!predicates.isStrType(.{ .primitive = .bool_ }));
}

test "typecheck/predicates: isStrType rejects optional/reference wrappers around str" {
    const inner = try types.mkPrimitive(alloc, .str);
    defer alloc.destroy(inner);
    const opt = types.Type{ .optional = inner };
    try std.testing.expect(!predicates.isStrType(opt));
    const ref = types.Type{ .reference = inner };
    try std.testing.expect(!predicates.isStrType(ref));
}

// ---------- isNilType ----------

test "typecheck/predicates: isNilType accepts nil, rejects others" {
    try std.testing.expect(predicates.isNilType(.{ .primitive = .nil_ }));

    try std.testing.expect(!predicates.isNilType(.{ .primitive = .bool_ }));
    try std.testing.expect(!predicates.isNilType(.{ .primitive = .i16 }));
    try std.testing.expect(!predicates.isNilType(.{ .primitive = .str }));
}

test "typecheck/predicates: isNilType does not propagate through optional" {
    // An `optional` wrapping nil isn't itself nil — the predicate
    // matches only the bare nil primitive, used by nil-equality and
    // nil-propagation paths.
    const inner = try types.mkPrimitive(alloc, .nil_);
    defer alloc.destroy(inner);
    const opt = types.Type{ .optional = inner };
    try std.testing.expect(!predicates.isNilType(opt));
}

// ---------- isBakeableType ----------

test "typecheck/predicates: isBakeableType accepts every primitive" {
    inline for (.{ .i8, .u8, .i16, .u16, .bool_, .nil_, .str, .fixed, .char }) |p| {
        try std.testing.expect(predicates.isBakeableType(.{ .primitive = p }));
    }
}

test "typecheck/predicates: isBakeableType accepts named types" {
    const named = types.Type{ .named = .{ .name = "Color", .span = .{ .start = 0, .end = 5 } } };
    try std.testing.expect(predicates.isBakeableType(named));
}

test "typecheck/predicates: isBakeableType rejects vec / reference / function" {
    const elem = try types.mkPrimitive(alloc, .i16);
    defer alloc.destroy(elem);
    const vec = types.Type{ .vec = elem };
    try std.testing.expect(!predicates.isBakeableType(vec));

    const ref = types.Type{ .reference = elem };
    try std.testing.expect(!predicates.isBakeableType(ref));

    const fun = types.Type{ .function = .{ .params = &.{}, .ret = elem } };
    try std.testing.expect(!predicates.isBakeableType(fun));
}

test "typecheck/predicates: isBakeableType recurses into array and propagates non-bakeable" {
    const u8t = try types.mkPrimitive(alloc, .u8);
    defer alloc.destroy(u8t);
    const arr_ok = types.Type{ .array = .{ .elem = u8t, .len = 8 } };
    try std.testing.expect(predicates.isBakeableType(arr_ok));

    // [Vec(u8); 4] — non-bakeable element ⇒ non-bakeable array.
    const inner_vec = types.Type{ .vec = u8t };
    const arr_bad = types.Type{ .array = .{ .elem = &inner_vec, .len = 4 } };
    try std.testing.expect(!predicates.isBakeableType(arr_bad));
}

test "typecheck/predicates: isBakeableType recurses into tuple — fails on first non-bakeable elem" {
    const u8t = try types.mkPrimitive(alloc, .u8);
    defer alloc.destroy(u8t);
    const i16t = try types.mkPrimitive(alloc, .i16);
    defer alloc.destroy(i16t);

    const tup_ok_elems = [_]*const types.Type{ u8t, i16t };
    const tup_ok = types.Type{ .tuple = &tup_ok_elems };
    try std.testing.expect(predicates.isBakeableType(tup_ok));

    // (u8, Vec(u8)) — second element non-bakeable ⇒ tuple non-bakeable.
    const inner_vec = types.Type{ .vec = u8t };
    const tup_bad_elems = [_]*const types.Type{ u8t, &inner_vec };
    const tup_bad = types.Type{ .tuple = &tup_bad_elems };
    try std.testing.expect(!predicates.isBakeableType(tup_bad));
}

test "typecheck/predicates: isBakeableType recurses into optional" {
    const u8t = try types.mkPrimitive(alloc, .u8);
    defer alloc.destroy(u8t);
    const opt_ok = types.Type{ .optional = u8t };
    try std.testing.expect(predicates.isBakeableType(opt_ok));

    const inner_vec = types.Type{ .vec = u8t };
    const opt_bad = types.Type{ .optional = &inner_vec };
    try std.testing.expect(!predicates.isBakeableType(opt_bad));
}

// ---------- primitiveName ----------

test "typecheck/predicates: primitiveName covers every primitive variant" {
    try std.testing.expectEqualStrings("i8", predicates.primitiveName(.i8));
    try std.testing.expectEqualStrings("u8", predicates.primitiveName(.u8));
    try std.testing.expectEqualStrings("i16", predicates.primitiveName(.i16));
    try std.testing.expectEqualStrings("u16", predicates.primitiveName(.u16));
    try std.testing.expectEqualStrings("bool", predicates.primitiveName(.bool_));
    try std.testing.expectEqualStrings("nil", predicates.primitiveName(.nil_));
    try std.testing.expectEqualStrings("str", predicates.primitiveName(.str));
    try std.testing.expectEqualStrings("fixed", predicates.primitiveName(.fixed));
    try std.testing.expectEqualStrings("char", predicates.primitiveName(.char));
}

// ---------- intLitFits ----------

test "typecheck/predicates: intLitFits accepts in-range values for every integer width" {
    try std.testing.expect(predicates.intLitFits(0, .i8));
    try std.testing.expect(predicates.intLitFits(-128, .i8));
    try std.testing.expect(predicates.intLitFits(127, .i8));

    try std.testing.expect(predicates.intLitFits(0, .u8));
    try std.testing.expect(predicates.intLitFits(255, .u8));

    try std.testing.expect(predicates.intLitFits(-32768, .i16));
    try std.testing.expect(predicates.intLitFits(32767, .i16));

    try std.testing.expect(predicates.intLitFits(0, .u16));
    try std.testing.expect(predicates.intLitFits(65535, .u16));
}

test "typecheck/predicates: intLitFits rejects i8 overflow on both sides" {
    try std.testing.expect(!predicates.intLitFits(128, .i8));
    try std.testing.expect(!predicates.intLitFits(-129, .i8));
}

test "typecheck/predicates: intLitFits rejects u8 overflow and negative values" {
    try std.testing.expect(!predicates.intLitFits(256, .u8));
    try std.testing.expect(!predicates.intLitFits(-1, .u8));
}

test "typecheck/predicates: intLitFits rejects i16 overflow on both sides" {
    try std.testing.expect(!predicates.intLitFits(32768, .i16));
    try std.testing.expect(!predicates.intLitFits(-32769, .i16));
}

test "typecheck/predicates: intLitFits rejects u16 overflow and negative values" {
    try std.testing.expect(!predicates.intLitFits(65536, .u16));
    try std.testing.expect(!predicates.intLitFits(-1, .u16));
}

test "typecheck/predicates: intLitFits returns false for non-integer primitives" {
    // Documented contract: only meaningful for the four integer
    // primitives. Everything else returns false even for value 0.
    try std.testing.expect(!predicates.intLitFits(0, .bool_));
    try std.testing.expect(!predicates.intLitFits(0, .nil_));
    try std.testing.expect(!predicates.intLitFits(0, .str));
    try std.testing.expect(!predicates.intLitFits(0, .fixed));
    try std.testing.expect(!predicates.intLitFits(0, .char));
}

test "typecheck/predicates: intLitFits handles i32 extremes safely" {
    // Boundary safety — predicate accepts an i32 input, so the
    // largest and smallest legal i32 values must produce `false`
    // without overflowing the comparison.
    try std.testing.expect(!predicates.intLitFits(std.math.maxInt(i32), .u16));
    try std.testing.expect(!predicates.intLitFits(std.math.minInt(i32), .i16));
}

// ---------- opLexeme ----------

test "typecheck/predicates: opLexeme covers every BinaryOp variant" {
    try std.testing.expectEqualStrings("`+`", predicates.opLexeme(.add));
    try std.testing.expectEqualStrings("`-`", predicates.opLexeme(.sub));
    try std.testing.expectEqualStrings("`*`", predicates.opLexeme(.mul));
    try std.testing.expectEqualStrings("`/`", predicates.opLexeme(.div));
    try std.testing.expectEqualStrings("`%`", predicates.opLexeme(.mod));
    try std.testing.expectEqualStrings("`<<`", predicates.opLexeme(.shl));
    try std.testing.expectEqualStrings("`>>`", predicates.opLexeme(.shr));
    try std.testing.expectEqualStrings("`&`", predicates.opLexeme(.bit_and));
    try std.testing.expectEqualStrings("`|`", predicates.opLexeme(.bit_or));
    try std.testing.expectEqualStrings("`^`", predicates.opLexeme(.bit_xor));
    try std.testing.expectEqualStrings("`==`", predicates.opLexeme(.eq));
    try std.testing.expectEqualStrings("`!=`", predicates.opLexeme(.neq));
    try std.testing.expectEqualStrings("`<`", predicates.opLexeme(.lt));
    try std.testing.expectEqualStrings("`<=`", predicates.opLexeme(.lte));
    try std.testing.expectEqualStrings("`>`", predicates.opLexeme(.gt));
    try std.testing.expectEqualStrings("`>=`", predicates.opLexeme(.gte));
    try std.testing.expectEqualStrings("`and`", predicates.opLexeme(.log_and));
    try std.testing.expectEqualStrings("`or`", predicates.opLexeme(.log_or));
}

test "typecheck/predicates: opLexeme table is exhaustive — sanity-check by enum field count" {
    // If a new BinaryOp variant is added without a lexeme entry,
    // Zig's exhaustive switch in `opLexeme` won't compile and this
    // test will fail to build. The count guard catches the inverse:
    // a stale spec that hasn't been updated when a variant is added.
    const variant_count = @typeInfo(ast.BinaryOp).@"enum".fields.len;
    try std.testing.expectEqual(@as(usize, 18), variant_count);
}
