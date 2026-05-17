/// Smoke that the `lambda` codegen submodule is reachable
/// through the public barrel. End-to-end coverage of closure
/// creation, capture analysis, heap promotion, and dispatch
/// lives in `tests/lang/codegen.test.zig`.
const std = @import("std");
const gero = @import("gero");

test "codegen/lambda: module compiles through the barrel" {
    _ = gero.lang.internal.codegen.lambda;
}
