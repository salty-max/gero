//! `gero lsp` — a language server over stdio for `.gas` and `.gr`.
//!
//! The server owns protocol and document state only. Every answer
//! comes from `lsp_analysis`, which calls the same library entry
//! points `gero check` and `gero fmt` do, so an editor and the CLI
//! cannot disagree about a buffer.

const std = @import("std");
const cli = @import("cli.zig");
const term_mod = @import("term.zig");
const gero = @import("gero");
const protocol = @import("lsp_protocol.zig");
const analysis = @import("lsp_analysis.zig");
const uri_mod = @import("lsp_uri.zig");

/// A set of document URIs.
const UriSet = std.StringHashMapUnmanaged(void);

/// Open documents, keyed by URI. The client owns the text — every
/// `didChange` replaces it wholesale, which is what the server asks
/// for by advertising full-sync.
const Documents = std.StringHashMapUnmanaged([]const u8);

/// Server state across one stdio session.
const Server = struct {
    /// Lives for the session: document text and URIs outlive the
    /// per-message arena that parsed them.
    gpa: std.mem.Allocator,
    docs: Documents = .{},
    /// Set by `shutdown`; `exit` then leaves with 0 rather than 1.
    shutdown_received: bool = false,
    /// URIs currently carrying diagnostics. Checking one document can
    /// report errors in the files it imports, and those have to be
    /// cleared once fixed — an editor keeps showing a published list
    /// until an empty one replaces it.
    published: std.StringHashMapUnmanaged(void) = .{},

    fn deinit(self: *Server) void {
        var it = self.docs.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.docs.deinit(self.gpa);
        var pit = self.published.keyIterator();
        while (pit.next()) |k| self.gpa.free(k.*);
        self.published.deinit(self.gpa);
    }

    /// Buffer text keyed by canonical path, for the resolvers. A
    /// document whose URI names no readable file is skipped: it cannot
    /// be the target of anyone's `use`.
    fn overlay(self: *Server, io: std.Io, arena: std.mem.Allocator) !gero.lang.Overlay {
        var ov: gero.lang.Overlay = .{};
        var it = self.docs.iterator();
        while (it.next()) |e| {
            const path = (try uri_mod.toPath(arena, e.key_ptr.*)) orelse continue;
            const canonical = std.Io.Dir.cwd().realPathFileAlloc(io, path, arena) catch continue;
            try ov.put(arena, canonical, e.value_ptr.*);
        }
        return ov;
    }

    /// Replace `uri`'s text, taking ownership of a fresh copy.
    fn put(self: *Server, uri: []const u8, text: []const u8) !void {
        const owned_text = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(owned_text);
        const gop = try self.docs.getOrPut(self.gpa, uri);
        if (gop.found_existing) {
            self.gpa.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = try self.gpa.dupe(u8, uri);
        }
        gop.value_ptr.* = owned_text;
    }

    /// Reconcile what the client is showing with what this round
    /// found: every URI that carried diagnostics before but was not
    /// written this round gets an explicit empty list, since an editor
    /// keeps a published list until an empty one replaces it.
    /// `carrying` then becomes the new set to reconcile against.
    fn reconcilePublished(
        self: *Server,
        arena: std.mem.Allocator,
        stdout: *std.Io.Writer,
        written: *const UriSet,
        carrying: *const UriSet,
    ) !void {
        var it = self.published.keyIterator();
        while (it.next()) |k| {
            if (written.contains(k.*)) continue;
            try writeDiagnostics(arena, stdout, k.*, &.{});
        }
        var next: UriSet = .{};
        errdefer {
            var nit = next.keyIterator();
            while (nit.next()) |k| self.gpa.free(k.*);
            next.deinit(self.gpa);
        }
        var cit = carrying.keyIterator();
        while (cit.next()) |k| {
            // Re-own the key: `carrying`'s strings live in the arena
            // this message is about to release.
            const owned = try self.gpa.dupe(u8, k.*);
            errdefer self.gpa.free(owned);
            try next.put(self.gpa, owned, {});
        }
        var old = self.published;
        var oit = old.keyIterator();
        while (oit.next()) |k| self.gpa.free(k.*);
        old.deinit(self.gpa);
        self.published = next;
    }

    fn drop(self: *Server, uri: []const u8) void {
        if (self.docs.fetchRemove(uri)) |kv| {
            self.gpa.free(kv.key);
            self.gpa.free(kv.value);
        }
    }
};

