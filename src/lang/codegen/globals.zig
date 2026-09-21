// Top-level `let` / `const` placement + access. Globals land in one of
// three regions — a pinned `@addr`, the zero page, or the dynamic data
// region — and `const` initializers backed by `bake` are evaluated at
// compile time so their bytes seed the data region directly.

const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const opcodes = @import("opcodes.zig");
const isa = @import("isa.zig");
const fixed = @import("fixed.zig");
const archive = @import("archive.zig");
const strings = @import("strings.zig");
const bake_mod = @import("../bake.zig");
const destructure = @import("destructure.zig");
const class = @import("class.zig");
const value_struct = @import("value_struct.zig");
const types = @import("../types.zig");
const diag_mod = @import("../diagnostic.zig");

const Emitter = codegen.Emitter;
const Global = codegen.Global;
const Reg = opcodes.Reg;
const alignUpU16 = archive.alignUpU16;

/// Register every top-level `let` / `const` as a `Global`. Placement:
/// `@addr $XXXX` pins the address; `@zero_page` takes the next zero-page
/// slot; `@align(N)` pads the cursor; otherwise the next data slot.
pub fn registerGlobals(self: *Emitter, program: *const ast.Program) !void {
    for (program.statements) |*stmt| switch (stmt.*) {
        .let_decl => |*d| try registerGlobalLet(self, d),
        .const_decl => |*d| try registerGlobalConst(self, d),
        else => {},
    };
}

fn registerGlobalLet(self: *Emitter, d: *const ast.LetDecl) !void {
    if (d.pattern.* != .ident) return registerDestructuredLet(self, d);
    const name = self.source[d.pattern.ident.name.start..d.pattern.ident.name.end];
    try placeGlobal(self, name, widthOfLetDecl(self, d), isI8Decl(self, d.type_ann), d.annotations, d.pattern.ident.name);
    // A top-level `let` with an initializer needs a runtime store at
    // startup — the slot is otherwise zero-filled. (`let name: T` with no
    // init stays zero, the declared-but-unset default.)
    if (d.init) |init| try self.global_inits.append(self.allocator, .{ .name = name, .init = init });
}

/// `let PATTERN = init` at module scope (§7.1 — `let` is a module-level
/// declaration). Every name the pattern binds becomes its own global,
/// sized from the typechecker's binder map, and the whole pattern is
/// destructured into those globals at entry startup.
fn registerDestructuredLet(self: *Emitter, d: *const ast.LetDecl) !void {
    const init = d.init orelse {
        try self.diagFatal(
            d.span,
            "E_CODEGEN_UNSUPPORTED",
            "codegen: a destructuring `let` needs an initializer — there is nothing to destructure",
        );
        return;
    };
    try placeBinderGlobals(self, d.pattern, d.annotations);
    try self.global_destructures.append(self.allocator, .{ .pattern = d.pattern, .init = init });
}

/// Place one global per identifier the pattern binds, in source order.
/// A wildcard binds nothing; a nested pattern recurses.
fn placeBinderGlobals(self: *Emitter, pat: *const ast.Pattern, annotations: []const ast.Annotation) error{OutOfMemory}!void {
    switch (pat.*) {
        .ident => |i| {
            const name = self.source[i.name.start..i.name.end];
            const ty = self.checked.binder_types.get(i.name.start);
            const width: u16 = if (ty) |t| self.widthOfType(t) else 2;
            const signed_byte = if (ty) |t| t.* == .primitive and t.primitive == .i8 else false;
            try placeGlobal(self, name, width, signed_byte, annotations, i.name);
        },
        .wildcard => {},
        .tuple_pattern => |t| for (t.elems) |e| try placeBinderGlobals(self, e, annotations),
        .struct_pattern => |st| for (st.fields) |f| try placeBinderGlobals(self, f.sub, annotations),
        .variant_pattern => |vp| for (vp.args) |e| try placeBinderGlobals(self, e, annotations),
        else => {},
    }
}

