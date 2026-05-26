//! Mirror file for `src/lang/typecheck/fields.zig`.
//! Behavioral coverage of field / method resolution lives in
//! `tests/lang/typecheck.test.zig` — this file exists to satisfy
//! the mirror-layout lint rule.

const std = @import("std");
const gero = @import("gero");

test "typecheck/fields: module reachable through the barrel" {
    _ = gero.lang.internal.typechecker.fields;
}
