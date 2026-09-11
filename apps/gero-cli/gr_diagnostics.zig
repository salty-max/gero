//! The Gero diagnostic pipeline for one source buffer, shared by
//! `gero check` and `gero lsp`. Keeping it in one place is what makes
//! "the editor and the CLI agree about a buffer" a property of the
//! code rather than a promise: both commands call this function, so
//! neither can gain a phase the other lacks. Rendering those
//! diagnostics for a terminal lives in `diagnostics.zig`.

const std = @import("std");
const gero = @import("gero");

/// Tokenize + parse + typecheck a Gero source into one flat
/// diagnostic slice. Pure over `src` (no IO), so every caller that
/// already holds the text can use it. Each diagnostic's `code` is the
/// lexer/parser's stable `E_SYNTAX_*` code (see
/// `docs/lang-diagnostics.md`), or `E_SYNTAX_GENERIC` when the
/// emission site carries none.
pub fn forGr(
    arena: std.mem.Allocator,
    src: []const u8,
    validate_codegen: bool,
    import_aliases: ?*const gero.lang.ImportAliases,
    graph: ?gero.lang.ModuleGraph,
) ![]gero.lang.Diagnostic {
    const stream = try gero.lang.tokenize(arena, src);
    var combined: std.ArrayList(gero.lang.Diagnostic) = .empty;

    // `parse` folds the lexer's `stream.errors` into `tree.errors`
    // (src/lang/parser.zig), so `tree.errors` is the complete set —
    // iterate it alone, never `stream.errors` as well.
    const tree = try gero.lang.parse(arena, src, stream);
    for (tree.errors) |e| {
        try combined.append(arena, .{
            .severity = .fatal,
            .code = e.expected orelse "E_SYNTAX_GENERIC",
            // safety: ParseError.index fits in u32 — bounded by file size.
            .message = try arena.dupe(u8, e.message),
            .span = .{ .start = @intCast(e.index), .end = @intCast(e.index) },
        });
    }

    // Only typecheck when parsing succeeded — otherwise the AST
    // shape can't carry semantic information.
    if (tree.errors.len == 0) {
        var checked = try gero.lang.typecheckGraph(arena, src, &tree.program, import_aliases, graph);
        for (checked.diagnostics) |d| try combined.append(arena, d);

        // Codegen-validate so codegen-only errors surface at check time.
        // `require_entry = false` lowers a library file's bodies even
        // without a `main` (it's validation, not a runnable image). Only
        // when the type-check is clean — codegen consumes the typed AST.
        if (validate_codegen and !checked.hasErrors()) {
            var compiled = gero.lang.compile(arena, src, &checked, .{ .require_entry = false, .import_aliases = import_aliases, .graph = graph }) catch |err| switch (err) {
                error.OutOfMemory => return err,
                // EntryNotFound can't fire (require_entry=false); any other
                // codegen host failure leaves the type-check result standing.
                else => null,
            };
            if (compiled) |*c| {
                defer c.deinit();
                for (c.diagnostics) |d| try combined.append(arena, .{
                    .severity = d.severity,
                    .code = d.code,
                    .message = try arena.dupe(u8, d.message),
                    .span = d.span,
                });
            }
        }
    }

    return combined.toOwnedSlice(arena);
}

/// Result of validating one `.gr` source (with its `use` imports).
pub const GrCheckResult = struct {
    source: []const u8,
    diagnostics: []gero.lang.Diagnostic,
    /// Fused → original-file map for diagnostic attribution. Empty for a
    /// read error (no file was fused).
    source_map: gero.lang.SourceMap,
    read_error: bool = false,
};

/// Read + tokenize + parse + typecheck the `.gr` file at `path`,
/// together with everything its `use` graph reaches. Parser
/// diagnostics are folded into the returned slice as lang
/// `Diagnostic`s with `E_SYNTAX_GENERIC` codes.
///
/// Files listed in `overlay` are read from memory rather than disk, so
/// a language server diagnoses the buffers an editor is showing while
/// `gero check` — passing `null` — diagnoses the saved tree.
pub fn forGrFile(
    io: std.Io,
    arena: std.mem.Allocator,
    path: []const u8,
    overlay: ?*const gero.lang.Overlay,
) !GrCheckResult {
    // Resolve `use` imports so the validated program is whole — a `use`
    // failure (missing / cyclic file) is itself a check diagnostic.
    var fused = gero.lang.resolveUseImportsOverlaid(io, arena, path, overlay) catch {
        return .{ .source = "", .diagnostics = &.{}, .source_map = .{ .files = .empty, .regions = .empty, .allocator = arena }, .read_error = true };
    };
    if (fused.hasErrors()) {
        return .{ .source = fused.source, .diagnostics = try includeErrorDiagnostics(arena, fused), .source_map = fused.source_map };
    }
    return .{ .source = fused.source, .diagnostics = try forGr(arena, fused.source, true, &fused.import_aliases, .{ .source_map = &fused.source_map, .imports = fused.imports }), .source_map = fused.source_map };
}

fn includeErrorDiagnostics(arena: std.mem.Allocator, fused: gero.lang.FusedSource) ![]gero.lang.Diagnostic {
    var out: std.ArrayList(gero.lang.Diagnostic) = .empty;
    for (fused.errors) |e| {
        const code = gero.lang.includeErrorCode(e.kind);
        const msg = try gero.lang.includeErrorMessage(arena, e.kind, e.requested);
        try out.append(arena, .{ .severity = .fatal, .code = code, .message = msg, .span = .{ .start = e.site_offset, .end = e.site_offset } });
    }
    return out.toOwnedSlice(arena);
}

// ---------- tests ----------

test "forGr: clean source yields no diagnostics" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const diags = try forGr(arena_state.allocator(), "def add(x: i16, y: i16) -> i16\n  return x + y\nend\n", false, null, null);
    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "forGr: lexer diagnostic is not double-counted" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // A lexer diagnostic (the `0x`-prefix error) surfaces exactly
    // once, not once per phase — `tree.errors` already includes it.
    const diags = try forGr(arena_state.allocator(), "let x = 0x1\n", false, null, null);
    var hex_count: usize = 0;
    for (diags) |d| {
        if (std.mem.eql(u8, d.code, "E_SYNTAX_HEX_PREFIX")) hex_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), hex_count);
}

test "forGr: type error surfaces when parse succeeds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const diags = try forGr(arena_state.allocator(), "def f()\n  return undefined_name\nend\n", false, null, null);
    try std.testing.expect(diags.len > 0);
}

test "forGr: codegen-validates a body even without a `main`" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // A frame-too-large body type-checks clean but is a codegen-only
    // error; with no `main` in the file, surfacing it proves codegen runs
    // in validation mode.
    const src =
        \\def hog() -> i16
        \\  let a: [i16; 40] = [0; 40]
        \\  let b: [i16; 40] = [0; 40]
        \\  return a[0] + b[0]
        \\end
        \\
    ;
    const diags = try forGr(arena_state.allocator(), src, true, null, null);
    var found = false;
    for (diags) |d| {
        if (std.mem.eql(u8, d.code, "E_CODEGEN_FRAME_TOO_LARGE")) found = true;
    }
    try std.testing.expect(found);
}
