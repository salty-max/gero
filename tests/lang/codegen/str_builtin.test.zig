/// Smoke that the `str_builtin` codegen module is reachable through the
/// public barrel. End-to-end `str` member coverage (`len` / `at` / `cmp`)
/// lives in `tests/lang/codegen.test.zig`.
const std = @import("std");
const gero = @import("gero");

test "codegen/str_builtin: module compiles through the barrel" {
    _ = gero.lang.internal.codegen.str_builtin;
}
