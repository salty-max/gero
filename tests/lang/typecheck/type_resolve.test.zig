//! Mirror file for `src/lang/typecheck/type_resolve.zig`.
//! Behavioral coverage of `resolveType` lives in
//! `tests/lang/typecheck.test.zig` (and the other typecheck
//! tests) — this file exists to satisfy the mirror-layout lint
//! rule.

const std = @import("std");
const gero = @import("gero");

test "typecheck/type_resolve: module reachable through the barrel" {
    _ = gero.lang.internal.typechecker.type_resolve;
}
