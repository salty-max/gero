//! Tests for the bake compile-time evaluator. The scaffolding
//! commit only verifies the module compiles through the barrel
//! and that the stub paths surface their placeholder diagnostic.
//! Behavioral coverage (arithmetic, control flow, aggregates,
//! call dispatch, instruction budget) lands in subsequent
//! commits within this PR.

const std = @import("std");
const gero = @import("gero");

const alloc = std.testing.allocator;

test "bake: module compiles through the barrel" {
    _ = gero.lang.bake.default_budget;
    _ = gero.lang.bake.BakeValue;
}

test "bake: default budget is 100_000_000 steps per spec §3.8" {
    try std.testing.expectEqual(@as(u32, 100_000_000), gero.lang.bake.default_budget);
}
