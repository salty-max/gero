// Declaration coverage (let / const / def / class / struct /
// enum / use / local) lives in `parser.test.zig`. This file pins
// the mirror-layout rule.
const std = @import("std");
const gero = @import("gero");

test "decl module imports cleanly via gero.lang" {
    _ = std;
    _ = gero.lang;
}
