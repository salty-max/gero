// Type-annotation coverage (named / nullable / array / Vec(T) /
// tuple / fn-pointer) lives in `parser.test.zig`. This file pins
// the mirror-layout rule.
const std = @import("std");
const gero = @import("gero");

test "type_ann module imports cleanly via gero.lang" {
    _ = std;
    _ = gero.lang;
}
