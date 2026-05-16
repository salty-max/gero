// Annotation coverage (marker form, bare-arg form, paren form,
// stacking on defs / classes / fields / methods) lives in
// `parser.test.zig`. This file pins the mirror-layout rule.
const std = @import("std");
const gero = @import("gero");

test "annotation module imports cleanly via gero.lang" {
    _ = std;
    _ = gero.lang;
}
