const std = @import("std");
const gero = @import("gero");

test "gero exposes VERSION" {
    try std.testing.expectEqualStrings("0.0.0", gero.VERSION);
}
