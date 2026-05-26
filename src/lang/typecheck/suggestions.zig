const std = @import("std");

/// Maximum edit distance for a suggestion to count. Per spec
/// (issue #257). Values above this cap return `null` from
/// `bestMatch` so the diagnostic stays clean — no suggestion is
/// better than a misleading one.
pub const max_distance: usize = 2;

/// Bounded Levenshtein distance — returns the actual distance when
/// it's `≤ cap`, or `cap + 1` when it's known to exceed (the
/// caller only needs the cap test, so the exact distance past the
/// cap doesn't matter). The bound makes the inner loop O(|b| × cap)
/// rather than O(|a| × |b|) once the running minimum exceeds cap.
pub fn levenshtein(a: []const u8, b: []const u8, cap: usize) usize {
    // Early outs based on length difference — distance is at least
    // the length-delta, so a delta past `cap` is a definite reject.
    const la = a.len;
    const lb = b.len;
    const delta = if (la > lb) la - lb else lb - la;
    if (delta > cap) return cap + 1;

    // Two-row dynamic-programming table — only the previous row
    // matters at any step, so we ping-pong between two buffers.
    // Bounded by 32 chars per name (identifiers in gero are short)
    // to keep the table on the stack.
    const max_name_len: usize = 64;
    if (la > max_name_len or lb > max_name_len) return cap + 1;

    var prev_buf: [max_name_len + 1]usize = undefined;
    var curr_buf: [max_name_len + 1]usize = undefined;
    var prev = prev_buf[0 .. lb + 1];
    var curr = curr_buf[0 .. lb + 1];

    for (prev, 0..) |*p, j| p.* = j;

    for (a, 0..) |ca, i| {
        curr[0] = i + 1;
        var row_min: usize = curr[0];
        for (b, 0..) |cb, j| {
            const ins = curr[j] + 1;
            const del = prev[j + 1] + 1;
            // @as: widen the 0/1 substitution cost from comptime_int to usize.
            const sub = prev[j] + @as(usize, if (ca == cb) 0 else 1);
            curr[j + 1] = @min(@min(ins, del), sub);
            if (curr[j + 1] < row_min) row_min = curr[j + 1];
        }
        if (row_min > cap) return cap + 1;
        std.mem.swap([]usize, &prev, &curr);
    }

    return prev[lb];
}

/// Pick the closest-spelling candidate to `target` within
/// `max_distance` edits. Returns the FIRST match at the minimum
/// distance — for the case where two candidates tie, the caller
/// gets a deterministic answer that depends on iteration order
/// (so callers wanting stability sort the candidate slice first).
pub fn bestMatch(target: []const u8, candidates: []const []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_dist: usize = max_distance + 1;
    for (candidates) |c| {
        const d = levenshtein(target, c, max_distance);
        if (d < best_dist) {
            best = c;
            best_dist = d;
            // Distance-0 match is the user's exact name — the
            // caller would have hit `lookup` instead of falling
            // through here. Short-circuit anyway in case some
            // future call site bypasses that step.
            if (best_dist == 0) return best;
        }
    }
    return best;
}
