//! Base-protocol framing for the language server: `Content-Length`
//! headers, a blank line, then exactly that many bytes of JSON.

const std = @import("std");

/// Largest message body accepted, matching the 16 MiB source ceiling
/// the rest of the CLI uses. A larger `Content-Length` is a malformed
/// or hostile header rather than a real document, and is refused
/// before anything is allocated for it.
pub const max_body_bytes: usize = 16 * 1024 * 1024;

/// Why a message could not be read.
pub const ReadError = error{
    /// The stream ended between messages — the client is gone, which
    /// is how a server normally exits.
    EndOfStream,
    /// A header line was malformed, or `Content-Length` was missing,
    /// unparseable, or over `max_body_bytes`.
    BadHeader,
};

/// Read one message body off `reader`, allocated through `arena`.
///
/// Headers other than `Content-Length` are ignored: `Content-Type` is
/// the only other one the base protocol defines, and it carries
/// nothing a server acts on.
pub fn readMessage(
    arena: std.mem.Allocator,
    reader: *std.Io.Reader,
) (ReadError || std.mem.Allocator.Error)![]const u8 {
    var content_length: ?usize = null;
    while (true) {
        // Inclusive: the exclusive form leaves the delimiter in the
        // stream, so the next read would see an empty line forever.
        const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            // A header line longer than the reader's buffer is a
            // desynchronized stream, not a client that hung up.
            error.StreamTooLong => return error.BadHeader,
            error.EndOfStream, error.ReadFailed => return error.EndOfStream,
        };
        const trimmed = std.mem.trimEnd(u8, line, "\r\n");
        if (trimmed.len == 0) break; // the blank line ends the headers
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return error.BadHeader;
        const key = std.mem.trim(u8, trimmed[0..colon], " ");
        const value = std.mem.trim(u8, trimmed[colon + 1 ..], " ");
        if (std.ascii.eqlIgnoreCase(key, "Content-Length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch return error.BadHeader;
        }
    }

    const len = content_length orelse return error.BadHeader;
    if (len > max_body_bytes) return error.BadHeader;
    const body = try arena.alloc(u8, len);
    reader.readSliceAll(body) catch return error.EndOfStream;
    return body;
}

/// Write `body` as one message and flush, so a client blocked on the
/// response sees it without waiting for more traffic.
pub fn writeMessage(writer: *std.Io.Writer, body: []const u8) !void {
    try writer.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try writer.writeAll(body);
    try writer.flush();
}

// ---------- tests ----------

const testing = std.testing;

/// Read one message out of `bytes`.
fn readOne(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var reader: std.Io.Reader = .fixed(bytes);
    return readMessage(arena, &reader);
}

test "readMessage: takes exactly Content-Length bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = try readOne(arena.allocator(), "Content-Length: 2\r\n\r\n{}trailing");
    try testing.expectEqualStrings("{}", body);
}

test "readMessage: ignores headers other than Content-Length" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = try readOne(
        arena.allocator(),
        "Content-Type: application/vscode-jsonrpc\r\nContent-Length: 4\r\n\r\n[1,2]",
    );
    try testing.expectEqualStrings("[1,2", body);
}

test "readMessage: a missing Content-Length is a bad header" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.BadHeader, readOne(arena.allocator(), "X: 1\r\n\r\n{}"));
}

test "readMessage: an oversized Content-Length is refused before allocating" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Refusing ahead of the allocation is the point — a hostile header
    // must not be able to ask for an arbitrary buffer.
    try testing.expectError(
        error.BadHeader,
        readOne(arena.allocator(), "Content-Length: 99999999999\r\n\r\n"),
    );
}

test "readMessage: a clean end between messages ends the stream" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.EndOfStream, readOne(arena.allocator(), ""));
}

test "readMessage: a body shorter than its header ends the stream" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.EndOfStream, readOne(arena.allocator(), "Content-Length: 10\r\n\r\n{}"));
}

test "writeMessage: frames the body with its length" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var out = std.Io.Writer.Allocating.fromArrayList(testing.allocator, &buf);
    defer out.deinit();
    try writeMessage(&out.writer, "{\"id\":1}");
    try testing.expectEqualStrings("Content-Length: 8\r\n\r\n{\"id\":1}", out.written());
}

test "protocol: a written message reads back byte-identical" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var out = std.Io.Writer.Allocating.fromArrayList(testing.allocator, &buf);
    defer out.deinit();
    const payload = "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}";
    try writeMessage(&out.writer, payload);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(payload, try readOne(arena.allocator(), out.written()));
}
