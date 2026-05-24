/// Unit tests for the Levenshtein / bestMatch helpers backing
/// the "did you mean…?" suggestion family. The end-to-end wiring
/// (per-emission-site help blocks) is exercised in
/// `tests/lang/typecheck.test.zig`.
const std = @import("std");
const gero = @import("gero");

const suggestions = gero.lang.internal.typechecker.suggestions;

test "levenshtein: identical strings → 0" {
    try std.testing.expectEqual(@as(usize, 0), suggestions.levenshtein("foo", "foo", 2));
}

test "levenshtein: single insert / delete / substitute → 1" {
    try std.testing.expectEqual(@as(usize, 1), suggestions.levenshtein("foo", "foob", 2));
    try std.testing.expectEqual(@as(usize, 1), suggestions.levenshtein("foob", "foo", 2));
    try std.testing.expectEqual(@as(usize, 1), suggestions.levenshtein("foo", "foa", 2));
}

test "levenshtein: transposition → 2" {
    // No native transposition primitive — counts as one delete + one insert.
    try std.testing.expectEqual(@as(usize, 2), suggestions.levenshtein("ab", "ba", 2));
}

test "levenshtein: distance > cap returns cap + 1" {
    try std.testing.expectEqual(@as(usize, 3), suggestions.levenshtein("hello", "world", 2));
    try std.testing.expectEqual(@as(usize, 3), suggestions.levenshtein("", "abcde", 2));
}

test "levenshtein: length-delta past cap short-circuits" {
    // No DP work happens — the length-delta check catches it.
    try std.testing.expectEqual(@as(usize, 3), suggestions.levenshtein("a", "abcd", 2));
}

test "bestMatch: returns nearest candidate within cap" {
    const candidates = [_][]const u8{ "foo", "bar", "fooz", "qux" };
    try std.testing.expectEqualStrings("foo", suggestions.bestMatch("fo", &candidates).?);
}

test "bestMatch: returns null when no candidate is within cap" {
    const candidates = [_][]const u8{ "hello", "world", "totally_unrelated" };
    try std.testing.expectEqual(@as(?[]const u8, null), suggestions.bestMatch("xyz", &candidates));
}

test "bestMatch: empty candidate list returns null" {
    const candidates = [_][]const u8{};
    try std.testing.expectEqual(@as(?[]const u8, null), suggestions.bestMatch("anything", &candidates));
}

test "bestMatch: ties resolve to the first-iterated candidate" {
    // "ab" and "ba" both have distance 2 from "aa" — first wins.
    const candidates = [_][]const u8{ "ab", "ba" };
    try std.testing.expectEqualStrings("ab", suggestions.bestMatch("aa", &candidates).?);
}
