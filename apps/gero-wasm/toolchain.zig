//! The operations behind the toolchain exports: resolve, build,
//! format, and report.
//!
//! Everything here is a function of the session's allocator and its
//! file set — no filesystem, and no state of its own. A name the set
//! does not hold is a diagnostic rather than a read, which is what
//! `docs/gero-lab.md` §4.2 means by resolution being closed.

const std = @import("std");
const gero = @import("gero");
const abi = @import("abi.zig");
const session = @import("session.zig");

const Result = abi.Result;
const Status = abi.Status;

/// Whether an operation wants the image, or only what is wrong.
pub const Want = enum { image, diagnostics_only };

/// Resolve, parse, type-check, and optionally lower a `.gr` entry.
///
/// Every phase reads from the virtual file set, never from a
/// filesystem — the resolver's `virtual` source makes a name the set
/// does not hold a not-found diagnostic rather than a read.
pub fn buildGr(name: []const u8, want: Want) *const Result {
    const arena = session.allocator();

    var fused = gero.lang.resolveUseImportsVirtual(arena, name, &session.fileSet().map) catch
        return session.fail(.out_of_memory);
    if (fused.hasErrors()) return includeDiagnostics(arena, fused);

    const stream = gero.lang.tokenize(arena, fused.source) catch return session.fail(.out_of_memory);
    var tree = gero.lang.parseAllModules(arena, fused.source, stream, &fused.source_map) catch
        return session.fail(.out_of_memory);
    if (tree.errors.len > 0) return langDiagnostics(arena, fused, tree.errors);

    var checked = gero.lang.typecheckGraph(arena, fused.source, &tree.program, &fused.import_aliases, .{
        .source_map = &fused.source_map,
        .imports = fused.imports,
    }) catch return session.fail(.out_of_memory);
    checked.program = &tree.program;
    if (checked.hasErrors() or want == .diagnostics_only) {
        return reportLang(arena, fused, checked.diagnostics);
    }

    const compiled = gero.lang.compile(arena, fused.source, &checked, .{
        .import_aliases = &fused.import_aliases,
        .graph = .{ .source_map = &fused.source_map, .imports = fused.imports },
    }) catch return session.fail(.out_of_memory);
    if (compiled.hasErrors()) return reportLang(arena, fused, compiled.diagnostics);
    return session.finish(compiled.image, null, 0);
}

/// Resolve, parse, and optionally assemble a `.gas` entry.
pub fn buildGas(name: []const u8, want: Want) *const Result {
    const arena = session.allocator();

    const fused = gero.asm_.resolveIncludesVirtual(arena, name, &session.fileSet().map) catch
        return session.fail(.out_of_memory);
    if (fused.errors.len > 0) return reportAsm(arena, fused.source_map, fused.errors);

    const pt = gero.asm_.parse(arena, fused.source) catch return session.fail(.out_of_memory);
    // Both passes run and both error sets are reported: an unknown
    // mnemonic parses cleanly and only fails at opcode resolution, so
    // stopping at the parse would hide it.
    const cg = gero.asm_.assemble(arena, fused.source, pt, .{ .source_map = &fused.source_map }) catch
        return session.fail(.out_of_memory);

    if (pt.errors.len > 0 or cg.errors.len > 0) {
        var all: std.ArrayList(gero.asm_.Diagnostic) = .empty;
        all.appendSlice(arena, pt.errors) catch return session.fail(.out_of_memory);
        all.appendSlice(arena, cg.errors) catch return session.fail(.out_of_memory);
        return reportAsm(arena, fused.source_map, all.items);
    }
    if (want == .diagnostics_only) return session.finish(null, null, 0);
    return session.finish(cg.image, null, 0);
}

pub fn formatGr(arena: std.mem.Allocator, src: []const u8) !?[]const u8 {
    const stream = gero.lang.tokenize(arena, src) catch return null;
    var tree = gero.lang.parse(arena, src, stream) catch return null;
    if (tree.errors.len > 0) return null;
    var out = std.Io.Writer.Allocating.init(arena);
    gero.lang.print(&out.writer, &tree.program, src, tree.comments) catch return null;
    return out.written();
}

pub fn formatGas(arena: std.mem.Allocator, src: []const u8) !?[]const u8 {
    const pt = gero.asm_.parse(arena, src) catch return null;
    if (pt.errors.len > 0) return null;
    var out = std.Io.Writer.Allocating.init(arena);
    gero.asm_.printProgram(&out.writer, &pt.program, src, gero.asm_.default_print_options) catch return null;
    return out.written();
}

// ---------- reporting ----------

