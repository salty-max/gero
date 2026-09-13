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

/// The form a source path takes inside a `.gx` debug section:
/// relative to the directory of the root source file, with forward
/// slashes whatever the host uses.
///
/// The absolute path a file was read from is a property of the machine
/// that built the image, not of the program. Recording it makes the
/// same sources produce different bytes in two checkouts, which costs
/// a build its reproducibility and leaks the builder's directory
/// layout into anything shipped. A debugger resolves what is stored
/// here against the source tree it has, which is the tree the user is
/// actually looking at.
///
/// ```
/// // root /proj/src/main.gas, file /proj/src/banks/b0.gas
/// const rel = try forDebugSection(alloc, "/proj/src", "/proj/src/banks/b0.gas");
/// // rel == "banks/b0.gas"
/// ```
///
/// A path already relative — the virtual file set a browser host
/// supplies — is returned as-is; it is a key, not a location, and it
/// is reproducible already. So is a path sharing no root with
/// `root_dir` (a second drive on Windows), which has no relative form.
/// Caller owns the result.
pub fn forDebugSection(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    path: []const u8,
) std.mem.Allocator.Error![]u8 {
    if (!namesAHostLocation(path) or !namesAHostLocation(root_dir)) {
        return posixCopy(allocator, path);
    }

    var from = componentsOf(root_dir);
    var to = componentsOf(path);
    var shared: usize = 0;
    while (true) {
        const a = from.peek() orelse break;
        const b = to.peek() orelse break;
        if (!std.mem.eql(u8, a, b)) break;
        _ = from.next();
        _ = to.next();
        shared += 1;
    }
    // Nothing in common is a path on another root, which no sequence
    // of `..` reaches.
    if (shared == 0) return posixCopy(allocator, path);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    while (from.next()) |_| try out.appendSlice(allocator, "../");
    var first = true;
    while (to.next()) |part| {
        if (!first) try out.append(allocator, '/');
        try out.appendSlice(allocator, part);
        first = false;
    }
    return out.toOwnedSlice(allocator);
}

/// Whether `path` names a place on a filesystem rather than a key in
/// a virtual set. Both platforms' absolute forms count on every host:
/// this decides how bytes are recorded, so it has to answer the same
/// wherever it runs, not follow the machine doing the recording.
fn namesAHostLocation(path: []const u8) bool {
    if (std.fs.path.isAbsolutePosix(path)) return true;
    // `C:\...` or `C:/...` — a drive letter, colon, separator.
    return path.len >= 3 and
        std.ascii.isAlphabetic(path[0]) and
        path[1] == ':' and
        (path[2] == '\\' or path[2] == '/');
}

/// Copy `path` with host separators rewritten to `/`, so an image
/// built on Windows matches one built anywhere else.
fn posixCopy(allocator: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error![]u8 {
    const out = try allocator.dupe(u8, path);
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

/// Forward iterator over a host path's non-empty components, with a
/// one-component lookahead so two paths can be walked in step.
const Components = struct {
    it: std.mem.SplitIterator(u8, .any),
    pending: ?[]const u8,

    fn peek(self: *Components) ?[]const u8 {
        if (self.pending == null) self.pending = self.advance();
        return self.pending;
    }

    fn next(self: *Components) ?[]const u8 {
        if (self.pending) |p| {
            self.pending = null;
            return p;
        }
        return self.advance();
    }

    fn advance(self: *Components) ?[]const u8 {
        while (self.it.next()) |part| {
            if (part.len != 0) return part;
        }
        return null;
    }
};

fn componentsOf(path: []const u8) Components {
    return .{ .it = std.mem.splitAny(u8, path, "/\\"), .pending = null };
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
