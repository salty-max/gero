/// Smoke that the expression emitter is reachable through the
/// public codegen barrel. End-to-end expression coverage lives
/// in `tests/lang/codegen.test.zig`.
const std = @import("std");
const gero = @import("gero");

test "codegen/expr: module compiles through the barrel" {
    _ = gero.lang.codegen.expr_emit;
}
