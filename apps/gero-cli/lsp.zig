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
const symbols = @import("lsp_symbols.zig");
const asm_symbols = @import("lsp_asm.zig");
const index_mod = @import("lsp_index.zig");
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
    /// URIs each document's analysis last published diagnostics for,
    /// keyed by the document analyzed.
    ///
    /// Checking one document can report errors in the files it
    /// imports, and those have to be cleared once fixed — an editor
    /// keeps showing a published list until an empty one replaces it.
    /// Scoped per analysis rather than globally, because analyzing one
    /// document says nothing about what another's errors should be:
    /// clearing across roots would wipe a file's diagnostics the
    /// moment an unrelated one was opened.
    published: std.StringHashMapUnmanaged(UriSet) = .{},
    /// Canonical paths each open document's last analysis read, keyed
    /// by document URI. A change to any of those paths invalidates
    /// that document's diagnostics, even though the editor only told
    /// us about the file being typed in.
    deps: std.StringHashMapUnmanaged([]const []const u8) = .{},
    /// What the workspace's other files export, for the import a code
    /// action offers. Empty until `initialize` names a root.
    index: index_mod.Index,

    fn deinit(self: *Server) void {
        self.index.deinit();
        var it = self.docs.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.docs.deinit(self.gpa);
        var pit = self.published.iterator();
        while (pit.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.freeUriSet(e.value_ptr);
        }
        self.published.deinit(self.gpa);
        var dit = self.deps.iterator();
        while (dit.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.freePaths(e.value_ptr.*);
        }
        self.deps.deinit(self.gpa);
    }

    fn freePaths(self: *Server, paths: []const []const u8) void {
        for (paths) |p| self.gpa.free(p);
        self.gpa.free(paths);
    }

    /// Remember which files `uri`'s analysis read, taking a gpa-owned
    /// copy — the paths come from the per-message arena.
    fn noteDeps(self: *Server, uri: []const u8, paths: []const []const u8) !void {
        const owned = try self.gpa.alloc([]const u8, paths.len);
        var filled: usize = 0;
        errdefer {
            for (owned[0..filled]) |p| self.gpa.free(p);
            self.gpa.free(owned);
        }
        for (paths, 0..) |p, i| {
            owned[i] = try self.gpa.dupe(u8, p);
            filled = i + 1;
        }
        const gop = try self.deps.getOrPut(self.gpa, uri);
        if (gop.found_existing) {
            self.freePaths(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = self.gpa.dupe(u8, uri) catch |err| {
                _ = self.deps.remove(uri);
                return err;
            };
        }
        gop.value_ptr.* = owned;
    }

    /// True when `uri`'s last analysis read `path`.
    fn dependsOn(self: *Server, uri: []const u8, path: []const u8) bool {
        const paths = self.deps.get(uri) orelse return false;
        for (paths) |p| {
            if (std.mem.eql(u8, p, path)) return true;
        }
        return false;
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
    /// Clear the diagnostics `root`'s previous analysis published and
    /// this one did not, then record what this one is carrying.
    ///
    /// Only `root`'s own previous set is cleared. Another document's
    /// diagnostics are that document's analysis to retract.
    fn reconcilePublished(
        self: *Server,
        arena: std.mem.Allocator,
        stdout: *std.Io.Writer,
        root: []const u8,
        written: *const UriSet,
        carrying: *const UriSet,
    ) !void {
        if (self.published.get(root)) |prev| {
            var it = prev.keyIterator();
            while (it.next()) |k| {
                if (written.contains(k.*)) continue;
                try writeDiagnostics(arena, stdout, k.*, &.{});
            }
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
        const gop = try self.published.getOrPut(self.gpa, root);
        if (gop.found_existing) {
            self.freeUriSet(gop.value_ptr);
        } else {
            gop.key_ptr.* = self.gpa.dupe(u8, root) catch |err| {
                _ = self.published.remove(root);
                return err;
            };
        }
        gop.value_ptr.* = next;
    }

    fn drop(self: *Server, uri: []const u8) void {
        if (self.docs.fetchRemove(uri)) |kv| {
            self.gpa.free(kv.key);
            self.gpa.free(kv.value);
        }
        if (self.deps.fetchRemove(uri)) |kv| {
            self.gpa.free(kv.key);
            self.freePaths(kv.value);
        }
        // What this document's analysis published stands until the
        // file is reopened (§3), so only the bookkeeping goes.
        if (self.published.fetchRemove(uri)) |kv| {
            self.gpa.free(kv.key);
            var set = kv.value;
            self.freeUriSet(&set);
        }
    }

    /// Release a set's owned URI keys and its backing storage.
    fn freeUriSet(self: *Server, set: *UriSet) void {
        var it = set.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        set.deinit(self.gpa);
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

    var server: Server = .{ .gpa = gpa, .index = .{ .gpa = gpa } };
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
        try noteRoot(arena, server, req.body);
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
    } else if (std.mem.eql(u8, req.method, "textDocument/definition")) {
        try onDefinition(io, arena, server, stdout, req.body, req.id);
    } else if (std.mem.eql(u8, req.method, "textDocument/hover")) {
        try onHover(io, arena, server, stdout, req.body, req.id);
    } else if (std.mem.eql(u8, req.method, "textDocument/references")) {
        try onReferences(io, arena, server, stdout, req.body, req.id);
    } else if (std.mem.eql(u8, req.method, "textDocument/inlayHint")) {
        try onInlayHint(arena, server, stdout, req.body, req.id);
    } else if (std.mem.eql(u8, req.method, "textDocument/completion")) {
        try onCompletion(io, arena, server, stdout, req.body, req.id);
    } else if (std.mem.eql(u8, req.method, "textDocument/codeAction")) {
        try onCodeAction(io, arena, server, stdout, req.body, req.id);
    } else if (req.id != null) {
        // An unknown request still needs an answer or the client
        // blocks; an unknown notification carries no id and needs none.
        try replyMethodNotFound(arena, stdout, req.id, req.method);
    }
    return null;
}

// ---------- request handlers ----------

/// Remember the workspace root an `initialize` named, so a code
/// action can offer an import from a file the document has not
/// mentioned. A client that sends neither leaves the index empty and
/// only stdlib imports are offered.
fn noteRoot(arena: std.mem.Allocator, server: *Server, msg: std.json.ObjectMap) !void {
    const params = objectAt(msg, &.{"params"}) orelse return;
    if (stringAt(params, "rootUri")) |uri| {
        if (try uri_mod.toPath(arena, uri)) |path| return server.index.setRoot(path);
    }
    if (stringAt(params, "rootPath")) |path| return server.index.setRoot(path);
}

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
    // Both answer from the checker's own binding table rather than a
    // second resolution of the same names (`docs/lsp.md` §6).
    try jw.objectField("definitionProvider");
    try jw.write(true);
    try jw.objectField("hoverProvider");
    try jw.write(true);
    try jw.objectField("referencesProvider");
    try jw.write(true);
    try jw.objectField("inlayHintProvider");
    try jw.write(true);
    try jw.objectField("completionProvider");
    try jw.beginObject();
    // A client asks on its own while the user types an identifier, but
    // `.` is not one — without it named here, a member list after a
    // receiver never opens unless the user asks for it by hand.
    try jw.objectField("triggerCharacters");
    try jw.beginArray();
    try jw.write(".");
    try jw.endArray();
    try jw.endObject();
    // Quick-fixes only — every action here rewrites one diagnostic's
    // span to the name the checker already suggested.
    try jw.objectField("codeActionProvider");
    try jw.beginObject();
    try jw.objectField("codeActionKinds");
    try jw.beginArray();
    try jw.write("quickfix");
    try jw.endArray();
    try jw.endObject();
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
    try publishAffected(io, arena, server, stdout, uri, text);
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
    try publishAffected(io, arena, server, stdout, uri, text);
}

/// The position in a `textDocument/*` request that carries one.
fn requestPosition(msg: std.json.ObjectMap) ?symbols.Position {
    const p = objectAt(msg, &.{ "params", "position" }) orelse return null;
    const line = p.get("line") orelse return null;
    const ch = p.get("character") orelse return null;
    if (line != .integer or ch != .integer) return null;
    // @as: an editor's line and column, bounded by the file.
    return .{ .line = @intCast(line.integer), .character = @intCast(ch.integer) };
}

/// The `params.range` an editor sends with a request scoped to a
/// selection rather than to a caret.
fn requestRange(msg: std.json.ObjectMap) ?struct { start: symbols.Position, end: symbols.Position } {
    const r = objectAt(msg, &.{ "params", "range" }) orelse return null;
    const a = positionIn(r, "start") orelse return null;
    const b = positionIn(r, "end") orelse return null;
    return .{ .start = a, .end = b };
}

fn positionIn(obj: std.json.ObjectMap, key: []const u8) ?symbols.Position {
    const v = obj.get(key) orelse return null;
    if (v != .object) return null;
    const line = v.object.get("line") orelse return null;
    const ch = v.object.get("character") orelse return null;
    if (line != .integer or ch != .integer) return null;
    // @as: an editor's line and column, bounded by the file.
    return .{ .line = @intCast(line.integer), .character = @intCast(ch.integer) };
}

/// Resolve what the cursor is on, or `null` for anything that is not a
/// name the checker bound — whitespace, a keyword, an unresolved
/// identifier.
fn resolveAt(
    arena: std.mem.Allocator,
    server: *Server,
    msg: std.json.ObjectMap,
) !?struct { uri: []const u8, src: []const u8, hit: symbols.Resolved } {
    const uri = docUri(msg) orelse return null;
    const text = server.docs.get(uri) orelse return null;
    const lang = analysis.langOf(uri) orelse return null;
    // `.gas` resolves through the assembler's symbol table, which is a
    // different shape; only `.gr` is wired here.
    if (lang != .gr) return null;
    const pos = requestPosition(msg) orelse return null;
    const hit = (try symbols.resolveGr(arena, text, pos)) orelse return null;
    return .{ .uri = uri, .src = text, .hit = hit };
}

/// Answer a completion request with the assembler's own symbols.
fn writeAsmCompletions(
    arena: std.mem.Allocator,
    stdout: *std.Io.Writer,
    id: ?std.json.Value,
    items: []const asm_symbols.Completion,
) !void {
    var out = std.Io.Writer.Allocating.init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try writeId(&jw, id);
    try jw.objectField("result");
    try jw.beginObject();
    try jw.objectField("isIncomplete");
    try jw.write(false);
    try jw.objectField("items");
    try jw.beginArray();
    for (items) |it| {
        try jw.beginObject();
        try jw.objectField("label");
        try jw.write(it.name);
        try jw.objectField("kind");
        try jw.write(asm_symbols.completionKind(it.kind));
        try jw.objectField("detail");
        try jw.write(asm_symbols.kindText(it.kind));
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
    try jw.endObject();
    try protocol.writeMessage(stdout, out.written());
}

/// A `.gas` document assembled, with the request's position resolved
/// into the fused buffer those offsets belong to.
const GasAt = struct {
    program: analysis.GasProgram,
    /// The document's own path, for placing results back into it.
    path: ?[]const u8,
    offset: u32,
};

/// Assemble the `.gas` document a request names and locate its
/// position in the fused source. `null` when the document is not
/// `.gas`, cannot be assembled, or names a position outside it.
fn gasAt(
    io: std.Io,
    arena: std.mem.Allocator,
    server: *Server,
    msg: std.json.ObjectMap,
) !?GasAt {
    const uri = docUri(msg) orelse return null;
    const text = server.docs.get(uri) orelse return null;
    if (analysis.langOf(uri) != .gas) return null;
    const pos = requestPosition(msg) orelse return null;

    var ov = try server.overlay(io, arena);
    defer ov.deinit(arena);
    const program = (try analysis.gasProgram(io, arena, uri, text, &ov)) orelse return null;
    const path = try uri_mod.toPath(arena, uri);
    const local = symbols.offsetOf(text, pos) orelse return null;
    const fused = asm_symbols.fusedOffsetOf(program, path, local) orelse return null;
    return .{ .program = program, .path = path, .offset = fused };
}

/// Answer a definition request with one fused span, placed in the
/// file that wrote it.
fn writeGasDefinition(
    arena: std.mem.Allocator,
    stdout: *std.Io.Writer,
    id: ?std.json.Value,
    fallback_uri: []const u8,
    program: analysis.GasProgram,
    span: gero.asm_.Span,
) !void {
    var out = std.Io.Writer.Allocating.init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try writeId(&jw, id);
    try jw.objectField("result");
    try jw.beginObject();
    try writeGasLocation(&jw, arena, fallback_uri, program, span);
    try jw.endObject();
    try jw.endObject();
    try protocol.writeMessage(stdout, out.written());
}

/// Write a fused span as an LSP `Location`, in whichever file wrote
/// it — an included file, not necessarily the one being edited.
fn writeGasLocation(
    jw: *std.json.Stringify,
    arena: std.mem.Allocator,
    fallback_uri: []const u8,
    program: analysis.GasProgram,
    span: gero.asm_.Span,
) !void {
    const at = asm_symbols.place(program, span);
    const uri = if (at.path) |p| try uri_mod.fromPath(arena, p) else fallback_uri;
    const start = gero.diagnostics_json.lineColIn(at.text, at.start);
    const end = gero.diagnostics_json.lineColIn(at.text, at.end);
    try jw.objectField("uri");
    try jw.write(uri);
    try jw.objectField("range");
    // safety: line/col of an offset in a source file, far under 4 GiB.
    try writeRange(
        jw,
        @intCast(start.line - 1),
        @intCast(start.col - 1),
        @intCast(end.line - 1),
        @intCast(end.col - 1),
    );
}

fn onDefinition(
    io: std.Io,
    arena: std.mem.Allocator,
    server: *Server,
    stdout: *std.Io.Writer,
    msg: std.json.ObjectMap,
    id: ?std.json.Value,
) !void {
    if (try gasAt(io, arena, server, msg)) |g| {
        const hit = (try asm_symbols.resolveAt(arena, g.program, g.offset)) orelse
            return replyNull(arena, stdout, id);
        const at = hit.symbol.decl_start orelse return replyNull(arena, stdout, id);
        // safety: a declaration's name length, bounded by the source.
        const len: u32 = @intCast(hit.key.len);
        return writeGasDefinition(arena, stdout, id, docUri(msg).?, g.program, .{ .start = at, .end = at + len });
    }
    const found = (try resolveAt(arena, server, msg)) orelse
        return replyNull(arena, stdout, id);
    const d = found.hit.binding.decl_span;
    const start = symbols.positionOf(found.src, d.start);
    const end = symbols.positionOf(found.src, d.end);

    var out = std.Io.Writer.Allocating.init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try writeId(&jw, id);
    try jw.objectField("result");
    try jw.beginObject();
    try jw.objectField("uri");
    try jw.write(found.uri);
    try jw.objectField("range");
    try writeRange(&jw, start.line, start.character, end.line, end.character);
    try jw.endObject();
    try jw.endObject();
    try protocol.writeMessage(stdout, out.written());
}

fn onHover(
    io: std.Io,
    arena: std.mem.Allocator,
    server: *Server,
    stdout: *std.Io.Writer,
    msg: std.json.ObjectMap,
    id: ?std.json.Value,
) !void {
    if (try gasAt(io, arena, server, msg)) |g| {
        const hit = (try asm_symbols.resolveAt(arena, g.program, g.offset)) orelse
            return replyNull(arena, stdout, id);
        const at = asm_symbols.place(g.program, hit.ref);
        const s0 = symbols.positionOf(at.text, at.start);
        const s1 = symbols.positionOf(at.text, at.end);
        return writeHover(arena, stdout, id, try asm_symbols.hoverText(arena, hit.key, hit.symbol), s0, s1);
    }
    const found = (try resolveAt(arena, server, msg)) orelse
        return replyNull(arena, stdout, id);
    const b = found.hit.binding;

    // `name: type` where a type is known, and the kind underneath, so
    // hovering says both what this is and what it is called elsewhere.
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena, "```gero\n");
    try text.appendSlice(arena, b.name);
    if (found.hit.type_text) |t| {
        try text.appendSlice(arena, ": ");
        try text.appendSlice(arena, t);
    }
    try text.appendSlice(arena, "\n```\n\n");
    try text.appendSlice(arena, kindText(b.kind));
    if (b.module) |m| {
        try text.appendSlice(arena, ", imported from `");
        try text.appendSlice(arena, m);
        try text.appendSlice(arena, "`");
    }

    const start = symbols.positionOf(found.src, found.hit.ref.start);
    const end = symbols.positionOf(found.src, found.hit.ref.end);
    try writeHover(arena, stdout, id, text.items, start, end);
}

/// Answer a hover request with markdown covering `start`..`end`.
fn writeHover(
    arena: std.mem.Allocator,
    stdout: *std.Io.Writer,
    id: ?std.json.Value,
    markdown: []const u8,
    start: symbols.Position,
    end: symbols.Position,
) !void {
    var out = std.Io.Writer.Allocating.init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try writeId(&jw, id);
    try jw.objectField("result");
    try jw.beginObject();
    try jw.objectField("contents");
    try jw.beginObject();
    try jw.objectField("kind");
    try jw.write("markdown");
    try jw.objectField("value");
    try jw.write(markdown);
    try jw.endObject();
    try jw.objectField("range");
    try writeRange(&jw, start.line, start.character, end.line, end.character);
    try jw.endObject();
    try jw.endObject();
    try protocol.writeMessage(stdout, out.written());
}

fn onReferences(
    io: std.Io,
    arena: std.mem.Allocator,
    server: *Server,
    stdout: *std.Io.Writer,
    msg: std.json.ObjectMap,
    id: ?std.json.Value,
) !void {
    const uri = docUri(msg) orelse return replyNull(arena, stdout, id);
    const text = server.docs.get(uri) orelse return replyNull(arena, stdout, id);
    const lang = analysis.langOf(uri) orelse return replyNull(arena, stdout, id);
    const pos = requestPosition(msg) orelse return replyNull(arena, stdout, id);

    // The client says whether the declaration itself belongs in the
    // results; some editors list it, some only want the uses.
    var include_decl = true;
    if (objectAt(msg, &.{ "params", "context" })) |ctx| {
        if (ctx.get("includeDeclaration")) |v| {
            if (v == .bool) include_decl = v.bool;
        }
    }

    if (lang == .gas) {
        const g = (try gasAt(io, arena, server, msg)) orelse return replyNull(arena, stdout, id);
        const spans = (try asm_symbols.referencesTo(arena, g.program, g.offset, include_decl)) orelse
            return replyNull(arena, stdout, id);

        var gout = std.Io.Writer.Allocating.init(arena);
        var gjw: std.json.Stringify = .{ .writer = &gout.writer, .options = .{ .whitespace = .minified } };
        try gjw.beginObject();
        try gjw.objectField("jsonrpc");
        try gjw.write("2.0");
        try writeId(&gjw, id);
        try gjw.objectField("result");
        try gjw.beginArray();
        for (spans) |sp| {
            try gjw.beginObject();
            try writeGasLocation(&gjw, arena, uri, g.program, sp);
            try gjw.endObject();
        }
        try gjw.endArray();
        try gjw.endObject();
        return protocol.writeMessage(stdout, gout.written());
    }
    if (lang != .gr) return replyNull(arena, stdout, id);

    const spans = (try symbols.referencesTo(arena, text, pos, include_decl)) orelse
        return replyNull(arena, stdout, id);

    var out = std.Io.Writer.Allocating.init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try writeId(&jw, id);
    try jw.objectField("result");
    try jw.beginArray();
    for (spans) |sp| {
        const a = symbols.positionOf(text, sp.start);
        const b = symbols.positionOf(text, sp.end);
        try jw.beginObject();
        try jw.objectField("uri");
        try jw.write(uri);
        try jw.objectField("range");
        try writeRange(&jw, a.line, a.character, b.line, b.character);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
    try protocol.writeMessage(stdout, out.written());
}

fn onInlayHint(
    arena: std.mem.Allocator,
    server: *Server,
    stdout: *std.Io.Writer,
    msg: std.json.ObjectMap,
    id: ?std.json.Value,
) !void {
    const uri = docUri(msg) orelse return replyNull(arena, stdout, id);
    const text = server.docs.get(uri) orelse return replyNull(arena, stdout, id);
    const lang = analysis.langOf(uri) orelse return replyNull(arena, stdout, id);
    if (lang != .gr) return replyNull(arena, stdout, id);

    const hints = try symbols.inlayHints(arena, text);

    var out = std.Io.Writer.Allocating.init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try writeId(&jw, id);
    try jw.objectField("result");
    try jw.beginArray();
    for (hints) |h| {
        const at = symbols.positionOf(text, h.at);
        try jw.beginObject();
        try jw.objectField("position");
        try jw.beginObject();
        try jw.objectField("line");
        try jw.write(at.line);
        try jw.objectField("character");
        try jw.write(at.character);
        try jw.endObject();
        try jw.objectField("label");
        try jw.write(try std.fmt.allocPrint(arena, ": {s}", .{h.text}));
        // Type hints, so an editor can style them apart from parameter
        // names if it distinguishes the two.
        try jw.objectField("kind");
        try jw.write(@as(u8, 1));
        try jw.objectField("paddingLeft");
        try jw.write(false);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
    try protocol.writeMessage(stdout, out.written());
}

fn onCompletion(
    io: std.Io,
    arena: std.mem.Allocator,
    server: *Server,
    stdout: *std.Io.Writer,
    msg: std.json.ObjectMap,
    id: ?std.json.Value,
) !void {
    const uri = docUri(msg) orelse return replyNull(arena, stdout, id);
    const text = server.docs.get(uri) orelse return replyNull(arena, stdout, id);
    const lang = analysis.langOf(uri) orelse return replyNull(arena, stdout, id);

    // Asm completes the symbols the program defines. There is no
    // scope to respect: a name means one thing across a program.
    if (lang == .gas) {
        var gov = try server.overlay(io, arena);
        defer gov.deinit(arena);
        const program = (try analysis.gasProgram(io, arena, uri, text, &gov)) orelse
            return replyNull(arena, stdout, id);
        return writeAsmCompletions(arena, stdout, id, try asm_symbols.completions(arena, program));
    }
    if (lang != .gr) return replyNull(arena, stdout, id);
    const pos = requestPosition(msg) orelse return replyNull(arena, stdout, id);

    var ov = try server.overlay(io, arena);
    defer ov.deinit(arena);
    try server.index.rebuild(io, &ov, try uri_mod.toPath(arena, uri));
    const doc_path = try uri_mod.toPath(arena, uri);
    const doc_dir = if (doc_path) |dp| std.fs.path.dirname(dp) else null;
    const list = try symbols.completionsAt(arena, text, &server.index, doc_dir, pos);

    var out = std.Io.Writer.Allocating.init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try writeId(&jw, id);
    try jw.objectField("result");
    try jw.beginObject();
    try jw.objectField("isIncomplete");
    try jw.write(list.is_incomplete);
    try jw.objectField("items");
    try jw.beginArray();
    const at = symbols.useInsertLine(text);
    for (list.items) |it| {
        try jw.beginObject();
        try jw.objectField("label");
        try jw.write(it.name);
        try jw.objectField("kind");
        try jw.write(symbols.completionKind(it.kind));
        try jw.objectField("detail");
        if (it.import) |imp| {
            try jw.write(try std.fmt.allocPrint(arena, "from {s}", .{imp.module}));
        } else {
            try jw.write(kindText(it.kind));
        }
        // A name already in scope sorts above one that has to be
        // imported: the user reaching for a local should not have to
        // scroll past the stdlib to find it.
        try jw.objectField("sortText");
        try jw.write(try std.fmt.allocPrint(arena, "{d}{s}", .{
            @as(u8, if (it.import == null) 0 else 1),
            it.name,
        }));
        if (it.import) |imp| {
            // Applied when the item is accepted, alongside the word
            // the client inserts itself.
            try jw.objectField("additionalTextEdits");
            try jw.beginArray();
            try jw.beginObject();
            try jw.objectField("range");
            try writeRange(&jw, at, 0, at, 0);
            try jw.objectField("newText");
            try jw.write(try std.fmt.allocPrint(arena, "use {s} from {s}\n", .{ imp.name, imp.module }));
            try jw.endObject();
            try jw.endArray();
        }
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
    try jw.endObject();
    try protocol.writeMessage(stdout, out.written());
}

/// How a kind reads in a hover card.
fn kindText(k: gero.lang.scope.SymbolKind) []const u8 {
    return switch (k) {
        .let_binding => "a `let` binding",
        .const_binding => "a `const` binding",
        .param => "a parameter",
        .function => "a function",
        .class => "a class",
        .struct_ => "a struct",
        .enum_ => "an enum",
        .module_alias => "a module alias",
        .imported => "an imported name",
        .field => "a field",
    };
}

/// Answer `textDocument/codeAction` with the quick-fixes for the
/// diagnostics under the editor's selection.
///
/// The document is re-analyzed rather than served from what was last
/// published: the client sends its own copy of the diagnostics in
/// `context`, and trusting those would mean applying a fix computed
/// against text the user has since edited.
fn onCodeAction(
    io: std.Io,
    arena: std.mem.Allocator,
    server: *Server,
    stdout: *std.Io.Writer,
    msg: std.json.ObjectMap,
    id: ?std.json.Value,
) !void {
    const uri = docUri(msg) orelse return replyNull(arena, stdout, id);
    const text = server.docs.get(uri) orelse return replyNull(arena, stdout, id);
    const lang = analysis.langOf(uri) orelse return replyNull(arena, stdout, id);
    if (lang != .gr) return replyNull(arena, stdout, id);
    const range = requestRange(msg) orelse return replyNull(arena, stdout, id);

    var ov = try server.overlay(io, arena);
    defer ov.deinit(arena);
    const result = analysis.diagnose(io, arena, lang, uri, text, &ov) catch |err| switch (err) {
        error.OutOfMemory => return err,
        // The document names a file that cannot be read — nothing to fix.
        else => return replyNull(arena, stdout, id),
    };

    var mine: []const analysis.Diagnostic = &.{};
    for (result.files) |f| {
        if (std.mem.eql(u8, f.uri, uri)) {
            mine = f.items;
            break;
        }
    }
    try server.index.rebuild(io, &ov, try uri_mod.toPath(arena, uri));
    const doc_path = try uri_mod.toPath(arena, uri);
    const doc_dir = if (doc_path) |dp| std.fs.path.dirname(dp) else null;
    const actions = try symbols.codeActionsAt(arena, text, mine, &server.index, doc_dir, range.start, range.end);

    var out = std.Io.Writer.Allocating.init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try writeId(&jw, id);
    try jw.objectField("result");
    try jw.beginArray();
    for (actions) |a| try writeCodeAction(&jw, uri, a, actions.len == 1);
    try jw.endArray();
    try jw.endObject();
    try protocol.writeMessage(stdout, out.written());
}

/// One `CodeAction` as the protocol's object, carrying the edit that
/// applies it.
///
/// `preferred` marks the action an editor may apply without showing a
/// menu. Only a lone fix earns that: with several on offer the user
/// has a choice to make, and the protocol allows one preferred action.
fn writeCodeAction(
    jw: *std.json.Stringify,
    uri: []const u8,
    a: symbols.CodeAction,
    preferred: bool,
) !void {
    try jw.beginObject();
    try jw.objectField("title");
    try jw.write(a.title);
    try jw.objectField("kind");
    try jw.write("quickfix");
    try jw.objectField("isPreferred");
    try jw.write(preferred);
    try jw.objectField("diagnostics");
    try jw.beginArray();
    try writeDiagnostic(jw, a.diagnostic);
    try jw.endArray();
    try jw.objectField("edit");
    try jw.beginObject();
    try jw.objectField("changes");
    try jw.beginObject();
    try jw.objectField(uri);
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("range");
    try writeRange(jw, a.start.line, a.start.character, a.end.line, a.end.character);
    try jw.objectField("newText");
    try jw.write(a.new_text);
    try jw.endObject();
    try jw.endArray();
    try jw.endObject();
    try jw.endObject();
    try jw.endObject();
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

/// Publish for `uri`, then for every other open document whose last
/// analysis read `uri`'s file.
///
/// An editor reports only the buffer being typed in, but a `use` /
/// `.include` graph means that edit can invalidate documents the
/// editor said nothing about. Without this fan-out, changing a library
/// leaves every importer showing diagnostics that no longer hold.
fn publishAffected(
    io: std.Io,
    arena: std.mem.Allocator,
    server: *Server,
    stdout: *std.Io.Writer,
    uri: []const u8,
    text: []const u8,
) !void {
    try publish(io, arena, server, stdout, uri, text);

    const changed = try canonicalPathOf(io, arena, uri) orelse return;
    // Collect first: publishing rewrites `deps` as it goes, which
    // would invalidate an iterator held across the loop.
    var affected: std.ArrayList([]const u8) = .empty;
    var it = server.docs.keyIterator();
    while (it.next()) |k| {
        if (std.mem.eql(u8, k.*, uri)) continue;
        if (server.dependsOn(k.*, changed)) try affected.append(arena, k.*);
    }
    for (affected.items) |dependent| {
        const dep_text = server.docs.get(dependent) orelse continue;
        try publish(io, arena, server, stdout, dependent, dep_text);
    }
}

/// Canonical filesystem path for `uri`, or `null` when it names no
/// readable file.
fn canonicalPathOf(io: std.Io, arena: std.mem.Allocator, uri: []const u8) !?[]const u8 {
    const path = (try uri_mod.toPath(arena, uri)) orelse return null;
    return std.Io.Dir.cwd().realPathFileAlloc(io, path, arena) catch null;
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
    var result: analysis.Analysis = .{ .files = &.{}, .graph_files = &.{} };
    if (analysis.langOf(uri)) |lang| {
        var ov = try server.overlay(io, arena);
        defer ov.deinit(arena);
        result = analysis.diagnose(io, arena, lang, uri, text, &ov) catch |err| switch (err) {
            error.OutOfMemory => return err,
            // The document names a file that cannot be read — it was
            // deleted or renamed under the editor. Nothing to report.
            else => .{ .files = &.{}, .graph_files = &.{} },
        };
    }
    try server.noteDeps(uri, result.graph_files);
    var files = result.files;
    if (files.len == 0) files = &.{.{ .uri = uri, .items = &.{} }};

    var written: UriSet = .{};
    var carrying: UriSet = .{};
    for (files) |f| {
        try writeDiagnostics(arena, stdout, f.uri, f.items);
        try written.put(arena, f.uri, {});
        if (f.items.len > 0) try carrying.put(arena, f.uri, {});
    }
    try server.reconcilePublished(arena, stdout, uri, &written, &carrying);
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
    for (diags) |d| try writeDiagnostic(&jw, d);
    try jw.endArray();
    try jw.endObject();
    try jw.endObject();
    try protocol.writeMessage(stdout, out.written());
}

/// One diagnostic as the protocol's object. A code action attaches the
/// same shape, so an editor can match the fix to what it is showing.
fn writeDiagnostic(jw: *std.json.Stringify, d: analysis.Diagnostic) !void {
    try jw.beginObject();
    try jw.objectField("range");
    try writeRange(jw, d.line, d.character, d.end_line, d.end_character);
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
        return .{ .server = .{ .gpa = gpa, .index = .{ .gpa = gpa } }, .out = std.Io.Writer.Allocating.init(gpa) };
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

    /// Only what was written after `mark` — for a test that sends two
    /// requests and has to tell their replies apart.
    fn writtenSince(self: *Session, mark: usize) []const u8 {
        return self.out.written()[mark..];
    }
};

test "handleMessage: initialize advertises its capabilities" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    _ = try s.send(arena_state.allocator(), "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}");
    const out = s.written();
    try testing.expect(std.mem.indexOf(u8, out, "\"documentFormattingProvider\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"textDocumentSync\":1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"definitionProvider\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"hoverProvider\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"referencesProvider\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"inlayHintProvider\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"completionProvider\"") != null);
    // The id is echoed, or the client cannot match the response.
    try testing.expect(std.mem.indexOf(u8, out, "\"id\":1") != null);
}

/// A buffer the position tests share: `twice` declared on line 0 and
/// called on line 4, `total` bound on line 4 and read on line 5.
const position_src =
    "def twice(n: i16) -> i16\n" ++
    "  return n + n\n" ++
    "end\n" ++
    "def main()\n" ++
    "  let total: i16 = twice(21)\n" ++
    "  print total\n" ++
    "end\n";

fn openPositionDoc(s: *Session, arena: std.mem.Allocator) !void {
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///p.gr\",\"languageId\":\"gero\",\"version\":1,\"text\":");
    var out = std.Io.Writer.Allocating.init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try jw.write(position_src);
    try body.appendSlice(arena, out.written());
    try body.appendSlice(arena, "}}}");
    _ = try s.send(arena, body.items);
}

/// A misspelled reference with its intended name in scope, so the
/// checker has a candidate to suggest. Opened as an `untitled:`
/// buffer — the text is the whole program, with no import graph to
/// resolve from disk.
const typo_src =
    \\def main()
    \\  let helo: i16 = 0
    \\  let x: i16 = helllo
    \\  print x
    \\end
    \\
;

fn openTypoDoc(s: *Session, arena: std.mem.Allocator) !void {
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"untitled:t.gr\",\"languageId\":\"gero\",\"version\":1,\"text\":");
    var out = std.Io.Writer.Allocating.init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try jw.write(typo_src);
    try body.appendSlice(arena, out.written());
    try body.appendSlice(arena, "}}}");
    _ = try s.send(arena, body.items);
}

test "handleMessage: a code action rewrites the typo to the suggested name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    try openTypoDoc(&s, arena);
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"textDocument/codeAction\",\"params\":{\"textDocument\":{\"uri\":\"untitled:t.gr\"},\"range\":{\"start\":{\"line\":2,\"character\":16},\"end\":{\"line\":2,\"character\":16}},\"context\":{\"diagnostics\":[]}}}");
    const out = s.written();
    try testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"quickfix\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"title\":\"Change to `helo`\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"newText\":\"helo\"") != null);
    // The edit must cover `helllo` alone — columns 15..21 of line 2.
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "\"range\":{\"start\":{\"line\":2,\"character\":15},\"end\":{\"line\":2,\"character\":21}},\"newText\":\"helo\"",
    ) != null);
}

