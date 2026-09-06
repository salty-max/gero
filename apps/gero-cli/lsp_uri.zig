//! Conversion between LSP document URIs and filesystem paths.
//!
//! An editor addresses buffers by `file://` URI; every gero front-end
//! addresses them by path. Diagnostics travel in both directions —
//! a request arrives as a URI, and a diagnostic resolved through a
//! source map comes back as the path of some imported file that must
//! be published under its own URI.

const std = @import("std");

/// Filesystem path for `uri`, or `null` when it is not a `file://`
/// URI — an unsaved "untitled:" buffer has no path, and the caller
/// falls back to analyzing its text standalone.
pub fn toPath(arena: std.mem.Allocator, uri: []const u8) std.mem.Allocator.Error!?[]const u8 {
    const scheme = "file://";
    if (!std.mem.startsWith(u8, uri, scheme)) return null;
    var rest = uri[scheme.len..];
    // `file:///path` carries an empty authority; anything else is a
    // remote host, which no front-end can open.
    if (rest.len > 0 and rest[0] != '/') return null;
    // A Windows URI is `file:///C:/...`; the path starts at the drive.
    if (rest.len >= 3 and rest[2] == ':' and std.ascii.isAlphabetic(rest[1])) rest = rest[1..];
    return try percentDecode(arena, rest);
}

/// `file://` URI for an absolute filesystem path.
pub fn fromPath(arena: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "file://");
    // A Windows path has no leading slash of its own, so the URI's
    // empty authority has to supply one.
    if (path.len > 0 and path[0] != '/') try out.append(arena, '/');
    for (path) |c| {
        if (isUnreserved(c) or c == '/') {
            try out.append(arena, c);
        } else {
            try out.print(arena, "%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice(arena);
}

/// Characters an editor leaves unescaped in a path segment (RFC 3986
/// unreserved set, plus the sub-delims editors commonly pass through).
fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or switch (c) {
        '-', '.', '_', '~', ':', '+', '$', '@' => true,
        else => false,
    };
}

fn percentDecode(arena: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |byte| {
                try out.append(arena, byte);
                i += 3;
                continue;
            } else |_| {}
        }
        try out.append(arena, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

// ---------- tests ----------

const testing = std.testing;

test "toPath: a file URI yields its path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = (try toPath(arena.allocator(), "file:///home/max/main.gr")).?;
    try testing.expectEqualStrings("/home/max/main.gr", p);
}

test "toPath: percent escapes decode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = (try toPath(arena.allocator(), "file:///tmp/my%20carts/a%2Bb.gr")).?;
    try testing.expectEqualStrings("/tmp/my carts/a+b.gr", p);
}

test "toPath: a non-file scheme has no path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try toPath(arena.allocator(), "untitled:Untitled-1")) == null);
    try testing.expect((try toPath(arena.allocator(), "file://remote/x.gr")) == null);
}

test "fromPath: round-trips a path containing a space" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const uri = try fromPath(a, "/tmp/my carts/main.gr");
    try testing.expectEqualStrings("file:///tmp/my%20carts/main.gr", uri);
    try testing.expectEqualStrings("/tmp/my carts/main.gr", (try toPath(a, uri)).?);
}

test "fromPath: a Windows path gains the authority's slash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const uri = try fromPath(a, "C:/src/main.gr");
    try testing.expectEqualStrings("file:///C:/src/main.gr", uri);
    try testing.expectEqualStrings("C:/src/main.gr", (try toPath(a, uri)).?);
}
