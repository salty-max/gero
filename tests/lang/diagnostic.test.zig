/// Diagnostic module is a simple struct definition — the
/// real coverage lives in `render.test.zig` (rendering pipeline)
/// and `typecheck.test.zig` (every diagnostic emitter). This file
/// pins the mirror-layout rule.
const std = @import("std");
const gero = @import("gero");

test "diagnostic module imports cleanly via gero.lang" {
    _ = std;
    _ = gero.lang.Diagnostic;
    _ = gero.lang.Severity;
}