fn registerGlobalConst(self: *Emitter, d: *const ast.ConstDecl) !void {
    const name = self.source[d.name.start..d.name.end];
    // A `bake`-backed initializer yields both the storage width and the
    // bytes to seed; other initializers fall back to the annotated width.
    const baked: ?bake_mod.BakeValue = try evalConstIfBake(self, d);
    const width: u16 = if (baked) |v| @intCast(bake_mod.widthOf(v)) else widthOfConstDecl(self, d);
    try placeGlobal(self, name, width, isI8Decl(self, d.type_ann), d.annotations, d.name);

    if (baked) |v| {
        const g = self.globals.get(name) orelse return;
        const bytes = try self.arena.alloc(u8, bake_mod.widthOf(v));
        // The bytes and any string slot inside them share one home, so
        // they move with the data region together or not at all.
        const relocatable = g.placement == .data;

        // Any `str` inside the value serializes as a zeroed pointer
        // slot and reports its position; the pool has no addresses
        // yet this early. Interning here reserves the bytes, and
        // `compile` writes the resolved address once the pool lays
        // out (§3.8 — a baked `str` lives in static data).
        var str_slots: std.ArrayList(bake_mod.StrSlot) = .empty;
        defer str_slots.deinit(self.allocator);
        _ = try bake_mod.serialize(v, bytes, &str_slots, self.allocator);
        for (str_slots.items) |slot| {
            const decoded = try archive.decodeStringEscapes(self.arena, slot.bytes);
            const id = try strings.internString(self, decoded);
            try self.bake_str_patches.append(self.allocator, .{
                .image_offset = g.address + slot.offset,
                .string_id = id,
                .relocatable = relocatable,
            });
        }
        try self.bake_inits.append(self.allocator, .{
            .addr = g.address,
            .relocatable = relocatable,
            .bytes = bytes,
        });
        return;
    }
    // A non-`bake` initializer is evaluated + stored at startup, like a
    // top-level `let` — without this the slot reads back zero.
    try self.global_inits.append(self.allocator, .{ .name = name, .init = d.init });
}

/// Seed a module-scope `let` / `const` whose initializer is a struct,
/// tuple or array: build it in a frame slot, then copy its bytes into
/// the global.
///
/// The scalar path stores through the accumulator, which holds one
/// value; an aggregate needs its whole width moved.
fn emitAggregateGlobal(
    self: *Emitter,
    init: *const ast.Expr,
    ty: *const types.Type,
    g: codegen.Global,
) !void {
    const width = self.widthOfType(ty);
    const slot = try destructure.materializeScrutinee(self, init, ty);
    const src = Reg.r1;
    const dest = Reg.r2;
    try value_struct.frameAddrToReg(self, slot, src);
    try emitGlobalAddrToReg(self, g, dest);
    try value_struct.copyBytes(self, src, dest, width);
}

/// Seed a module-scope destructuring `let`: materialize the
/// initializer into a frame slot, then copy each bound name out of it
/// into that name's global.
fn emitGlobalDestructure(self: *Emitter, gd: codegen.GlobalDestructure) !void {
    const ty = self.typeOf(gd.init);
    const slot = try destructure.materializeScrutinee(self, gd.init, ty);
    try storeBinders(self, gd.pattern, ty, slot, 0);
}

/// Walk `pat` against `ty`, copying each bound name from the
/// materialized aggregate at `[fp + slot + offset]` into its global.
/// Offsets follow the same layout the runtime uses, so a nested
/// pattern lands on the right bytes.
fn storeBinders(
    self: *Emitter,
    pat: *const ast.Pattern,
    ty: ?*const types.Type,
    slot: i8,
    offset: u16,
) error{OutOfMemory}!void {
    switch (pat.*) {
        .wildcard => {},
        .ident => |i| {
            const name = self.source[i.name.start..i.name.end];
            const g = self.globals.get(name) orelse return;
            try loadFromSlot(self, slot, offset, g.width, g.signed_byte);
            try emitGlobalStore(self, Reg.acu, g);
        },
        .tuple_pattern => |t| {
            const elems: ?[]const *const types.Type = if (ty) |it|
                (if (it.* == .tuple and it.tuple.len == t.elems.len) it.tuple else null)
            else
                null;
            var run: u16 = 0;
            for (t.elems, 0..) |elem, idx| {
                const elem_ty: ?*const types.Type = if (elems) |es| es[idx] else null;
                try storeBinders(self, elem, elem_ty, slot, offset + run);
                run += if (elem_ty) |et| self.widthOfType(et) else 2;
            }
        },
        .struct_pattern => |sp| {
            const sname = self.source[sp.type_name.start..sp.type_name.end];
            for (sp.fields) |f| {
                const fname = self.source[f.name.start..f.name.end];
                const info = self.structFieldInfo(sname, fname) orelse continue;
                try storeBinders(self, f.sub, null, slot, offset + info.offset);
            }
        },
        else => try self.diagFatal(
            pat.span(),
            "E_CODEGEN_UNSUPPORTED",
            "codegen: this pattern shape isn't supported for a module-scope `let` — bind the value to one name and destructure inside a function",
        ),
    }
}

