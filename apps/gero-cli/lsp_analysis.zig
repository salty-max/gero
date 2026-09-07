//! The language-server's view of a buffer: format it, or diagnose it.
//!
//! Both operations run over buffer *text* rather than a file on disk,
//! because an editor asks about unsaved edits. Diagnosing goes through
//! the same `gr_diagnostics` entry points `gero check` does, with the
//! open buffers overlaid on the file tree, so a server answer and a
//! CLI answer cannot drift apart.

const std = @import("std");
const gero = @import("gero");
const gr_diagnostics = @import("gr_diagnostics.zig");
const render = gero.diagnostics_json;
const uri_mod = @import("lsp_uri.zig");

/// Which front-end a document belongs to, decided by its URI suffix.
pub const Lang = enum { gas, gr };

/// Front-end for `uri`, or `null` when the suffix is neither — the
/// server then leaves the document alone rather than guessing.
pub fn langOf(uri: []const u8) ?Lang {
    if (std.mem.endsWith(u8, uri, ".gr")) return .gr;
    if (std.mem.endsWith(u8, uri, ".gas")) return .gas;
    return null;
}

/// A diagnostic positioned for LSP: zero-based line and character,
/// with an end position so an editor can underline a range.
pub const Diagnostic = struct {
    line: u32,
    character: u32,
    end_line: u32,
    end_character: u32,
    /// `1` error, `2` warning, `3` information — the LSP severity
    /// numbering, so the server writes it out unchanged.
    severity: u8,
    code: []const u8,
    message: []const u8,
};

/// One analysis: what to publish, and which files it read to decide.
///
/// `graph_files` is what makes a change to an imported file reach its
/// importers — a server that only re-analyzed the edited document
/// would leave every dependent showing stale diagnostics.
pub const Analysis = struct {
    files: []const FileDiagnostics,
    /// Canonical paths of every file the import graph covered. Empty
    /// for a document with no file behind it.
    graph_files: []const []const u8,
};

/// Every diagnostic that belongs to one document. Analyzing a buffer
/// can produce these for more than one document, because a `use` /
/// `.include` graph is checked whole and an error in an imported file
/// belongs on that file rather than on the importer.
pub const FileDiagnostics = struct {
    uri: []const u8,
    items: []const Diagnostic,
};

/// Diagnose the document at `uri` whose current text is `src`.
///
/// When the URI names a file on disk, the whole import graph rooted
/// there is checked — with `overlay` supplying the text of every
/// buffer the editor holds unsaved — and results come back grouped by
/// originating file. A URI with no path (an unsaved "untitled"
/// buffer) is analyzed standalone.
pub fn diagnose(
    io: std.Io,
    arena: std.mem.Allocator,
    lang: Lang,
    uri: []const u8,
    src: []const u8,
    overlay: ?*const gero.lang.Overlay,
) !Analysis {
    const path = try uri_mod.toPath(arena, uri);
    return switch (lang) {
        .gr => diagnoseGr(io, arena, uri, path, src, overlay),
        .gas => diagnoseGas(io, arena, uri, path, src, overlay),
    };
}

fn diagnoseGr(
    io: std.Io,
    arena: std.mem.Allocator,
    uri: []const u8,
    path: ?[]const u8,
    src: []const u8,
    overlay: ?*const gero.lang.Overlay,
) !Analysis {
    const p = path orelse {
        // No file behind the buffer, so no import graph to resolve;
        // the text is the whole program as far as anything can tell.
        const diags = try gr_diagnostics.forGr(arena, src, true, null, null);
        return .{
            .files = try single(arena, uri, try langDiagnostics(arena, src, diags)),
            .graph_files = &.{},
        };
    };

    const res = try gr_diagnostics.forGrFile(io, arena, p, overlay);
    if (res.read_error) return .{ .files = &.{}, .graph_files = &.{} };

    var grouped = Grouped.init(uri);
    for (res.diagnostics) |d| {
        const loc = res.source_map.lookup(d.span.start);
        const text = if (loc) |l| l.file.content else res.source;
        const start = if (loc) |l| l.file_offset else d.span.start;
        const end = start + (d.span.end - d.span.start);
        try grouped.add(arena, if (loc) |l| l.file.path else null, text, start, end, .{
            .severity = severityOf(d.severity),
            .code = try arena.dupe(u8, d.code),
            .message = try arena.dupe(u8, d.message),
        });
    }
    return .{
        .files = try grouped.finish(arena),
        .graph_files = try pathsOf(arena, res.source_map.files.items),
    };
}

