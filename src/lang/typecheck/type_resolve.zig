const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const typecheck = @import("../typecheck.zig");

const Checker = typecheck.Checker;
const WalkError = error{OutOfMemory};

/// Resolve `t` against the active scope chain. Unknown named
/// types emit `E_TYPE_UNDEFINED` (with a "did you mean…?"
/// suggestion when a near-spelling candidate exists) and fall
/// back to a placeholder `Named` so subsequent typecheck steps
/// can keep walking without further errors at that site.
pub fn resolveType(self: *Checker, t: *const ast.TypeAnn) WalkError!*const types.Type {
    switch (t.*) {
        .named => |n| {
            const name = self.lexeme(n.name);
            if (types.primitiveFromName(name)) |p| {
                return try self.primitive(p);
            }
            if (self.current_scope.lookup(name)) |_| {
                return try types.mkNamed(self.arena, name, n.span);
            }
            const msg = try std.fmt.allocPrint(
                self.arena,
                "undefined type `{s}`",
                .{name},
            );
            try self.emitSpanWithSuggestion("E_TYPE_UNDEFINED", n.name, msg, try self.suggestTypeName(name));
            return try types.mkNamed(self.arena, name, n.span);
        },
        .nullable => |n| {
            const inner = try resolveType(self, n.inner);
            if (!isOptionalInner(self, inner.*)) {
                const inner_s = try types.render(self.arena, inner.*);
                const msg = try std.fmt.allocPrint(
                    self.arena,
                    "type `{s}?` is invalid — `T?` applies to pointer-like types (`str`, class, fn-pointer, references) or scalars (`i8` / `u8` / `i16` / `u16` / `char` / `bool` / `fixed`)",
                    .{inner_s},
                );
                try self.emitSpan("E_NULL_NON_POINTER", n.span, msg);
            }
            return try types.mkOptional(self.arena, inner);
        },
        .array => |a| {
            const elem = try resolveType(self, a.elem);
            const len_val: u32 = if (a.len_expr.* == .int_lit)
                // safety: parser stores array lengths as i32; §3.4 requires non-negative comptime int. Slice 3+ will range-check; bit-cast preserves bytes.
                @bitCast(a.len_expr.int_lit.value)
            else
                0;
            return try types.mkArray(self.arena, elem, len_val);
        },
        .vec => |v| {
            const elem = try resolveType(self, v.elem);
            return try types.mkVec(self.arena, elem);
        },
        .tuple => |tu| {
            if (tu.elems.len > 4) {
                const msg = try std.fmt.allocPrint(self.arena, "a tuple has at most 4 elements (§3.4) — found {d}; use a struct for more", .{tu.elems.len});
                try self.emitSpan("E_TYPE_TUPLE_TOO_MANY", tu.span, msg);
            }
            var elems: std.ArrayList(*const types.Type) = .empty;
            errdefer elems.deinit(self.arena);
            for (tu.elems) |e| try elems.append(self.arena, try resolveType(self, e));
            const out = try self.arena.create(types.Type);
            out.* = .{ .tuple = try elems.toOwnedSlice(self.arena) };
            return out;
        },
        .fn_type => |f| {
            var params: std.ArrayList(*const types.Type) = .empty;
            errdefer params.deinit(self.arena);
            for (f.params) |p| try params.append(self.arena, try resolveType(self, p));
            const ret: *const types.Type = if (f.ret) |r|
                try resolveType(self, r)
            else
                try self.primitive(.nil_);
            const out = try self.arena.create(types.Type);
            out.* = .{ .function = .{
                .params = try params.toOwnedSlice(self.arena),
                .ret = ret,
            } };
            return out;
        },
        .reference => |r| {
            const inner = try resolveType(self, r.inner);
            return try types.mkReference(self.arena, inner);
        },
    }
}

/// Pointer-like types per §3.4.1 — `str`, references, function
/// pointers, and class names. Struct / enum / numeric / bool /
/// fixed are by-value and therefore not nullable-eligible.
/// Whether `t` is a valid `T?` inner type — pointer-like (a single-word
/// nullable pointer, `nil` = 0) or a scalar (a tagged `{present, value}`
/// optional). Aggregates (array / tuple / `Vec` / struct) are rejected.
pub fn isOptionalInner(self: *const Checker, t: types.Type) bool {
    if (isPointerLike(self, t)) return true;
    return t == .primitive and switch (t.primitive) {
        .i8, .u8, .i16, .u16, .char, .bool_, .fixed => true,
        .str, .nil_ => false, // `str` is pointer-like (handled above)
    };
}

/// Whether `t` is a pointer-like type (`str`, class, fn-pointer, reference)
/// — represented as a single nullable-pointer word (`nil` = 0).
pub fn isPointerLike(self: *const Checker, t: types.Type) bool {
    return switch (t) {
        .primitive => |p| p == .str,
        .reference, .function => true,
        .named => |n| {
            if (self.current_scope.lookup(n.name)) |info| {
                return switch (info.kind) {
                    .class, .module_alias, .imported => true,
                    else => false,
                };
            }
            // Unresolved named type — accept defensively so the
            // diagnostic surfaces from the resolution step.
            return true;
        },
        else => false,
    };
}
