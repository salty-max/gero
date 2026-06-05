/// Smoke that the `inline_asm` codegen module is reachable through the
/// public barrel. End-to-end `asm "..."` lowering coverage (operand
/// substitution, opcode validation) lives in `tests/lang/codegen.test.zig`.
const std = @import("std");
const gero = @import("gero");

test "codegen/inline_asm: module compiles through the barrel" {
    _ = gero.lang.internal.codegen.inline_asm;
}
