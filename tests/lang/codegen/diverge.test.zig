//! Mirror file for `src/lang/codegen/diverge.zig`.
//! Behavioral coverage of the diverging builtins (`panic`,
//! `unreachable`, `todo`) lives in `tests/lang/codegen.test.zig`
//! — this file exists to satisfy the mirror-layout lint rule.

const std = @import("std");
const gero = @import("gero");

test "codegen/diverge: module reachable through the barrel" {
    _ = gero.lang.internal.codegen;
}
