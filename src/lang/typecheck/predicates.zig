/// Pure predicates over `types.Type` / `types.Primitive` /
/// `ast.BinaryOp`. No `Checker` state — every helper is a total
/// function from its inputs, so they're safe to call from any
/// inference / checking site. Used heavily by the binary-operator
/// arm-checks, integer-literal fitting, and `bake` return-type
/// validation.
const ast = @import("../ast.zig");
const types = @import("../types.zig");

/// `true` for fixed-width integer primitives (`i8` / `u8` / `i16`
/// / `u16`). Excludes `fixed` (a Q-format scaled int), `bool`,
/// `nil`, `str`, `char`.
pub fn isIntegerPrimitive(p: types.Primitive) bool {
    return switch (p) {
        .i8, .u8, .i16, .u16 => true,
        else => false,
    };
}

/// `true` when `t` is a primitive integer (see
/// `isIntegerPrimitive`). Aggregate / reference / named types
/// return `false`.
pub fn isIntegerType(t: types.Type) bool {
    return switch (t) {
        .primitive => |p| isIntegerPrimitive(p),
        else => false,
    };
}

/// `true` when `t` is an integer or `fixed` — i.e. anything that
/// participates in `+ - * / %` and comparison arms.
pub fn isNumericType(t: types.Type) bool {
    return switch (t) {
        .primitive => |p| isIntegerPrimitive(p) or p == .fixed,
        else => false,
    };
}

/// `true` when `t` is the `bool` primitive. Used by logical-op
/// and condition checks.
pub fn isBoolType(t: types.Type) bool {
    return switch (t) {
        .primitive => |p| p == .bool_,
        else => false,
    };
}

/// `true` when `t` is the `str` primitive. Used by the `+`
/// concatenation arm.
pub fn isStrType(t: types.Type) bool {
    return switch (t) {
        .primitive => |p| p == .str,
        else => false,
    };
}

/// `true` when `t` is the `nil` primitive. Used by nullable
/// initialization, nil-equality, and call-arg nil-propagation
/// paths.
pub fn isNilType(t: types.Type) bool {
    return switch (t) {
        .primitive => |p| p == .nil_,
        else => false,
    };
}

/// `true` when a type is representable as static data — i.e. safe
/// as the return type or output of a `bake` context. `Vec(T)` and
/// references live in the runtime allocator / borrow domain and
/// therefore can't be baked.
pub fn isBakeableType(t: types.Type) bool {
    return switch (t) {
        .primitive => true,
        .array => |a| isBakeableType(a.elem.*),
        .tuple => |xs| blk: {
            for (xs) |e| if (!isBakeableType(e.*)) break :blk false;
            break :blk true;
        },
        .optional => |inner| isBakeableType(inner.*),
        .named => true,
        .vec, .reference, .function => false,
    };
}

/// Display name for a primitive — used in diagnostic messages
/// (e.g. `"value 257 doesn't fit in u8"`).
pub fn primitiveName(p: types.Primitive) []const u8 {
    return switch (p) {
        .i8 => "i8",
        .u8 => "u8",
        .i16 => "i16",
        .u16 => "u16",
        .bool_ => "bool",
        .nil_ => "nil",
        .str => "str",
        .fixed => "fixed",
        .char => "char",
    };
}

/// `true` when `value` is representable in `p` (only meaningful
/// for the four integer primitives — other primitives always
/// return `false`).
pub fn intLitFits(value: i32, p: types.Primitive) bool {
    return switch (p) {
        .i8 => value >= -128 and value <= 127,
        .u8 => value >= 0 and value <= 255,
        .i16 => value >= -32768 and value <= 32767,
        .u16 => value >= 0 and value <= 65535,
        else => false,
    };
}

/// Backtick-quoted display form for a binary operator — used in
/// the `operator X requires Y` diagnostic family.
pub fn opLexeme(op: ast.BinaryOp) []const u8 {
    return switch (op) {
        .add => "`+`",
        .sub => "`-`",
        .mul => "`*`",
        .div => "`/`",
        .mod => "`%`",
        .shl => "`<<`",
        .shr => "`>>`",
        .bit_and => "`&`",
        .bit_or => "`|`",
        .bit_xor => "`^`",
        .eq => "`==`",
        .neq => "`!=`",
        .lt => "`<`",
        .lte => "`<=`",
        .gt => "`>`",
        .gte => "`>=`",
        .log_and => "`and`",
        .log_or => "`or`",
    };
}
