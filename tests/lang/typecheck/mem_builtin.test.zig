/// Smoke that the `mem_builtin` typecheck module is reachable
/// through the public barrel. End-to-end coverage of every
/// `mem.*` rejection / acceptance lives in
/// `tests/lang/typecheck.test.zig` and the codegen integration
/// tests.
const std = @import("std");
const gero = @import("gero");

test "typecheck/mem_builtin: module compiles through the barrel" {
    _ = gero.lang.typechecker.mem_builtin;
}

test "typecheck/mem_builtin: lookupMemBuiltin recognizes every entry" {
    const names = [_][]const u8{
        "read_u8",  "read_u16",  "read_i8",  "read_i16",
        "write_u8", "write_u16", "write_i8", "write_i16",
        "memcpy",   "memset",    "peek",     "poke",
        "addr_of",
    };
    for (names) |name| {
        try std.testing.expect(gero.lang.typechecker.mem_builtin.lookupMemBuiltin(name) != null);
    }
    try std.testing.expect(gero.lang.typechecker.mem_builtin.lookupMemBuiltin("nonexistent") == null);
}
