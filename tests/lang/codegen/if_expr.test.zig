/// Smoke that the `if_expr` codegen module is reachable through the
/// public barrel. End-to-end value-`if` coverage (branch values,
/// `elif` chains, branch-local frame slots) lives in
/// `tests/lang/codegen.test.zig`.
const std = @import("std");
const gero = @import("gero");

test "codegen/if_expr: module compiles through the barrel" {
    _ = gero.lang.internal.codegen.if_expr;
}
