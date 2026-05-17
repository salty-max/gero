/// Smoke that the `strings` module is reachable through the
/// public codegen barrel. End-to-end coverage of single-literal
/// strings, dedup, interpolation in print + non-print position,
/// and the data-region overflow diagnostic lives in
/// `tests/lang/codegen.test.zig`.
const std = @import("std");
const gero = @import("gero");

test "codegen/strings: module compiles through the barrel" {
    _ = gero.lang.internal.codegen.strings;
}

test "codegen/strings: interp_buffer_size is the documented 64 bytes" {
    try std.testing.expectEqual(@as(u16, 64), gero.lang.internal.codegen.strings.interp_buffer_size);
}
