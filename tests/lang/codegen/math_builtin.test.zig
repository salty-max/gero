/// Smoke that the `math_builtin` codegen module is reachable through
/// the public barrel. End-to-end coverage of every `math.*` helper
/// lives in `tests/lang/codegen.test.zig` — that's where the VM-side
/// round-trip exercises the lowering.
const std = @import("std");
const gero = @import("gero");

test "math_builtin: module compiles through the codegen barrel" {
    _ = gero.lang.internal.codegen.math_builtin;
}
