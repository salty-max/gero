/// Smoke that the `vec_builtin` typecheck dispatch is reachable through the
/// public barrel. End-to-end `Vec(T)` type-checking coverage lives in
/// `tests/lang/typecheck.test.zig` and the round-trip in
/// `tests/lang/codegen.test.zig`.
const std = @import("std");
const gero = @import("gero");

test "typecheck/vec_builtin: dispatch compiles through the barrel" {
    _ = gero.lang.internal.typechecker.vec_builtin;
}
