/// Smoke that the `inline_call` codegen submodule is reachable through the
/// public barrel. Behavioral coverage lives in `tests/lang/codegen.test.zig`.
const std = @import("std");
const gero = @import("gero");

test "codegen/inline_call: module compiles through the barrel" {
    _ = gero.lang.internal.codegen.inline_call;
}