/// Run the server until the client closes stdin or sends `exit`.
pub fn execute(
    io: std.Io,
    gpa: std.mem.Allocator,
    opts: cli.Options,
    stdout: *std.Io.Writer,
    term: *term_mod.Term,
) !u8 {
    if (opts.positional().len > 0) {
        try term.err("gero lsp: takes no positional args (it speaks LSP over stdin/stdout)", .{});
        return 2;
    }

    var server: Server = .{ .gpa = gpa };
    defer server.deinit();

    var read_buf: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &read_buf);

    while (true) {
        // One arena per message: request JSON, the response, and any
        // diagnostics all die together when the reply is written.
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const body = protocol.readMessage(arena, &stdin.interface) catch |err| switch (err) {
            // A client that closes the pipe instead of sending `exit`
            // has still finished with the server; that is not a fault.
            error.EndOfStream => return 0,
            error.BadHeader => {
                try term.err("gero lsp: malformed message header", .{});
                return 1;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };

        const exit_code = try handleMessage(io, arena, &server, stdout, body);
        if (exit_code) |code| return code;
    }
}

/// The parts of an incoming message the dispatcher acts on. A
/// notification has no `id`, and that absence is what says no
/// response is expected.
const Request = struct {
    method: []const u8,
    id: ?std.json.Value,
    body: std.json.ObjectMap,
};

/// Decode one message body, or `null` when it is not a JSON-RPC
/// message this server can act on. There is nothing to reply to in
/// that case: the spec's parse-error response needs an id, and a body
/// that would not decode has none to give.
fn decode(parsed: std.json.Value) ?Request {
    if (parsed != .object) return null;
    const msg = parsed.object;
    const method = switch (msg.get("method") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    return .{ .method = method, .id = msg.get("id"), .body = msg };
}

/// Handle one message. Returns a code when the session should end.
fn handleMessage(
    io: std.Io,
    arena: std.mem.Allocator,
    server: *Server,
    stdout: *std.Io.Writer,
    body: []const u8,
) !?u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch return null;
    defer parsed.deinit();
    const req = decode(parsed.value) orelse return null;

    if (std.mem.eql(u8, req.method, "initialize")) {
        try replyInitialize(arena, stdout, req.id);
    } else if (std.mem.eql(u8, req.method, "shutdown")) {
        server.shutdown_received = true;
        try replyNull(arena, stdout, req.id);
    } else if (std.mem.eql(u8, req.method, "exit")) {
        // Exiting without a prior `shutdown` is an error per the spec.
        return if (server.shutdown_received) 0 else 1;
    } else if (std.mem.eql(u8, req.method, "textDocument/didOpen")) {
        try onDidOpen(io, arena, server, stdout, req.body);
    } else if (std.mem.eql(u8, req.method, "textDocument/didChange")) {
        try onDidChange(io, arena, server, stdout, req.body);
    } else if (std.mem.eql(u8, req.method, "textDocument/didClose")) {
        if (docUri(req.body)) |uri| server.drop(uri);
    } else if (std.mem.eql(u8, req.method, "textDocument/formatting")) {
        try onFormatting(arena, server, stdout, req.body, req.id);
    } else if (req.id != null) {
        // An unknown request still needs an answer or the client
        // blocks; an unknown notification carries no id and needs none.
        try replyMethodNotFound(arena, stdout, req.id, req.method);
    }
    return null;
}

// ---------- request handlers ----------

fn replyInitialize(arena: std.mem.Allocator, stdout: *std.Io.Writer, id: ?std.json.Value) !void {
    var out = std.Io.Writer.Allocating.init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try writeId(&jw, id);
    try jw.objectField("result");
    try jw.beginObject();
    try jw.objectField("capabilities");
    try jw.beginObject();
    // Full sync: the analysis re-reads the whole buffer anyway, so
    // incremental sync would be bookkeeping with no payoff.
    try jw.objectField("textDocumentSync");
    try jw.write(@as(u8, 1));
    try jw.objectField("documentFormattingProvider");
    try jw.write(true);
    try jw.endObject();
    try jw.objectField("serverInfo");
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write("gero-lsp");
    try jw.endObject();
    try jw.endObject();
    try jw.endObject();
    try protocol.writeMessage(stdout, out.written());
}