/// Load `width` bytes from `[fp + slot + offset]` into `acu`,
/// sign-extending a signed byte the way a local load would. The
/// address goes through a pointer register because the offset is an
/// in-aggregate delta that can push past the `[fp + imm8]` range.
fn loadFromSlot(self: *Emitter, slot: i8, offset: u16, width: u16, signed_byte: bool) !void {
    // A frame slot plus an in-aggregate delta; the frame-size check
    // bounds both, so the sum stays addressable.
    // @as: widen the i8 slot and the u16 delta to add them in i16.
    const eff: i16 = @as(i16, slot) + @as(i16, @intCast(offset));
    try isa.movRegToReg(self, Reg.fp, Reg.r1);
    if (eff < 0) {
        try isa.subImmFromReg(self, @intCast(-eff), Reg.r1);
    } else if (eff > 0) {
        try isa.addImmToReg(self, @intCast(eff), Reg.r1);
    }
    if (width == 1) {
        try class.emitByteLoadAtOffset(self, Reg.r1, 0, Reg.acu);
        if (signed_byte) try isa.signExtendByte(self, Reg.acu);
        return;
    }
    try class.emitWordLoadAtOffset(self, Reg.r1, 0, Reg.acu);
}

/// Whether a binding's declared type is `i8` — the one signed byte type,
/// so a byte load must sign-extend. `null` (unannotated) widens to a word
/// slot, which carries the sign already.
fn isI8Decl(self: *const Emitter, type_ann: ?*ast.TypeAnn) bool {
    const t = type_ann orelse return false;
    return self.isPrimitiveTypeAnn(t.*, "i8");
}

/// Emit the entry-startup stores that seed every non-`bake` top-level
/// `let` / `const` slot with its initializer's value (declaration order,
/// so a later init can read an earlier one). An `@addr`-pinned global is
/// skipped — it names a fixed location (typically MMIO) that already
/// holds the live value, so its initializer must not stomp it at boot.
pub fn emitGlobalInits(self: *Emitter) !void {
    for (self.global_destructures.items) |gd| try emitGlobalDestructure(self, gd);
    for (self.global_inits.items) |gi| {
        const g = self.globals.get(gi.name) orelse continue;
        if (g.placement == .addr) continue;
        // An aggregate does not fit the accumulator: materialize it
        // into a frame slot the way a destructuring `let` does, then
        // copy the bytes out to the global's own storage.
        const ty = self.typeOf(gi.init);
        if (ty) |t| {
            if (self.isInlineAggregateType(t)) {
                try emitAggregateGlobal(self, gi.init, t, g);
                continue;
            }
        }
        try self.emitExpr(gi.init);
        try emitGlobalStore(self, Reg.acu, g);
        if (try fixed.storeHighToAddr(self, gi.init, g.address)) |hi| try noteDataRef(self, g, hi);
    }
}

/// Evaluate a `const X = …` initializer whose RHS is a `bake do` block
/// or a `bake def` call; `null` for non-bake initializers.
fn evalConstIfBake(self: *Emitter, d: *const ast.ConstDecl) !?bake_mod.BakeValue {
    switch (d.init.*) {
        .do_expr => |do| {
            if (!do.is_bake) return null;
            return try runBake(self, d.span, .{ .do_expr = &d.init.do_expr });
        },
        .call => |c| {
            if (c.callee.* != .ident) return null;
            const callee_name = self.resolveImportAlias(self.source[c.callee.ident.span.start..c.callee.ident.span.end]);
            const decl = self.bake_defs.get(callee_name) orelse return null;
            // Top-level entry call — args must be literal / const-foldable.
            const args = try self.arena.alloc(bake_mod.BakeValue, c.args.len);
            for (c.args, 0..) |a, i| {
                args[i] = bake_mod.literalAsBakeValue(self.source, a) orelse {
                    try self.diagFatal(a.span(), "E_BAKE_UNSUPPORTED", "bake-call args at top-level must be literal values");
                    return null;
                };
            }
            return try runBakeDef(self, d.span, decl, args);
        },
        else => return null,
    }
}

