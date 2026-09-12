const std = @import("std");

/// Which path grammar a set of source files is addressed by.
///
/// A program on disk is addressed the way its host addresses files —
/// backslashes and drive letters on Windows. A virtual file set is
/// addressed by keys the embedder chose, and those are POSIX-shaped on
/// every host, because the same set has to resolve identically whether
/// the toolchain is running in a browser or on a developer's machine.
pub const Kind = enum { host, virtual };

/// Whether `path` names a location that needs no base directory.
pub fn isAbsolute(kind: Kind, path: []const u8) bool {
    return switch (kind) {
        .host => std.fs.path.isAbsolute(path),
        .virtual => std.fs.path.isAbsolutePosix(path),
    };
}

/// Join path components with the separator `kind` is addressed by.
/// Caller owns the result.
pub fn join(
    kind: Kind,
    allocator: std.mem.Allocator,
    parts: []const []const u8,
) std.mem.Allocator.Error![]u8 {
    return switch (kind) {
        .host => std.fs.path.join(allocator, parts),
        // The standard library publishes no POSIX-only `join`, and the
        // native one follows the host. `resolvePosix` collapses the
        // `./` this leaves in front of a bare name.
        .virtual => std.mem.join(allocator, "/", parts),
    };
}

/// The directory part of `path`, or null when it has none.
pub fn dirname(kind: Kind, path: []const u8) ?[]const u8 {
    return switch (kind) {
        .host => std.fs.path.dirname(path),
        .virtual => std.fs.path.dirnamePosix(path),
    };
}

/// Whether `requested` names the file the way the filesystem spells it.
///
/// A case-insensitive volume resolves `Utils.gas` to `utils.gas`, so a
/// program builds on macOS and Windows and fails on Linux with a
/// diagnostic about a file that plainly exists. Comparing the request
/// against what canonicalization returned catches that at the point of
/// the include rather than on someone else's machine.
///
/// Only the components the request actually supplied are compared, and
/// only those after its last `.` or `..` — everything before one is
/// cancelled by it, and everything outside the request came from the
/// filesystem and is already spelled correctly by construction.
pub fn spellingMatches(kind: Kind, requested: []const u8, canonical: []const u8) bool {
    // Compare trailing components, not a byte suffix: on Windows the
    // canonical path uses `\`, the `use` string uses `/`, and a suffix
    // match on `src/fighter.gr` would reject a file spelled correctly.
    var request = componentsBackwardsOf(kind, requested);
    var resolved = componentsBackwardsOf(kind, canonical);
    while (request.next()) |part| {
        if (part.len == 0) continue;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return true;
        var actual = resolved.next() orelse return false;
        while (actual.len == 0) actual = resolved.next() orelse return false;
        if (!std.mem.eql(u8, part, actual)) return false;
    }
    return true;
}

fn componentsBackwardsOf(kind: Kind, path: []const u8) std.mem.SplitBackwardsIterator(u8, .any) {
    return std.mem.splitBackwardsAny(u8, path, if (kind == .host) "/\\" else "/");
}
