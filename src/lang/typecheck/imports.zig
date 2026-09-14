// Reports imports nothing in the module referenced. Runs after the
// whole program is walked, because an import is only unused once every
// body that could have used it has been checked.

const std = @import("std");
const ast = @import("../ast.zig");
const typecheck = @import("../typecheck.zig");

const Checker = typecheck.Checker;
const WalkError = error{OutOfMemory};

/// Emit `W_UNUSED_IMPORT` for every `use` the module never referenced.
///
/// An import is used when some reference binds to it, which the
/// checker already recorded: `bindings` maps a reference's offset to
/// the declaration it resolved to, so an import nothing points at is
/// one nothing named.
///
/// A selective import is judged per item — `use abs, min from math`
/// where only `abs` is called reports `min` alone.
pub fn reportUnused(self: *Checker, program: *const ast.Program) WalkError!void {
    var referenced: std.AutoHashMapUnmanaged(u32, void) = .{};
    defer referenced.deinit(self.arena);
    var it = self.bindings.valueIterator();
    while (it.next()) |b| try referenced.put(self.arena, b.decl_span.start, {});

    try reportUnusedEdges(self, &referenced);

    for (program.statements) |stmt| {
        const d = switch (stmt) {
            .use_decl => |u| u,
            else => continue,
        };
        // A module whose bodies came from cache was never walked, so
        // its references were never recorded and every import would
        // look unused.
        if (self.skipsBodies(stmt)) continue;

        if (d.items.len == 0) {
            const name = if (d.alias) |a| self.lexeme(a) else self.lexeme(d.module);
            if (referenced.contains(d.module.start)) continue;
            try warn(self, d.span, name);
            continue;
        }
        for (d.items) |item| {
            if (referenced.contains(item.name.start)) continue;
            const name = if (item.alias) |a| self.lexeme(a) else self.lexeme(item.name);
            try warn(self, item.span, name);
        }
    }
}

/// A quoted-path `use` is elided by the fuse layer, so its names ride
/// the import edge instead of reaching the checker as a declaration.
/// Only the selective form names anything — a whole-module import is
/// used the moment any of the target's exports is.
fn reportUnusedEdges(
    self: *Checker,
    referenced: *const std.AutoHashMapUnmanaged(u32, void),
) WalkError!void {
    const g = self.graph orelse return;
    for (g.imports) |edge| {
        if (edge.items.len == 0) continue;
        if (edge.to >= self.module_scopes.len) continue;
        if (g.skip_bodies.len > edge.from and g.skip_bodies[edge.from]) continue;
        for (edge.items) |item| {
            const info = self.module_scopes[edge.to].entries.get(item.name) orelse continue;
            if (referenced.contains(info.decl_span.start)) continue;
            const bound = item.alias orelse item.name;
            try warn(self, .{ .start = edge.site, .end = edge.site }, bound);
        }
    }
}

fn warn(self: *Checker, span: ast.Span, name: []const u8) WalkError!void {
    const msg = try std.fmt.allocPrint(self.arena, "unused import `{s}`", .{name});
    try self.diagnostics.append(self.diag_alloc, .{
        .severity = .warning,
        .code = "W_UNUSED_IMPORT",
        .message = msg,
        .span = span,
        .help = "remove it, or reference the name it brings into scope",
    });
}
