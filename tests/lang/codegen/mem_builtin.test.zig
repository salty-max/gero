/// Smoke that the `mem_builtin` module is reachable through the
/// public barrel. End-to-end coverage of every `mem.*` builtin
/// lives in `tests/lang/codegen.test.zig` — that's where the
/// VM-side round-trip actually exercises the lowering.
const std = @import("std");
const gero = @import("gero");

test "mem_builtin: module compiles through the codegen barrel" {
    _ = gero.lang.codegen.internal.mem_builtin;
}
