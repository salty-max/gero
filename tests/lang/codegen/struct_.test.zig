/// Smoke that the `struct_` codegen submodule is reachable through
/// the public barrel. End-to-end coverage of struct construction,
/// field rw, value-copy, pass-by-value, and return-by-value lives in
/// `tests/lang/codegen.test.zig` — that's where the VM-side round
/// trip actually exercises the lowering.
const std = @import("std");
const gero = @import("gero");

test "codegen/struct_: module compiles through the barrel" {
    _ = gero.lang.internal.codegen.struct_;
}