fn replyNull(arena: std.mem.Allocator, stdout: *std.Io.Writer, id: ?std.json.Value) !void {
    var out = std.Io.Writer.Allocating.init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try writeId(&jw, id);
    try jw.objectField("result");
    try jw.write(null);
    try jw.endObject();
    try protocol.writeMessage(stdout, out.written());
}

fn replyMethodNotFound(
    arena: std.mem.Allocator,
    stdout: *std.Io.Writer,
    id: ?std.json.Value,
    method: []const u8,
) !void {
    var out = std.Io.Writer.Allocating.init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try writeId(&jw, id);
    try jw.objectField("error");
    try jw.beginObject();
    try jw.objectField("code");
    try jw.write(@as(i32, -32601)); // MethodNotFound
    try jw.objectField("message");
    try jw.print("\"unsupported method: {s}\"", .{method});
    try jw.endObject();
    try jw.endObject();
    try protocol.writeMessage(stdout, out.written());
}

fn onDidOpen(
    io: std.Io,
    arena: std.mem.Allocator,
    server: *Server,
    stdout: *std.Io.Writer,
    msg: std.json.ObjectMap,
) !void {
    const doc = objectAt(msg, &.{ "params", "textDocument" }) orelse return;
    const uri = stringAt(doc, "uri") orelse return;
    const text = stringAt(doc, "text") orelse return;
    try server.put(uri, text);
    try publish(io, arena, server, stdout, uri, text);
}

fn onDidChange(
    io: std.Io,
    arena: std.mem.Allocator,
    server: *Server,
    stdout: *std.Io.Writer,
    msg: std.json.ObjectMap,
) !void {
    const uri = docUri(msg) orelse return;
    const params = objectAt(msg, &.{"params"}) orelse return;
    const changes = switch (params.get("contentChanges") orelse return) {
        .array => |a| a,
        else => return,
    };
    // Full sync: the last change carries the whole document.
    if (changes.items.len == 0) return;
    const last = changes.items[changes.items.len - 1];
    if (last != .object) return;
    const text = stringAt(last.object, "text") orelse return;
    try server.put(uri, text);
    try publish(io, arena, server, stdout, uri, text);
}

fn onFormatting(
    arena: std.mem.Allocator,
    server: *Server,
    stdout: *std.Io.Writer,
    msg: std.json.ObjectMap,
    id: ?std.json.Value,
) !void {
    const uri = docUri(msg) orelse return replyNull(arena, stdout, id);
    const text = server.docs.get(uri) orelse return replyNull(arena, stdout, id);
    const lang = analysis.langOf(uri) orelse return replyNull(arena, stdout, id);
    const formatted = (try analysis.format(arena, lang, text)) orelse
        return replyNull(arena, stdout, id);
    if (std.mem.eql(u8, formatted, text)) return replyNull(arena, stdout, id);

    // One edit spanning the whole document. A minimal diff would move
    // the cursor less, but the canonical printer rewrites layout
    // globally, so a diff would rarely be smaller and could be wrong.
    var out = std.Io.Writer.Allocating.init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try writeId(&jw, id);
    try jw.objectField("result");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("range");
    try writeRange(&jw, 0, 0, lineCount(text), 0);
    try jw.objectField("newText");
    try jw.write(formatted);
    try jw.endObject();
    try jw.endArray();
    try jw.endObject();
    try protocol.writeMessage(stdout, out.written());
}

/// Analyze `uri` and publish a diagnostic list for it — plus one for
/// every file its import graph implicates, so an error in a library
/// lands on the library rather than on whoever imported it. A document
/// whose suffix names no front-end publishes an empty list, which
/// clears anything stale rather than leaving old squiggles on screen.
fn publish(
    io: std.Io,
    arena: std.mem.Allocator,
    server: *Server,
    stdout: *std.Io.Writer,
    uri: []const u8,
    text: []const u8,
) !void {
    var files: []const analysis.FileDiagnostics = &.{};
    if (analysis.langOf(uri)) |lang| {
        var ov = try server.overlay(io, arena);
        defer ov.deinit(arena);
        files = analysis.diagnose(io, arena, lang, uri, text, &ov) catch |err| switch (err) {
            error.OutOfMemory => return err,
            // The document names a file that cannot be read — it was
            // deleted or renamed under the editor. Nothing to report.
            else => &.{},
        };
    }
    if (files.len == 0) files = &.{.{ .uri = uri, .items = &.{} }};

    var written: UriSet = .{};
    var carrying: UriSet = .{};
    for (files) |f| {
        try writeDiagnostics(arena, stdout, f.uri, f.items);
        try written.put(arena, f.uri, {});
        if (f.items.len > 0) try carrying.put(arena, f.uri, {});
    }
    try server.reconcilePublished(arena, stdout, &written, &carrying);
}

