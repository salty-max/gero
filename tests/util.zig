/// Shared test helpers for gero specs. Populate as patterns emerge.
const std = @import("std");
const gero = @import("gero");

test "util module loads" {
    _ = std;
    _ = gero;
}