fn diagnoseGas(
    io: std.Io,
    arena: std.mem.Allocator,
    uri: []const u8,
    path: ?[]const u8,
    src: []const u8,
    overlay: ?*const gero.lang.Overlay,
) !Analysis {
    const resolved = try resolveGas(io, arena, uri, path, src, overlay);
    switch (resolved) {
        .unresolvable => return .{ .files = &.{}, .graph_files = &.{} },
        .include_errors => |a| return a,
        .ok => {},
    }
    const fused_source = resolved.ok.source;
    const source_map = resolved.ok.source_map;

    // Both passes always run and both error sets are reported: an
    // unknown register or mnemonic parses cleanly and only fails at
    // opcode resolution, so stopping at the parse would hide it.
    // `gero check` reports the union for the same reason.
    const pt = try gero.asm_.parse(arena, fused_source);
    const cg = try gero.asm_.assemble(arena, fused_source, pt, .{});

    var grouped = Grouped.init(uri);
    for ([_][]const gero.asm_.Diagnostic{ pt.errors, cg.errors }) |set| {
        for (set) |d| {
            // safety: a fused-buffer index, bounded well under 4 GiB.
            const at: u32 = @intCast(d.parse_error.index);
            const loc = if (source_map) |sm| sm.lookup(at) else null;
            const text = if (loc) |l| l.file.content else fused_source;
            const start = if (loc) |l| l.file_offset else at;
            try grouped.add(arena, if (loc) |l| l.file.path else null, text, start, start, .{
                .severity = 1,
                .code = if (d.code) |c| c.shortLabel() else "",
                .message = try arena.dupe(u8, d.parse_error.message),
            });
        }
    }
    return .{
        .files = try grouped.finish(arena),
        .graph_files = if (source_map) |sm| try pathsOf(arena, sm.files.items) else &.{},
    };
}

/// A diagnostic before it has been given a position — everything a
/// front-end reports that does not depend on which file it landed in.
const Unplaced = struct {
    severity: u8,
    code: []const u8,
    message: []const u8,
};

/// What resolving a `.gas` document's include graph produced.
const ResolvedGas = union(enum) {
    /// The document names a file that cannot be read.
    unresolvable,
    /// Resolution itself failed — a missing or cyclic include. Nothing
    /// downstream can run, so these are the whole answer.
    include_errors: Analysis,
    ok: struct {
        source: []const u8,
        /// Absent for a document with no file behind it, where fused
        /// offsets are already the buffer's own.
        source_map: ?gero.asm_.SourceMap,
    },
};

fn resolveGas(
    io: std.Io,
    arena: std.mem.Allocator,
    uri: []const u8,
    path: ?[]const u8,
    src: []const u8,
    overlay: ?*const gero.lang.Overlay,
) !ResolvedGas {
    const p = path orelse return .{ .ok = .{ .source = src, .source_map = null } };
    const fused = gero.asm_.resolveIncludesOverlaid(io, arena, p, overlay) catch return .unresolvable;
    if (fused.errors.len > 0) {
        return .{ .include_errors = .{
            .files = try single(arena, uri, try asmDiagnostics(arena, fused.source, fused.errors)),
            .graph_files = try pathsOf(arena, fused.source_map.files.items),
        } };
    }
    return .{ .ok = .{ .source = fused.source, .source_map = fused.source_map } };
}