test "handleMessage: a range with no diagnostic in it yields no actions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    try openTypoDoc(&s, arena);
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"textDocument/codeAction\",\"params\":{\"textDocument\":{\"uri\":\"untitled:t.gr\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":3}},\"context\":{\"diagnostics\":[]}}}");
    try testing.expect(std.mem.indexOf(u8, s.written(), "\"id\":6,\"result\":[]") != null);
}

/// Two misspellings on one line, so a selection covering both gets two
/// actions and neither can be the one an editor applies unprompted.
const two_typos_src =
    \\def main()
    \\  let helo: i16 = 0
    \\  let total: i16 = 0
    \\  let x: i16 = helllo + totl
    \\  print x
    \\end
    \\
;

test "handleMessage: one fix on offer is preferred, several are not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"untitled:two.gr\",\"languageId\":\"gero\",\"version\":1,\"text\":");
    var out = std.Io.Writer.Allocating.init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try jw.write(two_typos_src);
    try body.appendSlice(arena, out.written());
    try body.appendSlice(arena, "}}}");
    _ = try s.send(arena, body.items);

    // The whole of line 3, covering both typos.
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"textDocument/codeAction\",\"params\":{\"textDocument\":{\"uri\":\"untitled:two.gr\"},\"range\":{\"start\":{\"line\":3,\"character\":0},\"end\":{\"line\":3,\"character\":28}},\"context\":{\"diagnostics\":[]}}}");
    const both = s.written();
    try testing.expect(std.mem.indexOf(u8, both, "\"newText\":\"helo\"") != null);
    try testing.expect(std.mem.indexOf(u8, both, "\"newText\":\"total\"") != null);
    try testing.expect(std.mem.indexOf(u8, both, "\"isPreferred\":true") == null);

    // A caret on one of them alone offers a single, preferred fix.
    const mark = s.written().len;
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"textDocument/codeAction\",\"params\":{\"textDocument\":{\"uri\":\"untitled:two.gr\"},\"range\":{\"start\":{\"line\":3,\"character\":17},\"end\":{\"line\":3,\"character\":17}},\"context\":{\"diagnostics\":[]}}}");
    const one = s.writtenSince(mark);
    try testing.expect(std.mem.indexOf(u8, one, "\"isPreferred\":true") != null);
    try testing.expect(std.mem.indexOf(u8, one, "\"newText\":\"totl\"") == null);
}

