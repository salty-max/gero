/// Smoke that the `str_builtin` typecheck dispatch is reachable through the
/// public barrel. End-to-end `str` member type-checking lives in
/// `tests/lang/typecheck.test.zig` and the round-trip in
/// `tests/lang/codegen.test.zig`.
const std = @import("std");
const gero = @import("gero");

test "typecheck/str_builtin: dispatch compiles through the barrel" {
    _ = gero.lang.internal.typechecker.str_builtin;
}
