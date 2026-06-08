/// Smoke that the `do_expr` codegen module is reachable through the
/// public barrel. End-to-end `do … end` value-block coverage (scalar
/// / tuple / struct / array results, scratch locals, defers) lives in
/// `tests/lang/codegen.test.zig`.
const std = @import("std");
const gero = @import("gero");

test "codegen/do_expr: module compiles through the barrel" {
    _ = gero.lang.internal.codegen.do_expr;
}
