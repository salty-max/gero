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
