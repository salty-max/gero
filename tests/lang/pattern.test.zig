// Pattern coverage (wildcard / ident / literals / or / range /
// tuple / variant / struct, plus shorthand binding) lives in
// `parser.test.zig`. This file pins the mirror-layout rule.
const std = @import("std");
const gero = @import("gero");

test "pattern module imports cleanly via gero.lang" {
    _ = std;
    _ = gero.lang;
}