test "replyInitialize: the server advertises quickfix code actions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}");
    try testing.expect(std.mem.indexOf(u8, s.written(), "\"codeActionProvider\":{\"codeActionKinds\":[\"quickfix\"]}") != null);
}

test "handleMessage: definition jumps to the declaration, not the reference" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    try openPositionDoc(&s, arena);
    // The `twice` inside `twice(21)` on line 4.
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///p.gr\"},\"position\":{\"line\":4,\"character\":19}}}");
    // `def twice` is line 0 and the name starts at column 4. Asserted
    // as one fragment so a coincidental line 0 in a diagnostic cannot
    // pass the test.
    try testing.expect(std.mem.indexOf(
        u8,
        s.written(),
        "\"range\":{\"start\":{\"line\":0,\"character\":4}",
    ) != null);
}

test "handleMessage: hover names the binding and its type" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    try openPositionDoc(&s, arena);
    // The `total` in `print total` on line 5.
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///p.gr\"},\"position\":{\"line\":5,\"character\":9}}}");
    const out = s.written();
    try testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"markdown\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "total: i16") != null);
    try testing.expect(std.mem.indexOf(u8, out, "a `let` binding") != null);
}

test "handleMessage: a position on nothing answers null rather than guessing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    try openPositionDoc(&s, arena);
    // Column 0 of `end` — a keyword, bound to nothing.
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file:///p.gr\"},\"position\":{\"line\":2,\"character\":0}}}");
    try testing.expect(std.mem.indexOf(u8, s.written(), "\"id\":4,\"result\":null") != null);
}

