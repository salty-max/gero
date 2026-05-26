//! Mirror file for `src/lang/typecheck/calls.zig`.
//! Behavioral coverage of call / assert / variadic / bake-call
//! rules lives in `tests/lang/typecheck.test.zig` — this file
//! exists to satisfy the mirror-layout lint rule.

const std = @import("std");
const gero = @import("gero");

test "typecheck/calls: module reachable through the barrel" {
    _ = gero.lang.internal.typechecker.calls;
}
