//! Mirror file for `src/lang/codegen/overflow.zig`. Behavioral
//! tests for the debug overflow trap live in
//! `tests/lang/codegen.test.zig` next to the rest of the codegen
//! suite; this file exists to satisfy the mirror-layout lint rule.

const std = @import("std");
const gero = @import("gero");

test "codegen/overflow: module compiles through the barrel" {
    _ = gero.lang.compile;
}