/// Report lang diagnostics, attributed to the files they came from.
fn reportLang(
    arena: std.mem.Allocator,
    fused: gero.lang.FusedSource,
    diagnostics: []const gero.lang.Diagnostic,
) *const Result {
    if (diagnostics.len == 0) return session.finish(null, null, 0);
    const json = encodeLangDiagnostics(arena, .{
        .path = entryPath(fused),
        .source = fused.source,
        .diagnostics = diagnostics,
    }) catch return session.fail(.out_of_memory);
    return session.finish(null, json, diagnostics.len);
}

fn langDiagnostics(
    arena: std.mem.Allocator,
    fused: gero.lang.FusedSource,
    errors: anytype,
) *const Result {
    var out: std.ArrayList(gero.lang.Diagnostic) = .empty;
    for (errors) |e| {
        out.append(arena, .{
            .severity = .fatal,
            .code = e.expected orelse "E_SYNTAX_GENERIC",
            .message = e.message,
            // safety: a fused-buffer index, bounded well under 4 GiB.
            .span = .{ .start = @intCast(e.index), .end = @intCast(e.index) },
        }) catch return session.fail(.out_of_memory);
    }
    return reportLang(arena, fused, out.items);
}

/// Report `use`-resolution failures — a missing or cyclic target.
fn includeDiagnostics(arena: std.mem.Allocator, fused: gero.lang.FusedSource) *const Result {
    var out: std.ArrayList(gero.lang.Diagnostic) = .empty;
    for (fused.errors) |e| {
        out.append(arena, .{
            .severity = .fatal,
            .code = switch (e.kind) {
                .cycle => "E_USE_CYCLE",
                .depth_exceeded => "E_USE_DEPTH",
                .not_found => "E_USE_NOT_FOUND",
                .duplicate_alias => "E_USE_DUPLICATE_ALIAS",
            },
            .message = switch (e.kind) {
                .cycle => "`use` cycle detected",
                .depth_exceeded => "`use` depth exceeds 32 — likely runaway recursion",
                .not_found => "`use` target is not in the file set",
                .duplicate_alias => "import alias is bound to two different targets",
            },
            .span = .{ .start = e.site_offset, .end = e.site_offset },
        }) catch return session.fail(.out_of_memory);
    }
    return reportLang(arena, fused, out.items);
}

fn reportAsm(
    arena: std.mem.Allocator,
    source_map: gero.asm_.SourceMap,
    diagnostics: []const gero.asm_.Diagnostic,
) *const Result {
    if (diagnostics.len == 0) return session.finish(null, null, 0);
    const json = encodeAsmDiagnostics(arena, source_map, diagnostics) catch
        return session.fail(.out_of_memory);
    return session.finish(null, json, diagnostics.len);
}

/// Name of the file resolution started from, for diagnostics that
/// carry no file of their own.
fn entryPath(fused: gero.lang.FusedSource) []const u8 {
    if (fused.entry_module < fused.source_map.files.items.len) {
        return fused.source_map.files.items[fused.entry_module].path;
    }
    return "";
}

/// Disassemble a `.gx` into annotated assembly: an address gutter, an
/// entry marker, and symbol names in place of raw addresses.
///
/// `bank` selects a bank window, or `abi.no_bank` for the base image.
/// The annotations are what make the text addressable — a debugger
/// maps a click to a breakpoint through the gutter, and a plain
/// instruction listing gives it nothing to map.
///
/// `show_bytes` adds the hex column beside each instruction. It has to
/// come from here: the gutter carries CPU addresses, so a host holding
/// the `.gx` cannot slice an instruction's bytes out of it without
/// knowing where the image section starts.
pub fn disassemble(image: []const u8, bank: u32, show_bytes: bool) *const Result {
    const arena = session.allocator();
    const header = gero.disasm.parseHeader(image) catch return session.fail(.bad_argument);

    const base_image = bank == abi.no_bank;
    const region = if (base_image) header.image else blk: {
        if (bank >= header.bank_count) return session.fail(.bad_argument);
        const window = gero.gx.bank_disk_size;
        // @as: widen the host's bank index for the offset math.
        const start = @as(usize, bank) * window;
        break :blk header.banks[start .. start + window];
    };

    // A malformed debug section costs the symbol column, not the
    // disassembly — a release image carries none either, and both
    // still render.
    const symbols = gero.disasm.parseSymbols(arena, header.debug) catch null;

    var out = std.Io.Writer.Allocating.init(arena);
    gero.disasm.writeBytesPretty(arena, &out.writer, region, .{
        .base_addr = if (base_image) 0x0000 else abi.bank_window_base,
        .show_bytes = show_bytes,
        .entry_addr = if (base_image) header.entry_point else null,
        .symbols = symbols,
    }) catch return session.fail(.out_of_memory);
    return session.finish(out.written(), null, 0);
}