/// One annotated binder and one inferred, so a hint appearing for the
/// wrong one is visible.
const hint_src =
    "def main()\n" ++
    "  let inferred = 40 + 2\n" ++
    "  let stated: i16 = 3\n" ++
    "  print inferred\n" ++
    "  print inferred\n" ++
    "end\n";

fn openDoc(s: *Session, arena: std.mem.Allocator, text: []const u8) !void {
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///h.gr\",\"languageId\":\"gero\",\"version\":1,\"text\":");
    var out = std.Io.Writer.Allocating.init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try jw.write(text);
    try body.appendSlice(arena, out.written());
    try body.appendSlice(arena, "}}}");
    _ = try s.send(arena, body.items);
}

/// Open an `untitled:` `.gas` buffer — no file behind it, so fused
/// offsets are the buffer's own and no include graph is resolved.
fn openAsmDoc(s: *Session, arena: std.mem.Allocator, text: []const u8) !void {
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"untitled:a.gas\",\"languageId\":\"gero-asm\",\"version\":1,\"text\":");
    var out = std.Io.Writer.Allocating.init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try jw.write(text);
    try body.appendSlice(arena, out.written());
    try body.appendSlice(arena, "}}}");
    _ = try s.send(arena, body.items);
}

const asm_src =
    "const PRINT = $10\n" ++
    "main:\n" ++
    ".loop:\n" ++
    "  djnz r1, .loop\n" ++
    "  int PRINT\n" ++
    "  call emit\n" ++
    "  hlt\n" ++
    "emit:\n" ++
    "  ret\n";

