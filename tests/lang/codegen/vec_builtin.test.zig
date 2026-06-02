/// Smoke that the `vec_builtin` codegen module is reachable through the
/// public barrel. End-to-end `Vec(T)` coverage (construct / push / grow /
/// at / set / slice / value-copy) lives in `tests/lang/codegen.test.zig`.
const std = @import("std");
const gero = @import("gero");

test "codegen/vec_builtin: module compiles through the barrel" {
    _ = gero.lang.internal.codegen.vec_builtin;
}
