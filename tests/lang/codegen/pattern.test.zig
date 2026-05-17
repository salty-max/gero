/// Smoke that the `pattern` module is reachable through the
/// public barrel. End-to-end pattern coverage (literal /
/// wildcard / ident / OR / range / variant) lives in the match
/// integration tests in `tests/lang/codegen.test.zig`.
const std = @import("std");
const gero = @import("gero");

test "codegen/pattern: module compiles through the barrel" {
    _ = gero.lang.codegen.pattern;
}