/// Accumulates diagnostics per originating file, so each document is
/// published once with everything that belongs to it. Files are kept
/// in first-seen order, with the analyzed document always first.
const Grouped = struct {
    root_uri: []const u8,
    by_uri: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(Diagnostic)) = .{},

    fn init(root_uri: []const u8) Grouped {
        return .{ .root_uri = root_uri };
    }

    /// Record `d`, positioning it from `start`/`end` within `text` and
    /// filing it under `path`'s URI (the analyzed document when the
    /// diagnostic could not be traced to a file).
    fn add(
        self: *Grouped,
        arena: std.mem.Allocator,
        path: ?[]const u8,
        text: []const u8,
        start: u32,
        end: u32,
        d: Unplaced,
    ) !void {
        const placed = place(text, start, end, d);
        const key = if (path) |p| try uri_mod.fromPath(arena, p) else self.root_uri;
        const gop = try self.by_uri.getOrPut(arena, key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, placed);
    }

    fn finish(self: *Grouped, arena: std.mem.Allocator) ![]const FileDiagnostics {
        var out: std.ArrayList(FileDiagnostics) = .empty;
        // The analyzed document is published even with nothing to
        // report, so that fixing its last error clears the squiggles.
        try out.append(arena, .{ .uri = self.root_uri, .items = &.{} });
        var it = self.by_uri.iterator();
        while (it.next()) |e| {
            const items = try e.value_ptr.toOwnedSlice(arena);
            if (std.mem.eql(u8, e.key_ptr.*, self.root_uri)) {
                out.items[0].items = items;
            } else {
                try out.append(arena, .{ .uri = e.key_ptr.*, .items = items });
            }
        }
        return out.toOwnedSlice(arena);
    }
};

fn single(
    arena: std.mem.Allocator,
    uri: []const u8,
    items: []const Diagnostic,
) std.mem.Allocator.Error![]const FileDiagnostics {
    const out = try arena.alloc(FileDiagnostics, 1);
    out[0] = .{ .uri = uri, .items = items };
    return out;
}

/// Resolve `start`/`end` to zero-based LSP positions within `text`.
fn place(text: []const u8, start: u32, end: u32, d: Unplaced) Diagnostic {
    const at_start = render.lineColIn(text, start);
    const at_end = render.lineColIn(text, end);
    return .{
        // safety: line/col of an offset in a source file, far under 4 GiB.
        .line = @intCast(at_start.line - 1),
        .character = @intCast(at_start.col - 1),
        .end_line = @intCast(at_end.line - 1),
        .end_character = @intCast(at_end.col - 1),
        .severity = d.severity,
        .code = d.code,
        .message = d.message,
    };
}

/// Canonical paths of the files a resolved graph covered.
fn pathsOf(arena: std.mem.Allocator, files: anytype) std.mem.Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, files.len);
    for (files, 0..) |f, i| out[i] = f.path;
    return out;
}

fn severityOf(s: gero.lang.Severity) u8 {
    return switch (s) {
        .fatal => 1,
        .warning => 2,
        .note => 3,
    };
}

/// Position a standalone buffer's lang diagnostics against its text.
fn langDiagnostics(
    arena: std.mem.Allocator,
    src: []const u8,
    diags: []const gero.lang.Diagnostic,
) std.mem.Allocator.Error![]const Diagnostic {
    var out: std.ArrayList(Diagnostic) = .empty;
    for (diags) |d| {
        try out.append(arena, place(src, d.span.start, d.span.end, .{
            .severity = severityOf(d.severity),
            .code = try arena.dupe(u8, d.code),
            .message = try arena.dupe(u8, d.message),
        }));
    }
    return out.toOwnedSlice(arena);
}

/// Position include-resolution errors against the fused buffer.
fn asmDiagnostics(
    arena: std.mem.Allocator,
    src: []const u8,
    diags: []const gero.asm_.Diagnostic,
) std.mem.Allocator.Error![]const Diagnostic {
    var out: std.ArrayList(Diagnostic) = .empty;
    for (diags) |d| {
        // safety: a fused-buffer index, bounded well under 4 GiB.
        const at: u32 = @intCast(d.parse_error.index);
        try out.append(arena, place(src, at, at, .{
            .severity = 1,
            .code = if (d.code) |c| c.shortLabel() else "",
            .message = try arena.dupe(u8, d.parse_error.message),
        }));
    }
    return out.toOwnedSlice(arena);
}

/// Canonical form of `src`, or `null` when it does not parse — an
/// editor's format-on-save must leave a broken buffer untouched
/// rather than rewrite it from a partial tree.
pub fn format(
    arena: std.mem.Allocator,
    lang: Lang,
    src: []const u8,
) std.mem.Allocator.Error!?[]const u8 {
    return switch (lang) {
        .gr => formatGr(arena, src),
        .gas => formatGas(arena, src),
    };
}

fn formatGr(arena: std.mem.Allocator, src: []const u8) std.mem.Allocator.Error!?[]const u8 {
    var stream = gero.lang.tokenize(arena, src) catch return null;
    defer stream.deinit();
    var tree = gero.lang.parse(arena, src, stream) catch return null;
    defer tree.deinit();
    if (stream.errors.len > 0 or tree.errors.len > 0) return null;

    var out = std.Io.Writer.Allocating.init(arena);
    gero.lang.print(&out.writer, &tree.program, src, tree.comments) catch return null;
    return out.written();
}

