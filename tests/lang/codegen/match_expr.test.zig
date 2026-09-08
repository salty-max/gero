/// Smoke that the `match_expr` codegen module is reachable through the
/// public barrel. End-to-end value-`match` coverage (arm values, guards,
/// payload binders, arm-local frame slots) lives in
/// `tests/lang/codegen.test.zig`.
const std = @import("std");
const gero = @import("gero");

test "codegen/match_expr: module compiles through the barrel" {
    _ = gero.lang.internal.codegen.match_expr;
}
