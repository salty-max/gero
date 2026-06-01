/// Smoke that the `bank_builtin` codegen module is reachable through
/// the public barrel. End-to-end coverage of `bank.switch_to` /
/// `bank.current` lives in `tests/lang/codegen.test.zig`.
const std = @import("std");
const gero = @import("gero");

test "bank_builtin: module compiles through the codegen barrel" {
    _ = gero.lang.internal.codegen.bank_builtin;
}
