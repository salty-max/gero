/// Smoke that the `class` codegen submodule is reachable through
/// the public barrel. End-to-end coverage of class instantiation,
/// field rw, and method dispatch lives in
/// `tests/lang/codegen.test.zig` — that's where the VM-side round
/// trip actually exercises the lowering.
const std = @import("std");
const gero = @import("gero");

test "codegen/class: module compiles through the barrel" {
    _ = gero.lang.internal.codegen.class;
}