test "handleMessage: asm definition jumps to the label's declaration" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    try openAsmDoc(&s, arena, asm_src);
    const before = s.written().len;
    // The `emit` in `call emit` on line 5.
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"untitled:a.gas\"},\"position\":{\"line\":5,\"character\":8}}}");
    const reply = s.written()[before..];
    // `emit:` declares on line 7.
    try testing.expect(std.mem.indexOf(u8, reply, "\"start\":{\"line\":7") != null);
}

test "handleMessage: asm definition resolves a local label under its parent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    try openAsmDoc(&s, arena, asm_src);
    const before = s.written().len;
    // The `.loop` in `djnz r1, .loop` on line 3.
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"untitled:a.gas\"},\"position\":{\"line\":3,\"character\":12}}}");
    const reply = s.written()[before..];
    // `.loop:` declares on line 2, not `main:` on line 1.
    try testing.expect(std.mem.indexOf(u8, reply, "\"start\":{\"line\":2") != null);
}

test "handleMessage: asm hover reports the address a name assembled to" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    try openAsmDoc(&s, arena, asm_src);
    const before = s.written().len;
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":22,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"untitled:a.gas\"},\"position\":{\"line\":4,\"character\":7}}}");
    const reply = s.written()[before..];
    try testing.expect(std.mem.indexOf(u8, reply, "const PRINT = $0010") != null);
    try testing.expect(std.mem.indexOf(u8, reply, "a constant") != null);
}