/// Encode gero-lang diagnostics as the JSON array a host renders in
/// its gutter.
///
/// The objects come from `gero.diagnostics_json`, the same writer
/// `gero check --format=json` uses — so an error's wording, code, and
/// span are identical in a terminal and in a browser. That is a
/// deliberate single source of truth (§5), not a coincidence to be
/// re-verified.
pub fn encodeLangDiagnostics(
    arena: std.mem.Allocator,
    file: gero.lang.render.FileDiagnostics,
) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try jw.beginArray();
    for (file.diagnostics) |d| try gero.diagnostics_json.writeLang(&jw, file, d);
    try jw.endArray();
    return out.written();
}

/// Encode asm diagnostics as the same JSON array.
pub fn encodeAsmDiagnostics(
    arena: std.mem.Allocator,
    source_map: gero.asm_.SourceMap,
    diagnostics: []const gero.asm_.Diagnostic,
) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try jw.beginArray();
    for (diagnostics) |d| try gero.diagnostics_json.writeAsm(&jw, source_map, d);
    try jw.endArray();
    return out.written();
}
pub fn writeDebugJson(
    arena: std.mem.Allocator,
    jw: *std.json.Stringify,
    debug: []const u8,
) !void {
    try jw.beginObject();

    try jw.objectField("symbols");
    try jw.beginArray();
    if (debug.len > 0) {
        const syms = gero.disasm.parseSymbols(arena, debug) catch gero.disasm.Symbols{ .entries = &.{} };
        for (syms.entries) |sym| {
            try jw.beginObject();
            try jw.objectField("address");
            try jw.write(sym.address);
            try jw.objectField("kind");
            try jw.write(switch (sym.kind) {
                .label => "label",
                .data => "data",
                else => "unknown",
            });
            try jw.objectField("name");
            try jw.write(sym.name);
            try jw.endObject();
        }
    }
    try jw.endArray();

    try jw.objectField("files");
    try jw.beginArray();
    const files_chunk = if (debug.len > 0) (gero.gx.findChunk(debug, .files) catch null) else null;
    const paths: []const []const u8 = if (files_chunk) |p|
        gero.gx.decodeFiles(arena, p) catch &.{}
    else
        &.{};
    for (paths) |path| try jw.write(path);
    try jw.endArray();

    try jw.objectField("lines");
    try jw.beginArray();
    const lines_chunk = if (debug.len > 0) (gero.gx.findChunk(debug, .lines) catch null) else null;
    if (lines_chunk) |p| {
        const rows = gero.gx.decodeLines(arena, p) catch &.{};
        for (rows) |row| {
            try jw.beginObject();
            try jw.objectField("start");
            try jw.write(row.start_addr);
            try jw.objectField("end");
            try jw.write(row.end_addr);
            try jw.objectField("file");
            try jw.write(row.file);
            try jw.objectField("line");
            try jw.write(row.line);
            try jw.objectField("column");
            try jw.write(row.column);
            try jw.endObject();
        }
    }
    try jw.endArray();

    try jw.endObject();
}

// ---------- tests ----------

const testing = std.testing;

test "encodeLangDiagnostics: emits the shape a host decodes" {
    session.init(0);
    const arena = session.allocator();
    const src = "def main()\n  print undefined_thing()\nend\n";

    const stream = try gero.lang.tokenize(arena, src);
    var tree = try gero.lang.parse(arena, src, stream);
    const checked = try gero.lang.typecheck(arena, src, &tree.program);
    try testing.expect(checked.diagnostics.len > 0);

    const json = try encodeLangDiagnostics(arena, .{
        .path = "main.gr",
        .source = src,
        .diagnostics = checked.diagnostics,
    });

    // Runs the real pipeline through the module's own arena, which is
    // what proves the allocator is usable by the library rather than
    // only by these tests.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const first = parsed.value.array.items[0].object;
    try testing.expectEqualStrings("E_UNDEFINED_SYMBOL", first.get("code").?.string);
    try testing.expectEqualStrings("main.gr", first.get("file").?.string);
}

test "buildGr: a use target outside the set is a diagnostic, not a read" {
    session.init(0);
    // Resolution is closed (§4.2): the set is the whole filesystem, so
    // a name it does not hold cannot fall through to a disk or a fetch.
    try session.putFile("main.gr", "use \"./nope\"\ndef main()\n  print 1\nend\n");
    const r = buildGr("main.gr", .image);
    try testing.expectEqual(@intFromEnum(Status.diagnostics), r.status);
    try testing.expect(std.mem.indexOf(u8, session.diagnosticsOf(r), "E_USE_NOT_FOUND") != null);
}

