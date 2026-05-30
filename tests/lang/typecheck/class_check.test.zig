/// Smoke that the `class_check` typecheck submodule is reachable through the
/// public barrel. Behavioral coverage lives in `tests/lang/typecheck.test.zig`.
const std = @import("std");
const gero = @import("gero");

test "typecheck/class_check: module compiles through the barrel" {
    _ = gero.lang.internal.typechecker.class_check;
}