test "handleMessage: asm references cover the declaration and every use" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    try openAsmDoc(&s, arena, asm_src);
    const before = s.written().len;
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":23,\"method\":\"textDocument/references\",\"params\":{\"textDocument\":{\"uri\":\"untitled:a.gas\"},\"position\":{\"line\":4,\"character\":7},\"context\":{\"includeDeclaration\":true}}}");
    const with_decl = s.written()[before..];
    // The `const` on line 0 and the `int PRINT` on line 4.
    try testing.expect(std.mem.indexOf(u8, with_decl, "\"start\":{\"line\":0") != null);
    try testing.expect(std.mem.indexOf(u8, with_decl, "\"start\":{\"line\":4") != null);

    const mark = s.written().len;
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":24,\"method\":\"textDocument/references\",\"params\":{\"textDocument\":{\"uri\":\"untitled:a.gas\"},\"position\":{\"line\":4,\"character\":7},\"context\":{\"includeDeclaration\":false}}}");
    const without = s.writtenSince(mark);
    try testing.expect(std.mem.indexOf(u8, without, "\"start\":{\"line\":0") == null);
    try testing.expect(std.mem.indexOf(u8, without, "\"start\":{\"line\":4") != null);
}

test "handleMessage: asm completion offers the program's symbols" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    try openAsmDoc(&s, arena, asm_src);
    const before = s.written().len;
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":25,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"untitled:a.gas\"},\"position\":{\"line\":6,\"character\":2}}}");
    const reply = s.written()[before..];
    try testing.expect(std.mem.indexOf(u8, reply, "\"label\":\"emit\"") != null);
    try testing.expect(std.mem.indexOf(u8, reply, "\"label\":\"PRINT\"") != null);
    try testing.expect(std.mem.indexOf(u8, reply, "\"label\":\"main.loop\"") != null);
    // A symbol set is fixed; nothing typed next adds to it.
    try testing.expect(std.mem.indexOf(u8, reply, "\"isIncomplete\":false") != null);
}

test "handleMessage: an asm position on no name answers null" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    try openAsmDoc(&s, arena, asm_src);
    const before = s.written().len;
    // Column 2 of `  hlt` — a mnemonic, which names no symbol.
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":26,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"untitled:a.gas\"},\"position\":{\"line\":6,\"character\":3}}}");
    try testing.expect(std.mem.indexOf(u8, s.written()[before..], "\"id\":26,\"result\":null") != null);
}

test "handleMessage: inlay hints cover the inferred binder and not the stated one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    try openDoc(&s, arena, hint_src);
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/inlayHint\",\"params\":{\"textDocument\":{\"uri\":\"file:///h.gr\"},\"range\":{}}}");
    const out = s.written();

    // `let inferred` ends at line 1, column 14.
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "\"position\":{\"line\":1,\"character\":14},\"label\":\": i16\"",
    ) != null);
    // Repeating a type the author wrote is noise, so line 2 gets none.
    try testing.expect(std.mem.indexOf(u8, out, "\"line\":2,\"character\"") == null);
}

test "handleMessage: references find the declaration and every use" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    try openDoc(&s, arena, hint_src);
    // The `inferred` in the first `print`, on line 3.
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/references\",\"params\":{\"textDocument\":{\"uri\":\"file:///h.gr\"},\"position\":{\"line\":3,\"character\":9},\"context\":{\"includeDeclaration\":true}}}");
    const out = s.written();

    // The binder on line 1 and both reads, in source order.
    try testing.expect(std.mem.indexOf(u8, out, "\"line\":1,\"character\":6") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"line\":3,\"character\":8") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"line\":4,\"character\":8") != null);
}