/// Tagged input to `runBake` — picks the entry shape so one helper
/// handles the diagnostic plumbing.
const BakeEntry = union(enum) {
    do_expr: *const ast.DoExpr,
};

fn runBake(self: *Emitter, span: ast.Span, entry: BakeEntry) !?bake_mod.BakeValue {
    const opts: bake_mod.Options = .{ .bake_defs = &bakeDefsAdapter(self), .expr_types = &self.checked.expr_types };
    var result = switch (entry) {
        .do_expr => |de| try bake_mod.evaluateDo(self.allocator, self.source, de, opts),
    };
    defer result.deinit(self.allocator);
    try forwardBakeDiagnostics(self, result.diagnostics);
    if (result.value == null) {
        try self.diagFatal(span, "E_BAKE_UNSUPPORTED", "bake evaluation failed; see diagnostics above");
        return null;
    }
    return try bake_mod.cloneBakeValue(self.arena, result.value.?);
}

fn runBakeDef(self: *Emitter, span: ast.Span, decl: *const ast.DefDecl, args: []const bake_mod.BakeValue) !?bake_mod.BakeValue {
    const adapter = bakeDefsAdapter(self);
    const opts: bake_mod.Options = .{ .bake_defs = &adapter, .expr_types = &self.checked.expr_types };
    var result = try bake_mod.evaluateDef(self.allocator, self.source, decl, args, opts);
    defer result.deinit(self.allocator);
    try forwardBakeDiagnostics(self, result.diagnostics);
    if (result.value == null) {
        try self.diagFatal(span, "E_BAKE_UNSUPPORTED", "bake evaluation failed; see diagnostics above");
        return null;
    }
    return try bake_mod.cloneBakeValue(self.arena, result.value.?);
}

fn forwardBakeDiagnostics(self: *Emitter, diags: []const diag_mod.Diagnostic) !void {
    for (diags) |diag| {
        try self.diagnostics.append(self.allocator, .{
            .severity = diag.severity,
            .code = diag.code,
            .message = try self.diag_arena.dupe(u8, diag.message),
            .span = diag.span,
        });
    }
}

/// Snapshot the bake-def index into the std-`StringHashMap` shape the
/// evaluator expects. Rebuilt per call so later bake-def discovery
/// stays visible; the evaluator only borrows it for one call.
fn bakeDefsAdapter(self: *Emitter) std.StringHashMap(*const ast.DefDecl) {
    var map = std.StringHashMap(*const ast.DefDecl).init(self.arena);
    var it = self.bake_defs.iterator();
    while (it.next()) |e| {
        // allow-strict: copies fit in the arena that owns `bake_defs`; OOM would have surfaced upstream.
        map.put(e.key_ptr.*, e.value_ptr.*) catch unreachable;
    }
    return map;
}

fn placeGlobal(
    self: *Emitter,
    name: []const u8,
    width: u16,
    signed_byte: bool,
    annotations: []const ast.Annotation,
    decl_span: ast.Span,
) !void {
    var pinned_addr: ?u16 = null;
    var zero_page: bool = false;
    var align_n: ?u16 = null;
    for (annotations) |ann| {
        const ann_name = self.source[ann.name.start..ann.name.end];
        if (std.mem.eql(u8, ann_name, "addr") and ann.args.len == 1 and ann.args[0].* == .int_lit) {
            // @as: address literals are non-negative per §3.7.1; truncating i32 → u16 preserves bytes.
            pinned_addr = @intCast(ann.args[0].int_lit.value & 0xFFFF);
        } else if (std.mem.eql(u8, ann_name, "zero_page")) {
            zero_page = true;
        } else if (std.mem.eql(u8, ann_name, "align") and ann.args.len == 1 and ann.args[0].* == .int_lit) {
            // @as: typechecker verified a power-of-two; i32 → u16 fits the alignment range.
            align_n = @intCast(ann.args[0].int_lit.value & 0xFFFF);
        }
    }
    const dup = try self.arena.dupe(u8, name);

    if (pinned_addr) |addr| {
        try self.globals.put(self.arena, dup, .{ .address = addr, .width = width, .placement = .addr, .signed_byte = signed_byte });
        return;
    }
    if (zero_page) {
        if (align_n) |n| self.zp_cursor = alignUpU16(self.zp_cursor, n);
        if (self.zp_cursor + width > 0x100) {
            try self.diagFatal(decl_span, "E_CODEGEN_ZP_OVERFLOW", "zero-page region exhausted — too many `@zero_page` globals");
            return;
        }
        try self.globals.put(self.arena, dup, .{ .address = self.zp_cursor, .width = width, .placement = .zero_page, .signed_byte = signed_byte });
        self.zp_cursor += width;
        return;
    }
    if (align_n) |n| self.data_cursor = alignUpU16(self.data_cursor, n);
    // @as: widen to u32 so a wide global (e.g. a large baked array) can't wrap the bound check itself.
    if (@as(u32, self.data_cursor) + width > codegen.data_region_end) {
        try self.diagFatal(decl_span, "E_CODEGEN_DATA_OVERFLOW", "static-data region exhausted — too many data globals");
        return;
    }
    try self.globals.put(self.arena, dup, .{ .address = self.data_cursor, .width = width, .placement = .data, .signed_byte = signed_byte });
    self.data_cursor += width;
}

