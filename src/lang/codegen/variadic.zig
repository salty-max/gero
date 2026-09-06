// Variadic `def` monomorphization (§4.6.2). A variadic def has no
// concrete arity at its declaration — each call site fixes one. The
// trailing `args` slot is a tuple of the supplied values; there is no
// runtime length field. So codegen emits one specialization per distinct
// call-site arity under a mangled `name$N` label, all sharing the body,
// and routes each call to the matching `N`. The `args` block is laid out
// word-strided (each vararg pushed as a full word by the caller), which
// both `args.N` indexing and `format(fmt, args)` forwarding read.

const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const types = @import("../types.zig");
const def_emit = @import("def.zig");
const class = @import("class.zig");
const isa = @import("isa.zig");
const opcodes = @import("opcodes.zig");

const Emitter = codegen.Emitter;
const Type = types.Type;
const Reg = opcodes.Reg;

/// The variadic specialization currently emitting. `args.N` loads and
/// `format(fmt, args)` forwarding read it to size + locate the args.
pub const Active = struct {
    /// Name of the trailing variadic parameter (its `args` slot).
    param: []const u8,
    /// Element type `T` — every vararg shares it (§4.6.2). `null` only
    /// for an arity-0 specialization, where no vararg pins a type.
    elem: ?*const Type,
    /// This specialization's vararg count.
    arity: u16,
};

/// Mangled label for the arity-`N` specialization of variadic `name`.
/// `$` can't appear in a source identifier, so it never collides with a
/// real def or method label.
pub fn label(self: *Emitter, name: []const u8, arity: u16) ![]const u8 {
    return std.fmt.allocPrint(self.arena, "{s}${d}", .{ name, arity });
}

/// Distinct arities every module's call sites asked of variadic `name`,
/// unioned and sorted. This is the link step's answer to which
/// specializations exist: each module records only what its own calls
/// need, so no module's set depends on its dependents'.
pub fn arities(self: *Emitter, name: []const u8) ![]const u32 {
    var out: std.ArrayListUnmanaged(u32) = .empty;
    var per_module = self.checked.moduleArities(name);
    while (per_module.next()) |set| {
        for (set) |a| {
            for (out.items) |seen| {
                if (seen == a) break;
            } else try out.append(self.arena, a);
        }
    }
    // Hash order isn't stable, so sort to keep emission deterministic.
    std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
    return out.items;
}

/// Emit every variadic def's per-arity specializations. Each `name$N`
/// runs the shared body with `current_variadic` set so its `args.N` /
/// forwarding lower against `N` word-strided slots. A variadic def with
/// no recorded call site (uninstantiable — no element type pinned) emits
/// nothing.
pub fn emitSpecializations(self: *Emitter, program: *const ast.Program) !void {
    for (program.statements) |*stmt| switch (stmt.*) {
        .def_decl => |*dd| {
            if (!isVariadicDef(dd.*)) continue;
            const name = self.source[dd.name.start..dd.name.end];
            const elem = self.checked.variadicElem(name);
            const last = dd.params[dd.params.len - 1];
            const param_name = self.source[last.name.start..last.name.end];
            for (try arities(self, name)) |arity| {
                // @as: a call-site arity fits the i8 frame budget well
                // under u16 (frame ≤ 127 bytes ⇒ ≤ 61 word slots).
                const n: u16 = @intCast(arity);
                // Arity ≥ 1 needs a pinned `T` to lower `args.N` /
                // forwarding; an unpinned def (only ever called with zero
                // varargs) still emits its empty specialization.
                if (n > 0 and elem == null) continue;
                const saved = self.current_variadic;
                self.current_variadic = .{ .param = param_name, .elem = elem, .arity = n };
                defer self.current_variadic = saved;
                try def_emit.emitDefWithLabel(self, dd, .regular, try label(self, name, n));
            }
        },
        else => {},
    };
}

/// `true` when `d`'s last parameter is the variadic `args` slot.
pub fn isVariadicDef(d: ast.DefDecl) bool {
    return d.params.len > 0 and d.params[d.params.len - 1].variadic;
}

/// `true` when `e` is the trailing `args` slot of the variadic body
/// currently emitting — i.e. a bare reference to the variadic parameter.
pub fn isArgsForward(self: *Emitter, e: *const ast.Expr) bool {
    const v = self.current_variadic orelse return false;
    if (e.* != .ident) return false;
    return std.mem.eql(u8, self.source[e.ident.span.start..e.ident.span.end], v.param);
}

/// Lower `args.N` — load the `N`-th vararg word. The block is
/// word-strided (the caller pushed each vararg as a full word, so a
/// sub-word `T` rides the low half already sign/zero-extended), so the
/// element is a plain word load at `N * 2` from the `args` base.
pub fn emitArgsIndex(self: *Emitter, receiver: *const ast.Expr, index: u8) !void {
    try self.emitAddrOf(receiver); // acu = args base (fp + slot offset)
    try isa.movRegToReg(self, Reg.acu, Reg.r1);
    // @as: index < arity and arity*2 is frame-bounded, so the offset fits u16.
    try class.emitWordLoadAtOffset(self, Reg.r1, @as(u16, index) * 2, Reg.acu);
}
