/// Smoke that the `variadic` codegen module is reachable through the
/// public barrel. End-to-end variadic monomorphization coverage
/// (`args.N` indexing, mixed arity, `str.format(fmt, args)` forwarding)
/// lives in `tests/lang/codegen.test.zig`.
const std = @import("std");
const gero = @import("gero");

test "codegen/variadic: module compiles through the barrel" {
    _ = gero.lang.internal.codegen.variadic;
}
