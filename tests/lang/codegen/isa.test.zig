//! Mirror file for `src/lang/codegen/isa.zig`.
//! Behavioral coverage of every ISA-instruction emitter lives in
//! `tests/lang/codegen.test.zig` (and the VM-side handler tests)
//! — this file exists to satisfy the mirror-layout lint rule.

const std = @import("std");
const gero = @import("gero");

test "codegen/isa: module reachable through the barrel" {
    _ = gero.lang.internal.codegen.isa;
}
