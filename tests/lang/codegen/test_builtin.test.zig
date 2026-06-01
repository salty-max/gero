/// Smoke that the `test_builtin` codegen module is reachable through
/// the public barrel. End-to-end coverage of `test.assert_eq` /
/// `test.assert_ne` lives in `tests/lang/codegen.test.zig`.
const std = @import("std");
const gero = @import("gero");

test "test_builtin: module compiles through the codegen barrel" {
    _ = gero.lang.internal.codegen.test_builtin;
}