/// Storage width of a `let` / `const` global: its annotated type width,
/// or the inferred initializer width when unannotated.
fn widthOfLetDecl(self: *const Emitter, d: *const ast.LetDecl) u16 {
    if (d.type_ann) |t| return self.widthOfTypeAnn(t.*);
    if (d.init) |init| if (self.typeOf(init)) |t| {
        if (fixed.isFixedType(t)) return Emitter.fixed_size;
    };
    return 2;
}

fn widthOfConstDecl(self: *const Emitter, d: *const ast.ConstDecl) u16 {
    if (d.type_ann) |t| return self.widthOfTypeAnn(t.*);
    if (self.typeOf(d.init)) |t| {
        if (fixed.isFixedType(t)) return Emitter.fixed_size;
    }
    return 2;
}

/// Record the 2-byte address slot at `slot` as naming `g`, so the link
/// step shifts it when the data region sits above the code. The slot
/// already holds the provisional address, whatever the emitting
/// instruction put there.
///
/// A `@addr`-pinned or zero-page global names an address the program
/// chose, which never moves, so it is never recorded.
pub fn noteDataRef(self: *Emitter, g: Global, slot: usize) !void {
    if (g.placement != .data) return;
    try self.data_patches.append(self.allocator, .{
        .bank = self.current_bank,
        .code_offset = slot,
    });
}

/// Load `g`'s address into `dest` — `addr_of`, and the destination of
/// an aggregate global's seed copy.
pub fn emitGlobalAddrToReg(self: *Emitter, g: Global, dest: u8) !void {
    const slot = try isa.movImmToRegSlot(self, g.address, dest);
    try noteDataRef(self, g, slot);
}

/// Load `g`'s value into `acu`. The instruction shape depends on the
/// placement family + byte width.
pub fn emitGlobalLoad(self: *Emitter, g: Global) !void {
    switch (g.placement) {
        .addr, .data => {
            const slot = if (g.width == 1)
                try isa.mov8AddrToReg(self, g.address, Reg.acu)
            else
                try isa.movAddrToReg(self, g.address, Reg.acu);
            try noteDataRef(self, g, slot);
        },
        .zero_page => {
            // @as: placement.zero_page guarantees address ≤ 0xFF.
            const zp: u8 = @intCast(g.address);
            if (g.width == 1) {
                try isa.mov8ZpToReg(self, zp, Reg.acu);
            } else {
                try isa.movZpToReg(self, zp, Reg.acu);
            }
        },
    }
    // A byte-wide `i8` global loads zero-extended; sign-extend so a
    // negative value keeps its sign in expression context.
    if (g.width == 1 and g.signed_byte) try isa.signExtendByte(self, Reg.acu);
}

/// Store `src`'s value into `g`'s slot. Byte-width globals use `movl`
/// (low-byte store) so the neighboring byte stays untouched — critical
/// for MMIO where adjacent addresses are distinct registers.
pub fn emitGlobalStore(self: *Emitter, src: u8, g: Global) !void {
    switch (g.placement) {
        .addr, .data => {
            const slot = if (g.width == 1)
                try isa.movlRegToAddr(self, src, g.address)
            else
                try isa.movRegToAddr(self, src, g.address);
            try noteDataRef(self, g, slot);
        },
        .zero_page => {
            // @as: placement.zero_page guarantees address ≤ 0xFF.
            const zp: u8 = @intCast(g.address);
            if (g.width == 1) {
                try isa.movlRegToZp(self, src, zp);
            } else {
                try isa.movRegToZp(self, src, zp);
            }
        },
    }
}