fn writeDiagnostics(
    arena: std.mem.Allocator,
    stdout: *std.Io.Writer,
    uri: []const u8,
    diags: []const analysis.Diagnostic,
) !void {
    var out = std.Io.Writer.Allocating.init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try jw.objectField("method");
    try jw.write("textDocument/publishDiagnostics");
    try jw.objectField("params");
    try jw.beginObject();
    try jw.objectField("uri");
    try jw.write(uri);
    try jw.objectField("diagnostics");
    try jw.beginArray();
    for (diags) |d| {
        try jw.beginObject();
        try jw.objectField("range");
        try writeRange(&jw, d.line, d.character, d.end_line, d.end_character);
        try jw.objectField("severity");
        try jw.write(d.severity);
        if (d.code.len > 0) {
            try jw.objectField("code");
            try jw.write(d.code);
        }
        try jw.objectField("source");
        try jw.write("gero");
        try jw.objectField("message");
        try jw.write(d.message);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
    try jw.endObject();
    try protocol.writeMessage(stdout, out.written());
}

// ---------- JSON helpers ----------

/// Echo the request id back unchanged. A notification has none, and
/// omitting the field is what distinguishes the two.
fn writeId(jw: *std.json.Stringify, id: ?std.json.Value) !void {
    const v = id orelse return;
    try jw.objectField("id");
    switch (v) {
        .integer => |n| try jw.write(n),
        .string => |s| try jw.write(s),
        else => try jw.write(null),
    }
}

fn writeRange(jw: *std.json.Stringify, l0: u32, c0: u32, l1: u32, c1: u32) !void {
    try jw.beginObject();
    try jw.objectField("start");
    try jw.beginObject();
    try jw.objectField("line");
    try jw.write(l0);
    try jw.objectField("character");
    try jw.write(c0);
    try jw.endObject();
    try jw.objectField("end");
    try jw.beginObject();
    try jw.objectField("line");
    try jw.write(l1);
    try jw.objectField("character");
    try jw.write(c1);
    try jw.endObject();
    try jw.endObject();
}

/// Walk a chain of object keys, e.g. `params.textDocument`.
fn objectAt(obj: std.json.ObjectMap, path: []const []const u8) ?std.json.ObjectMap {
    var cur = obj;
    for (path) |key| {
        const next = cur.get(key) orelse return null;
        if (next != .object) return null;
        cur = next.object;
    }
    return cur;
}

fn stringAt(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn docUri(msg: std.json.ObjectMap) ?[]const u8 {
    const doc = objectAt(msg, &.{ "params", "textDocument" }) orelse return null;
    return stringAt(doc, "uri");
}

/// Lines in `text`, used as the end of a whole-document edit range.
fn lineCount(text: []const u8) u32 {
    var n: u32 = 0;
    for (text) |c| {
        if (c == '\n') n += 1;
    }
    // A trailing line without its newline still occupies a line.
    if (text.len > 0 and text[text.len - 1] != '\n') n += 1;
    return n;
}

// ---------- tests ----------

const testing = std.testing;

/// Feed `msg` to a server and return everything it wrote back.
const Session = struct {
    server: Server,
    out: std.Io.Writer.Allocating,

    fn init(gpa: std.mem.Allocator) Session {
        return .{ .server = .{ .gpa = gpa }, .out = std.Io.Writer.Allocating.init(gpa) };
    }

    fn deinit(self: *Session) void {
        self.server.deinit();
        self.out.deinit();
    }

    /// Dispatch one message, returning the exit code it asks for.
    fn send(self: *Session, arena: std.mem.Allocator, msg: []const u8) !?u8 {
        return handleMessage(testing.io, arena, &self.server, &self.out.writer, msg);
    }

    /// Every framed message written so far, concatenated.
    fn written(self: *Session) []const u8 {
        return self.out.written();
    }
};

test "handleMessage: initialize advertises the two capabilities" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    _ = try s.send(arena_state.allocator(), "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}");
    const out = s.written();
    try testing.expect(std.mem.indexOf(u8, out, "\"documentFormattingProvider\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"textDocumentSync\":1") != null);
    // The id is echoed, or the client cannot match the response.
    try testing.expect(std.mem.indexOf(u8, out, "\"id\":1") != null);
}

test "handleMessage: exit without shutdown is an error, with it is not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bare = Session.init(testing.allocator);
    defer bare.deinit();
    try testing.expectEqual(@as(?u8, 1), try bare.send(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}"));

    var clean = Session.init(testing.allocator);
    defer clean.deinit();
    _ = try clean.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\"}");
    try testing.expectEqual(@as(?u8, 0), try clean.send(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}"));
}

test "handleMessage: an unknown request is answered, an unknown notification is not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    // A request left unanswered blocks the client forever.
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"textDocument/hover\"}");
    try testing.expect(std.mem.indexOf(u8, s.written(), "-32601") != null);

    const after_request = s.written().len;
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"$/setTrace\",\"params\":{}}");
    try testing.expectEqual(after_request, s.written().len);
}

