/// Smoke that the `globals` codegen submodule is reachable through the
/// public barrel. Behavioral coverage lives in `tests/lang/codegen.test.zig`.
const std = @import("std");
const gero = @import("gero");

test "codegen/globals: module compiles through the barrel" {
    _ = gero.lang.internal.codegen.globals;
}
