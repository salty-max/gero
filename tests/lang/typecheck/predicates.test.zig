/// Smoke that the `predicates` typecheck sub-module is reachable
/// through the public barrel. Concrete behavior coverage —
/// integer/numeric arms, `bakeable` recursion, op-lexeme table
/// completeness — lives in `tests/lang/typecheck.test.zig` and is
/// filled in by gero-qa.
const std = @import("std");
const gero = @import("gero");

test "typecheck/predicates: module compiles through the barrel" {
    _ = gero.lang.typechecker.predicates;
}

test "typecheck/predicates: isIntegerPrimitive accepts every integer width" {
    _ = std.testing.expect; // placeholder — gero-qa fills the case
}

test "typecheck/predicates: isNumericType includes fixed but excludes bool" {
    _ = std.testing.expect; // placeholder — gero-qa fills the case
}

test "typecheck/predicates: isBakeableType rejects vec / reference / function" {
    _ = std.testing.expect; // placeholder — gero-qa fills the case
}

test "typecheck/predicates: intLitFits enforces signed and unsigned bounds" {
    _ = std.testing.expect; // placeholder — gero-qa fills the case
}

test "typecheck/predicates: opLexeme covers every BinaryOp variant" {
    _ = std.testing.expect; // placeholder — gero-qa fills the case
}
