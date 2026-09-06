const std = @import("std");
const ast = @import("ast.zig");
const include = @import("include.zig");

/// Hash of a module's full text — what changes when anything in the
/// file changes, body included. A module whose content hash still
/// matches needs no work of its own.
pub fn contentHash(map: *const include.SourceMap, file_id: u16) u64 {
    if (file_id >= map.files.items.len) return 0;
    return std.hash.Wyhash.hash(0, map.files.items[file_id].content);
}

/// Hash of what a module exports — every non-`local` top-level
/// declaration, with function and method bodies excluded.
///
/// This is the key a dependent caches against. Excluding bodies is
/// what makes a body edit invisible across a module boundary: the
/// dependent's own work stays valid because nothing it could have
/// relied on changed.
pub fn interfaceHash(source: []const u8, statements: []const ast.Statement) u64 {
    var h = std.hash.Wyhash.init(0);
    for (statements) |stmt| {
        if (isLocal(stmt)) continue;
        switch (stmt) {
            .def_decl => |d| hashSignature(&h, source, d),
            .class_decl => |c| {
                // A class's own header stops at its first member, and
                // each method contributes its signature but not its body.
                const header_end = if (c.methods.len > 0)
                    c.methods[0].span.start
                else
                    c.span.end;
                h.update(slice(source, c.span.start, header_end));
                for (c.methods) |m| hashSignature(&h, source, m);
            },
            else => h.update(slice(source, stmt.span().start, stmt.span().end)),
        }
        // Separator, so two declarations can't hash the same as one
        // whose text happens to concatenate to theirs.
        h.update("\x00");
    }
    return h.final();
}

/// Modules that must be redone: those whose own content changed, plus
/// everything that transitively imports one of them. Returns a flag per
/// module, indexed by file id.
///
/// A module importing a changed one is included whatever changed in it,
/// because the import edge alone doesn't say whether the change touched
/// the interface — the caller compares interface hashes first and only
/// reports a module changed when its dependents could care.
pub fn dirtySet(
    allocator: std.mem.Allocator,
    module_count: usize,
    imports: []const include.ImportEdge,
    changed: []const bool,
) ![]bool {
    const dirty = try allocator.alloc(bool, module_count);
    for (dirty, 0..) |*d, i| d.* = i < changed.len and changed[i];

    // Import edges run importer → imported, so a dirty module marks its
    // importers. Repeat until nothing new is marked: an edge list in
    // arbitrary order needs more than one sweep to close transitively.
    var settled = false;
    while (!settled) {
        settled = true;
        for (imports) |edge| {
            if (edge.from >= module_count or edge.to >= module_count) continue;
            if (dirty[edge.to] and !dirty[edge.from]) {
                dirty[edge.from] = true;
                settled = false;
            }
        }
    }
    return dirty;
}

/// A def's text up to its body — annotations, name, parameters, and
/// return type, and nothing that only affects the code it compiles to.
fn hashSignature(h: *std.hash.Wyhash, source: []const u8, d: ast.DefDecl) void {
    const sig_end = if (d.body.len > 0) d.body[0].span().start else d.span.end;
    h.update(slice(source, d.span.start, sig_end));
}

fn isLocal(stmt: ast.Statement) bool {
    return switch (stmt) {
        .def_decl => |d| d.is_local,
        .const_decl => |d| d.is_local,
        .class_decl => |d| d.is_local,
        .enum_decl => |d| d.is_local,
        .struct_decl => |d| d.is_local,
        .let_decl => |d| d.is_local,
        else => false,
    };
}

fn slice(source: []const u8, start: u32, end: u32) []const u8 {
    if (start >= source.len or end > source.len or start >= end) return "";
    return source[start..end];
}
