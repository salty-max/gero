//! Mirror file for `src/lang/typecheck/operators.zig`.
//! Behavioral coverage of operator + cast type rules lives in
//! `tests/lang/typecheck.test.zig` — this file exists to satisfy
//! the mirror-layout lint rule.

const std = @import("std");
const gero = @import("gero");

test "typecheck/operators: module reachable through the barrel" {
    _ = gero.lang.internal.typechecker.operators;
}
