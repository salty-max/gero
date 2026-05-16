// Statement coverage (if / elif / else with if-let, while /
// while-let, for-in / step, match, do-block, return, break,
// continue, print, expr-stmts, assign / inc_dec / discard) lives
// in `parser.test.zig`. This file pins the mirror-layout rule.
const std = @import("std");
const gero = @import("gero");

test "stmt module imports cleanly via gero.lang" {
    _ = std;
    _ = gero.lang;
}
