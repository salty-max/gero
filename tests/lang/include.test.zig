//! Mirror file for `src/lang/include.zig`.
//! Unit tests for `matchUseQuotedLine` live alongside the source;
//! end-to-end include-resolution coverage lives in the
//! `gero compile` integration tests.

const std = @import("std");
const gero = @import("gero");

test "include: module reachable through the barrel" {
    _ = gero.lang.resolveUseImports;
    _ = gero.lang.FusedSource;
    _ = gero.lang.SourceMap;
}