fn formatGas(arena: std.mem.Allocator, src: []const u8) std.mem.Allocator.Error!?[]const u8 {
    var pt = gero.asm_.parse(arena, src) catch return null;
    defer pt.deinit();
    if (pt.errors.len > 0) return null;

    var out = std.Io.Writer.Allocating.init(arena);
    gero.asm_.printProgram(&out.writer, &pt.program, src, gero.asm_.default_print_options) catch return null;
    return out.written();
}

// ---------- tests ----------

const testing = std.testing;

/// Diagnose an untitled buffer — no path, so no import graph.
fn diagnoseText(arena: std.mem.Allocator, lang: Lang, src: []const u8) ![]const Diagnostic {
    const result = try diagnose(testing.io, arena, lang, "untitled:buffer", src, null);
    try testing.expectEqual(@as(usize, 1), result.files.len);
    return result.files[0].items;
}

test "langOf: dispatches on the URI suffix" {
    try testing.expectEqual(Lang.gr, langOf("file:///x/main.gr").?);
    try testing.expectEqual(Lang.gas, langOf("file:///x/boot.gas").?);
    // Anything else is left alone rather than guessed at.
    try testing.expect(langOf("file:///x/README.md") == null);
}

test "diagnose: a gero-lang type error carries a range and its code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const diags = try diagnoseText(arena.allocator(), .gr, "def main()\n  print undefined_thing()\nend\n");
    try testing.expectEqual(@as(usize, 1), diags.len);
    // Zero-based, so source line 2 is LSP line 1.
    try testing.expectEqual(@as(u32, 1), diags[0].line);
    try testing.expectEqual(@as(u8, 1), diags[0].severity);
    try testing.expectEqualStrings("E_UNDEFINED_SYMBOL", diags[0].code);
    try testing.expect(diags[0].end_character > diags[0].character);
}

test "diagnose: a clean buffer reports nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const diags = try diagnoseText(arena.allocator(), .gr, "def main()\n  print 1\nend\n");
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "diagnose: a gero-lang syntax error carries its E_SYNTAX code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const diags = try diagnoseText(arena.allocator(), .gr, "def main(\n");
    try testing.expect(diags.len > 0);
    for (diags) |d| try testing.expect(std.mem.startsWith(u8, d.code, "E_SYNTAX"));
}

test "diagnose: a lexer error is reported once, not once per phase" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const diags = try diagnoseText(arena.allocator(), .gr, "let x = 0x1\n");
    var hex: usize = 0;
    for (diags) |d| {
        if (std.mem.eql(u8, d.code, "E_SYNTAX_HEX_PREFIX")) hex += 1;
    }
    try testing.expectEqual(@as(usize, 1), hex);
}

test "diagnose: an asm error is positioned too" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const diags = try diagnoseText(arena.allocator(), .gas, "main:\n  mov $01, rZ\n  hlt\n");
    try testing.expect(diags.len > 0);
    try testing.expectEqual(@as(u32, 1), diags[0].line);
}

test "diagnose: asm reports resolution errors alongside parse errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // An unknown mnemonic parses cleanly and only fails at opcode
    // resolution, so stopping at the parse would hide it — the same
    // union `gero check` reports.
    const diags = try diagnoseText(arena.allocator(), .gas, "start:\n  mov r0, 1\n  bogus r1\n  hlt\n");
    var saw_parse = false;
    var saw_resolve = false;
    for (diags) |d| {
        if (std.mem.eql(u8, d.code, "E001")) saw_resolve = true;
        if (d.code.len == 0) saw_parse = true;
    }
    try testing.expect(saw_parse);
    try testing.expect(saw_resolve);
}

test "diagnose: codegen-only errors surface, as they do under check" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // A frame-too-large body type-checks clean; only codegen rejects
    // it. An editor that stopped at the type-check would show nothing.
    const src =
        \\def hog() -> i16
        \\  let a: [i16; 40] = [0; 40]
        \\  let b: [i16; 40] = [0; 40]
        \\  return a[0] + b[0]
        \\end
        \\
    ;
    const diags = try diagnoseText(arena.allocator(), .gr, src);
    var found = false;
    for (diags) |d| {
        if (std.mem.eql(u8, d.code, "E_CODEGEN_FRAME_TOO_LARGE")) found = true;
    }
    try testing.expect(found);
}

