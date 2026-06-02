/// Smoke that the `destructure` module is reachable through the
/// public barrel. End-to-end destructuring coverage (`let (a, b)`,
/// `let P { x, y }`, `if let E.A(n)`, `while let` + `when` guards)
/// lives in the integration tests in `tests/lang/codegen.test.zig`.
const std = @import("std");
const gero = @import("gero");

test "codegen/destructure: module compiles through the barrel" {
    _ = gero.lang.internal.codegen.destructure;
}