test "handleMessage: references can leave the declaration out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    try openDoc(&s, arena, hint_src);
    const before = s.written().len;
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/references\",\"params\":{\"textDocument\":{\"uri\":\"file:///h.gr\"},\"position\":{\"line\":3,\"character\":9},\"context\":{\"includeDeclaration\":false}}}");
    const reply = s.written()[before..];
    try testing.expect(std.mem.indexOf(u8, reply, "\"line\":3,\"character\":8") != null);
    try testing.expect(std.mem.indexOf(u8, reply, "\"line\":1,\"character\":6") == null);
}

/// Two functions, so a local in one must not be offered in the other.
const completion_src =
    "def helper(n: i16) -> i16\n" ++
    "  let scoped = n * 2\n" ++
    "  return scoped\n" ++
    "end\n" ++
    "def main()\n" ++
    "  let total = 1\n" ++
    "  print total\n" ++
    "end\n";

test "handleMessage: completion offers what is in scope and nothing else" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    try openDoc(&s, arena, completion_src);
    const before = s.written().len;
    // Inside `main`, on the line after `let total`.
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file:///h.gr\"},\"position\":{\"line\":6,\"character\":8}}}");
    const reply = s.written()[before..];

    // Module-level names are visible throughout the file.
    try testing.expect(std.mem.indexOf(u8, reply, "\"label\":\"helper\"") != null);
    try testing.expect(std.mem.indexOf(u8, reply, "\"label\":\"main\"") != null);
    // The local in this function is in scope.
    try testing.expect(std.mem.indexOf(u8, reply, "\"label\":\"total\"") != null);
    // The other function's local and parameter are not — offering them
    // is the failure that makes completion untrustworthy.
    try testing.expect(std.mem.indexOf(u8, reply, "\"label\":\"scoped\"") == null);
    try testing.expect(std.mem.indexOf(u8, reply, "\"label\":\"n\"") == null);
}

/// A prefix matching a stdlib export nothing has imported.
const autoimport_src =
    "def main()\n" ++
    "  let x: fixed = fixed_s\n" ++
    "end\n";

test "handleMessage: an unimported stdlib name completes with the `use` it needs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    try openDoc(&s, arena, autoimport_src);
    const before = s.written().len;
    // Just past `fixed_s` on line 1.
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file:///h.gr\"},\"position\":{\"line\":1,\"character\":24}}}");
    const reply = s.written()[before..];

    try testing.expect(std.mem.indexOf(u8, reply, "\"label\":\"fixed_sin\"") != null);
    try testing.expect(std.mem.indexOf(u8, reply, "\"detail\":\"from math\"") != null);
    // Accepting it inserts the import alongside the word.
    try testing.expect(std.mem.indexOf(u8, reply, "\"newText\":\"use fixed_sin from math\\n\"") != null);
    // An in-scope name sorts ahead of one that has to be imported.
    try testing.expect(std.mem.indexOf(u8, reply, "\"sortText\":\"0main\"") != null);
    try testing.expect(std.mem.indexOf(u8, reply, "\"sortText\":\"1fixed_sin\"") != null);
    // The set depends on the prefix, so the client must ask again.
    try testing.expect(std.mem.indexOf(u8, reply, "\"isIncomplete\":true") != null);
}

test "handleMessage: an already-imported name completes without a redundant import" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    try openDoc(&s, arena, "use abs from math\ndef main()\n  print ab\nend\n");
    const before = s.written().len;
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file:///h.gr\"},\"position\":{\"line\":2,\"character\":10}}}");
    const reply = s.written()[before..];

    try testing.expect(std.mem.indexOf(u8, reply, "\"label\":\"abs\"") != null);
    // In scope already, so no edit and no second entry for it.
    try testing.expect(std.mem.indexOf(u8, reply, "additionalTextEdits") == null);
}

test "initialize: `.` is advertised as a completion trigger" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}");
    const out = s.written();
    // A client asks on its own while an identifier is being typed, but
    // never on `.` — a member list would only ever open by hand.
    try testing.expect(std.mem.indexOf(u8, out, "\"triggerCharacters\":[\".\"]") != null);
}

test "handleMessage: a stdlib module completes its own functions after a dot" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    try openDoc(&s, arena, "use math\ndef main()\n  let x: fixed = math.\nend\n");
    const before = s.written().len;
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file:///h.gr\"},\"position\":{\"line\":2,\"character\":22}}}");
    const reply = s.written()[before..];

    try testing.expect(std.mem.indexOf(u8, reply, "\"label\":\"fixed_sin\"") != null);
    try testing.expect(std.mem.indexOf(u8, reply, "\"label\":\"sqrt_fixed\"") != null);
    // A receiver's members are a fixed set — nothing typed next adds
    // to it, and nothing outside the module belongs in the list.
    try testing.expect(std.mem.indexOf(u8, reply, "\"isIncomplete\":false") != null);
    try testing.expect(std.mem.indexOf(u8, reply, "\"label\":\"main\"") == null);
}

test "handleMessage: an aliased module completes under its alias" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    try openDoc(&s, arena, "use mem as m\ndef main()\n  m.\nend\n");
    const before = s.written().len;
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file:///h.gr\"},\"position\":{\"line\":2,\"character\":4}}}");
    const reply = s.written()[before..];

    try testing.expect(std.mem.indexOf(u8, reply, "\"label\":\"poke\"") != null);
    try testing.expect(std.mem.indexOf(u8, reply, "\"label\":\"memcpy\"") != null);
}

test "handleMessage: completion does not offer a local above its declaration" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    try openDoc(&s, arena, completion_src);
    const before = s.written().len;
    // Inside `helper`, on its first body line — `scoped` is declared
    // on that line and is not usable before it.
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file:///h.gr\"},\"position\":{\"line\":1,\"character\":2}}}");
    const reply = s.written()[before..];

    try testing.expect(std.mem.indexOf(u8, reply, "\"label\":\"scoped\"") == null);
    // A `def` is usable anywhere in the file, including above itself.
    try testing.expect(std.mem.indexOf(u8, reply, "\"label\":\"main\"") != null);
}

/// One of each container, and a buffer that stops mid-member — which
/// is what a file looks like when completion is asked for.
const member_src =
    "struct Point\n  x: i16,\n  y: i16\nend\n" ++
    "enum Colour\n  case Red\n  case Blue\nend\n" ++
    "class Fighter\n  let hp: i16\n  def hurt(self, n: i16)\n    self.hp = self.hp - n\n  end\nend\n" ++
    "def main()\n  let p: Point = Point { x: 1, y: 2 }\n  print p.\nend\n";

fn completeAt(s: *Session, arena: std.mem.Allocator, id: u8, line: u32, ch: u32) ![]const u8 {
    const before = s.written().len;
    const req = try std.fmt.allocPrint(
        arena,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"textDocument/completion\",\"params\":{{\"textDocument\":{{\"uri\":\"file:///h.gr\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}}}",
        .{ id, line, ch },
    );
    _ = try s.send(arena, req);
    return s.written()[before..];
}

test "handleMessage: completion after a dot offers members, not what is in scope" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    try openDoc(&s, arena, member_src);
    // Just past `p.` on the last line of `main`'s body.
    const reply = try completeAt(&s, arena, 20, 16, 10);

    try testing.expect(std.mem.indexOf(u8, reply, "\"label\":\"x\"") != null);
    try testing.expect(std.mem.indexOf(u8, reply, "\"label\":\"y\"") != null);
    // Nothing in scope can follow a dot, so none of it is offered.
    try testing.expect(std.mem.indexOf(u8, reply, "\"label\":\"main\"") == null);
    try testing.expect(std.mem.indexOf(u8, reply, "\"label\":\"Colour\"") == null);
}

