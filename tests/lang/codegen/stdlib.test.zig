/// Smoke that the `stdlib` codegen router is reachable through the
/// public barrel. End-to-end coverage of `math.*` / `bank.*` / `test.*`
/// lowering lives in `tests/lang/codegen.test.zig`, where the VM-side
/// round-trip exercises it.
const std = @import("std");
const gero = @import("gero");

test "stdlib: codegen router compiles through the barrel" {
    _ = gero.lang.internal.codegen.stdlib;
}
