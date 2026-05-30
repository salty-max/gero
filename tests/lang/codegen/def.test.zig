/// Smoke that the `def` codegen submodule is reachable through the
/// public barrel. Behavioral coverage lives in `tests/lang/codegen.test.zig`.
const std = @import("std");
const gero = @import("gero");

test "codegen/def: module compiles through the barrel" {
    _ = gero.lang.internal.codegen.def;
}