test "diagnose: an unsaved import is read from the overlay, not from disk" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lib.gr", .data = "def double(n: i16) -> i16\n  return n * 2\nend\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "main.gr", .data = "use \"./lib\"\ndef main()\n  print double(21)\nend\n" });

    const lib_path = try tmp.dir.realPathFileAlloc(testing.io, "lib.gr", arena);
    const main_path = try tmp.dir.realPathFileAlloc(testing.io, "main.gr", arena);
    const main_uri = try uri_mod.fromPath(arena, main_path);
    const main_src = "use \"./lib\"\ndef main()\n  print double(21)\nend\n";

    // Against the saved tree, `main.gr` is clean.
    const clean = try diagnose(testing.io, arena, .gr, main_uri, main_src, null);
    try testing.expectEqual(@as(usize, 0), clean.files[0].items.len);
    // The graph it read is what lets a server know this document has
    // to be re-checked when `lib.gr` changes.
    try testing.expectEqual(@as(usize, 2), clean.graph_files.len);

    // The editor renames `double` in `lib.gr` without saving; the
    // importer must go red against the buffer, not against the file.
    var ov: gero.lang.Overlay = .{};
    try ov.put(arena, lib_path, "def renamed(n: i16) -> i16\n  return n * 2\nend\n");
    const dirty = try diagnose(testing.io, arena, .gr, main_uri, main_src, &ov);
    try testing.expectEqual(@as(usize, 1), dirty.files[0].items.len);
    try testing.expectEqualStrings("E_UNDEFINED_SYMBOL", dirty.files[0].items[0].code);
}

test "diagnose: an error inside an import is published against that file" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lib.gr", .data = "def broken() -> i16\n  return nope\nend\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "main.gr", .data = "use \"./lib\"\ndef main()\n  print broken()\nend\n" });

    const main_path = try tmp.dir.realPathFileAlloc(testing.io, "main.gr", arena);
    const main_uri = try uri_mod.fromPath(arena, main_path);
    const result = try diagnose(testing.io, arena, .gr, main_uri, "use \"./lib\"\ndef main()\n  print broken()\nend\n", null);
    const files = result.files;

    // The importer itself is clean; the error belongs to `lib.gr` and
    // is positioned in `lib.gr`'s own coordinates.
    try testing.expectEqual(@as(usize, 2), files.len);
    try testing.expectEqualStrings(main_uri, files[0].uri);
    try testing.expectEqual(@as(usize, 0), files[0].items.len);
    try testing.expect(std.mem.endsWith(u8, files[1].uri, "lib.gr"));
    try testing.expectEqual(@as(u32, 1), files[1].items[0].line);
}

test "diagnose: a missing `use` target is reported on the importer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const src = "use \"./nope\"\ndef main()\n  print 1\nend\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "main.gr", .data = src });
    const main_path = try tmp.dir.realPathFileAlloc(testing.io, "main.gr", arena);
    const main_uri = try uri_mod.fromPath(arena, main_path);

    const result = try diagnose(testing.io, arena, .gr, main_uri, src, null);
    try testing.expectEqualStrings("E_USE_NOT_FOUND", result.files[0].items[0].code);
}

test "format: canonicalizes a gero-lang buffer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = (try format(arena.allocator(), .gr, "def  main()\n   print   1\nend\n")).?;
    try testing.expectEqualStrings("def main()\n  print 1\nend\n", out);
}

test "format: canonicalizes an asm buffer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = (try format(arena.allocator(), .gas, "main:\n   mov   $01,r1\n  hlt\n")).?;
    try testing.expect(std.mem.indexOf(u8, out, "mov $01, r1") != null);
}

test "format: a buffer that does not parse is left alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Format-on-save must not rewrite a broken buffer from a partial
    // tree — the edit would be destructive and unasked for.
    try testing.expect(try format(arena.allocator(), .gr, "def main(\n") == null);
    try testing.expect(try format(arena.allocator(), .gas, "mov &x, r1\n") == null);
}

test "format: already-canonical text is unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const canonical = "def main()\n  print 1\nend\n";
    const out = (try format(arena.allocator(), .gr, canonical)).?;
    try testing.expectEqualStrings(canonical, out);
}
