// Behavioral coverage for the expression parser lives in
// `parser.test.zig` — every Pratt-precedence pin, every primary
// form, and every postfix chain runs through the public
// `gero.lang.parse` surface. This file pins the mirror-layout rule
// and the import shape; per-form regressions belong next door.
const std = @import("std");
const gero = @import("gero");

test "expr module imports cleanly via gero.lang" {
    _ = std;
    _ = gero.lang;
}