test "handleMessage: a container named directly offers its own members" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    const src = member_src ++ "def other()\n  print Colour.\nend\n";
    try openDoc(&s, arena, src);
    // Past `Colour.` — the enum itself, not a value of it.
    const reply = try completeAt(&s, arena, 21, 19, 15);

    try testing.expect(std.mem.indexOf(u8, reply, "\"label\":\"Red\"") != null);
    try testing.expect(std.mem.indexOf(u8, reply, "\"label\":\"Blue\"") != null);
}

test "handleMessage: a method is not offered as a free function" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    try openDoc(&s, arena, member_src);
    // Inside `main`, at module nesting — `hurt` belongs to `Fighter`
    // and cannot be called here.
    const reply = try completeAt(&s, arena, 22, 15, 2);

    try testing.expect(std.mem.indexOf(u8, reply, "\"label\":\"Fighter\"") != null);
    try testing.expect(std.mem.indexOf(u8, reply, "\"label\":\"hurt\"") == null);
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

    // A request left unanswered blocks the client forever. The method
    // has to be one the server really does not implement — this test
    // used `textDocument/hover` until the server grew it.
    _ = try s.send(arena, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"textDocument/rename\"}");
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
    var s = Server{ .gpa = testing.allocator, .index = .{ .gpa = testing.allocator } };
    defer s.deinit();
    try s.put("untitled:a.gr", "first");
    try s.put("untitled:a.gr", "second");
    try testing.expectEqual(@as(usize, 1), s.docs.count());
    try testing.expectEqualStrings("second", s.docs.get("untitled:a.gr").?);
}

test "publishAffected: editing a library re-publishes its importers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lib.gr", .data = "def double(n: i16) -> i16\n  return n * 2\nend\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "main.gr", .data = "use \"./lib\"\ndef main()\n  print double(21)\nend\n" });
    const lib_uri = try uriOf(arena, &tmp, "lib.gr");
    const main_uri = try uriOf(arena, &tmp, "main.gr");

    _ = try s.send(arena, try didOpen(arena, main_uri, "use \"./lib\"\ndef main()\n  print double(21)\nend\n"));
    _ = try s.send(arena, try didOpen(arena, lib_uri, "def double(n: i16) -> i16\n  return n * 2\nend\n"));

    // Rename `double` in the library's buffer only. The editor reports
    // that buffer alone, so nothing tells the server to re-check the
    // importer — it has to work that out from the graph it read.
    const before = s.written().len;
    _ = try s.send(arena, try didChange(arena, lib_uri, "def renamed(n: i16) -> i16\n  return n * 2\nend\n"));

    const after = s.written()[before..];
    try testing.expect(std.mem.indexOf(u8, after, main_uri) != null);
    try testing.expect(std.mem.indexOf(u8, after, "undefined symbol `double`") != null);
}

test "publishAffected: opening one document does not clear another's diagnostics" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "broken.gr", .data = "def main()\n  print nope\nend\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "clean.gr", .data = "def ok() -> i16\n  return 1\nend\n" });
    const broken_uri = try uriOf(arena, &tmp, "broken.gr");
    const clean_uri = try uriOf(arena, &tmp, "clean.gr");

    _ = try s.send(arena, try didOpen(arena, broken_uri, "def main()\n  print nope\nend\n"));
    try testing.expect(std.mem.indexOf(u8, s.written(), "undefined symbol `nope`") != null);

    // Opening an unrelated clean file says nothing about the broken
    // one. Clearing across documents would wipe its squiggle, and an
    // editor does not re-open a tab it already holds — so it would
    // stay gone until the file was edited again.
    const before = s.written().len;
    _ = try s.send(arena, try didOpen(arena, clean_uri, "def ok() -> i16\n  return 1\nend\n"));
    const after = s.written()[before..];

    const cleared = try std.fmt.allocPrint(arena, "\"uri\":\"{s}\",\"diagnostics\":[]", .{broken_uri});
    try testing.expect(std.mem.indexOf(u8, after, cleared) == null);
}

test "publishAffected: a fixed error in an imported file is cleared" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lib.gr", .data = "def helper() -> i16\n  return nope\nend\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "app.gr", .data = "use helper from \"./lib\"\ndef main()\n  print helper()\nend\n" });
    const lib_uri = try uriOf(arena, &tmp, "lib.gr");
    const app_uri = try uriOf(arena, &tmp, "app.gr");

    // The error is in the imported file, reported against that file.
    _ = try s.send(arena, try didOpen(arena, app_uri, "use helper from \"./lib\"\ndef main()\n  print helper()\nend\n"));
    try testing.expect(std.mem.indexOf(u8, s.written(), "undefined symbol `nope`") != null);

    // Fixing it has to retract what the earlier analysis published,
    // which is what scoping the record per document must not lose.
    const before = s.written().len;
    _ = try s.send(arena, try didChange(arena, app_uri, "use helper from \"./lib\"\ndef main()\n  print helper()\n  print 1\nend\n"));
    _ = try s.send(arena, try didOpen(arena, lib_uri, "def helper() -> i16\n  return 0\nend\n"));
    const after = s.written()[before..];

    const cleared = try std.fmt.allocPrint(arena, "\"uri\":\"{s}\",\"diagnostics\":[]", .{lib_uri});
    try testing.expect(std.mem.indexOf(u8, after, cleared) != null);
}

test "publishAffected: an unrelated document is not re-published" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = Session.init(testing.allocator);
    defer s.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.gr", .data = "def a() -> i16\n  return 1\nend\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.gr", .data = "def b() -> i16\n  return 2\nend\n" });
    const a_uri = try uriOf(arena, &tmp, "a.gr");
    const b_uri = try uriOf(arena, &tmp, "b.gr");

    _ = try s.send(arena, try didOpen(arena, a_uri, "def a() -> i16\n  return 1\nend\n"));
    _ = try s.send(arena, try didOpen(arena, b_uri, "def b() -> i16\n  return 2\nend\n"));

    // Neither imports the other, so the fan-out must stay narrow
    // rather than re-checking every open buffer on every keystroke.
    const before = s.written().len;
    _ = try s.send(arena, try didChange(arena, a_uri, "def a() -> i16\n  return 11\nend\n"));
    try testing.expect(std.mem.indexOf(u8, s.written()[before..], b_uri) == null);
}

/// `file://` URI of `name` inside `tmp`.
fn uriOf(arena: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    const path = try tmp.dir.realPathFileAlloc(testing.io, name, arena);
    return uri_mod.fromPath(arena, path);
}

fn didOpen(arena: std.mem.Allocator, uri: []const u8, text: []const u8) ![]const u8 {
    return notification(arena, "textDocument/didOpen", uri, text, true);
}

fn didChange(arena: std.mem.Allocator, uri: []const u8, text: []const u8) ![]const u8 {
    return notification(arena, "textDocument/didChange", uri, text, false);
}

/// Build a didOpen / didChange body, JSON-escaping `text` by writing
/// it through the same stringifier the server answers with.
fn notification(
    arena: std.mem.Allocator,
    method: []const u8,
    uri: []const u8,
    text: []const u8,
    is_open: bool,
) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try jw.objectField("method");
    try jw.write(method);
    try jw.objectField("params");
    try jw.beginObject();
    try jw.objectField("textDocument");
    try jw.beginObject();
    try jw.objectField("uri");
    try jw.write(uri);
    if (is_open) {
        try jw.objectField("text");
        try jw.write(text);
    }
    try jw.endObject();
    if (!is_open) {
        try jw.objectField("contentChanges");
        try jw.beginArray();
        try jw.beginObject();
        try jw.objectField("text");
        try jw.write(text);
        try jw.endObject();
        try jw.endArray();
    }
    try jw.endObject();
    try jw.endObject();
    return out.written();
}
