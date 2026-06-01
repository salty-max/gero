/// Smoke that the `stdlib` typecheck dispatch is reachable through the
/// public barrel. End-to-end coverage of `math.*` / `bank.*` / `test.*`
/// type-checking lives in `tests/lang/typecheck.test.zig` and the
/// codegen round-trip in `tests/lang/codegen.test.zig`.
const std = @import("std");
const gero = @import("gero");

test "stdlib: typecheck dispatch compiles through the barrel" {
    _ = gero.lang.internal.typechecker.stdlib;
}