test "handleMessage: malformed input is survivable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    // A body with no id to answer against, a non-object body, and a
    // request whose params are the wrong shape all leave the session
    // running rather than taking the server down with them.
    _ = try s.send(arena, "not json at all");
    _ = try s.send(arena, "[1,2,3]");
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{}}");
    try testing.expectEqual(@as(usize, 0), s.written().len);
    // Still able to answer a well-formed request afterwards.
    try testing.expectEqual(@as(?u8, null), try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"shutdown\"}"));
    try testing.expect(std.mem.indexOf(u8, s.written(), "\"id\":1") != null);
}

test "handleMessage: didOpen publishes, didChange republishes the new text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"untitled:a.gr\",\"text\":\"def main()\\n  print 1\\nend\\n\"}}}");
    try testing.expect(std.mem.indexOf(u8, s.written(), "\"diagnostics\":[]") != null);

    // Full sync: the last change carries the whole document.
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"untitled:a.gr\"},\"contentChanges\":[{\"text\":\"def main()\\n  print nope\\nend\\n\"}]}}");
    try testing.expect(std.mem.indexOf(u8, s.written(), "E_UNDEFINED_SYMBOL") != null);
}

test "handleMessage: formatting returns a whole-document edit" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"untitled:a.gr\",\"text\":\"def  main()\\n   print  1\\nend\\n\"}}}");
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/formatting\",\"params\":{\"textDocument\":{\"uri\":\"untitled:a.gr\"}}}");
    const out = s.written();
    try testing.expect(std.mem.indexOf(u8, out, "def main()\\n  print 1\\nend\\n") != null);
    // The edit spans the document: three lines, ending at 3:0.
    try testing.expect(std.mem.indexOf(u8, out, "\"end\":{\"line\":3,\"character\":0}") != null);
}

test "handleMessage: a buffer that does not parse formats to no edits" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"untitled:a.gr\",\"text\":\"def main(\\n\"}}}");
    const before = s.written().len;
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"textDocument/formatting\",\"params\":{\"textDocument\":{\"uri\":\"untitled:a.gr\"}}}");
    // Format-on-save must not rewrite broken source from a partial tree.
    try testing.expect(std.mem.indexOf(u8, s.written()[before..], "\"result\":null") != null);
}

test "handleMessage: fixing the last error publishes an empty list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"untitled:a.gr\",\"text\":\"def main()\\n  print nope\\nend\\n\"}}}");
    const before = s.written().len;
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"untitled:a.gr\"},\"contentChanges\":[{\"text\":\"def main()\\n  print 1\\nend\\n\"}]}}");
    // An editor keeps a published list until an empty one replaces it.
    const after = s.written()[before..];
    try testing.expect(std.mem.indexOf(u8, after, "\"diagnostics\":[]") != null);
}

test "handleMessage: didClose drops the buffer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"untitled:a.gr\",\"text\":\"def main()\\n  print 1\\nend\\n\"}}}");
    try testing.expectEqual(@as(usize, 1), s.server.docs.count());
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\",\"params\":{\"textDocument\":{\"uri\":\"untitled:a.gr\"}}}");
    try testing.expectEqual(@as(usize, 0), s.server.docs.count());
}

test "Server: reopening a document replaces its text without leaking" {
    var s = Server{ .gpa = testing.allocator };
    defer s.deinit();
    try s.put("untitled:a.gr", "first");
    try s.put("untitled:a.gr", "second");
    try testing.expectEqual(@as(usize, 1), s.docs.count());
    try testing.expectEqualStrings("second", s.docs.get("untitled:a.gr").?);
}
