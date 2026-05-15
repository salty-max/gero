const std = @import("std");
const gero = @import("gero");

test "gero exposes VERSION sourced from build.zig.zon" {
    // The exact version moves on every release; pin the shape (X.Y.Z)
    // so the smoke test stays valid across bumps.
    var it = std.mem.splitScalar(u8, gero.VERSION, '.');
    var parts: usize = 0;
    while (it.next()) |part| : (parts += 1) {
        try std.testing.expect(part.len > 0);
        for (part) |c| try std.testing.expect(c >= '0' and c <= '9');
    }
    try std.testing.expectEqual(@as(usize, 3), parts);
}
