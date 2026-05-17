/// Smoke that the `match` typecheck sub-module is reachable
/// through the public barrel. End-to-end coverage of
/// exhaustiveness + reachability checks lives in
/// `tests/lang/typecheck.test.zig`.
const std = @import("std");
const gero = @import("gero");

test "typecheck/match: module compiles through the barrel" {
    _ = gero.lang.typechecker.internal.match;
}

test "typecheck/match: splitPath splits `Enum.Variant` correctly" {
    const result = gero.lang.typechecker.internal.match.splitPath("Color.Red");
    try std.testing.expectEqualStrings("Color", result.head);
    try std.testing.expectEqualStrings("Red", result.tail);

    const no_dot = gero.lang.typechecker.internal.match.splitPath("Lone");
    try std.testing.expectEqualStrings("", no_dot.head);
    try std.testing.expectEqualStrings("Lone", no_dot.tail);
}