test "buildGr: a multi-file program compiles from the set alone" {
    session.init(0);
    try session.putFile("lib.gr", "def double(n: i16) -> i16\n  return n * 2\nend\n");
    try session.putFile("main.gr", "use \"./lib\"\ndef main()\n  print double(21)\nend\n");
    const r = buildGr("main.gr", .image);
    try testing.expectEqual(@intFromEnum(Status.ok), r.status);
    try testing.expectEqualStrings("GERO", session.payloadOf(r)[0..4]);
}

test "buildGas: an include target resolves from the set" {
    session.init(0);
    try session.putFile("helper.gas", "double:\n  add r1, r1\n  ret\n");
    try session.putFile("m.gas", "include \"helper.gas\"\nmain:\n  call @double\n  hlt\n");
    const r = buildGas("m.gas", .image);
    try testing.expectEqual(@intFromEnum(Status.ok), r.status);
    try testing.expectEqualStrings("GERO", session.payloadOf(r)[0..4]);
}

test "buildGas: parse and resolution errors are reported together" {
    session.init(0);
    // An unknown mnemonic parses cleanly and only fails at opcode
    // resolution, so reporting just the parse would hide it.
    try session.putFile("m.gas", "start:\n  mov r0, 1\n  bogus r1\n  hlt\n");
    const r = buildGas("m.gas", .diagnostics_only);
    try testing.expectEqual(@intFromEnum(Status.diagnostics), r.status);
    try testing.expect(std.mem.indexOf(u8, session.diagnosticsOf(r), "E001") != null);
}

test "check: a clean program reports nothing and returns no image" {
    session.init(0);
    try session.putFile("main.gr", "def main()\n  print 1\nend\n");
    const r = buildGr("main.gr", .diagnostics_only);
    try testing.expectEqual(@intFromEnum(Status.ok), r.status);
    try testing.expectEqual(@as(u32, 0), r.payload_len);
}

test "disassemble: the base image renders with an address gutter, symbols and the entry marker" {
    session.init(0);
    try session.putFile("main.gas", "start:\n  mov $0041, r1\n  int $10\n  jmp start\n");
    const built = buildGas("main.gas", .image);
    try testing.expectEqual(@intFromEnum(Status.ok), built.status);

    // The image has to survive `session.begin()`'s scratch reset, the
    // same way a host's does — it holds the bytes, not the module.
    const image = try testing.allocator.dupe(u8, session.payloadOf(built));
    defer testing.allocator.free(image);

    session.init(0);
    const r = disassemble(image, abi.no_bank, false);
    try testing.expectEqual(@intFromEnum(Status.ok), r.status);
    const text = session.payloadOf(r);

    // The gutter is what makes a line addressable: a debugger maps a
    // click to a breakpoint through it. The first instruction sits at
    // the image's own base, which is also where the entry marker goes.
    try testing.expect(std.mem.startsWith(u8, text, "0000:"));
    try testing.expect(std.mem.indexOf(u8, text, "; entry point") != null);
    // A branch renders as its label rather than as `&XXXX`, which is
    // the whole point of feeding the symbol table in.
    try testing.expect(std.mem.indexOf(u8, text, "jmp   start") != null);
}

test "disassemble: bank 0 is a window, not a request for the base image" {
    session.init(0);
    try session.putFile("main.gas", "start:\n  hlt\n");
    const built = buildGas("main.gas", .image);
    const image = try testing.allocator.dupe(u8, session.payloadOf(built));
    defer testing.allocator.free(image);

    session.init(0);
    // A cart with no banks has no window 0, so `no_bank` is the only
    // way to ask for the base image.
    try testing.expectEqual(
        @intFromEnum(Status.bad_argument),
        disassemble(image, 0, false).status,
    );
}

test "disassemble: the byte column is what a host cannot reconstruct itself" {
    session.init(0);
    try session.putFile("main.gas", "start:\n  mov $0041, r1\n  hlt\n");
    const built = buildGas("main.gas", .image);
    const image = try testing.allocator.dupe(u8, session.payloadOf(built));
    defer testing.allocator.free(image);

    session.init(0);
    const plain = try testing.allocator.dupe(u8, session.payloadOf(disassemble(image, abi.no_bank, false)));
    defer testing.allocator.free(plain);

    session.init(0);
    const with_bytes = session.payloadOf(disassemble(image, abi.no_bank, true));

    // The gutter carries CPU addresses, not offsets into the `.gx`, so
    // a host holding the file cannot slice an instruction's bytes out
    // of it — the column has to come from here.
    try testing.expect(with_bytes.len > plain.len);
    try testing.expect(std.mem.indexOf(u8, with_bytes, "10 41 00 02") != null);
    try testing.expect(std.mem.indexOf(u8, plain, "10 41 00 02") == null);
}
