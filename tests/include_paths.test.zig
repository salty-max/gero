const std = @import("std");
const testing = std.testing;
const alloc = std.testing.allocator;

const gero = @import("gero");
const include_paths = gero.include_paths;

test "include_paths.join: a virtual set joins with a forward slash on every host" {
    // The property that matters: the same file set resolves the same
    // way whether the toolchain runs in a browser or on a machine whose
    // native separator is a backslash. A host-shaped join produces a
    // key the set does not contain, and the include reads as missing.
    const joined = try include_paths.join(.virtual, alloc, &.{ ".", "bank0.gas" });
    defer alloc.free(joined);
    try testing.expectEqualStrings("./bank0.gas", joined);

    const nested = try include_paths.join(.virtual, alloc, &.{ "banks", "bank1.gas" });
    defer alloc.free(nested);
    try testing.expectEqualStrings("banks/bank1.gas", nested);
}

test "include_paths.join: a host path follows the host" {
    const joined = try include_paths.join(.host, alloc, &.{ "dir", "main.gas" });
    defer alloc.free(joined);
    const expected = "dir" ++ [_]u8{std.fs.path.sep} ++ "main.gas";
    try testing.expectEqualStrings(expected, joined);
}

test "include_paths.isAbsolute: a virtual key is absolute only with a leading slash" {
    try testing.expect(include_paths.isAbsolute(.virtual, "/bank0.gas"));
    try testing.expect(!include_paths.isAbsolute(.virtual, "bank0.gas"));

    // A drive letter is a host concept. In a virtual set it is an
    // ordinary name, and treating it as absolute would skip the base
    // directory a relative include resolves against.
    try testing.expect(!include_paths.isAbsolute(.virtual, "C:\\bank0.gas"));
}

test "include_paths.dirname: a virtual key splits on forward slashes only" {
    try testing.expectEqualStrings("banks", include_paths.dirname(.virtual, "banks/bank0.gas").?);
    try testing.expectEqual(@as(?[]const u8, null), include_paths.dirname(.virtual, "bank0.gas"));

    // Not a separator here, so the whole thing is one name.
    try testing.expectEqual(
        @as(?[]const u8, null),
        include_paths.dirname(.virtual, "banks\\bank0.gas"),
    );
}
