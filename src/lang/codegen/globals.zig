// Top-level `let` / `const` placement + access. Globals land in one of
// three regions — a pinned `@addr`, the zero page, or the dynamic data
// region — and `const` initializers backed by `bake` are evaluated at
// compile time so their bytes seed the data region directly.

const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const opcodes = @import("opcodes.zig");
const isa = @import("isa.zig");
const archive = @import("archive.zig");
const bake_mod = @import("../bake.zig");
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
    if (d.pattern.* != .ident) return; // destructuring at top-level — slice later
    const name = self.source[d.pattern.ident.name.start..d.pattern.ident.name.end];
    try placeGlobal(self, name, widthOfLetDecl(self, d), isI8Decl(self, d.type_ann), d.annotations, d.pattern.ident.name);
    // A top-level `let` with an initializer needs a runtime store at
    // startup — the slot is otherwise zero-filled. (`let name: T` with no
    // init stays zero, the declared-but-unset default.)
    if (d.init) |init| try self.global_inits.append(self.allocator, .{ .name = name, .init = init });
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
        _ = bake_mod.serialize(v, bytes);
        try self.bake_inits.put(self.allocator, g.address, bytes);
        return;
    }
    // A non-`bake` initializer is evaluated + stored at startup, like a
    // top-level `let` — without this the slot reads back zero.
    try self.global_inits.append(self.allocator, .{ .name = name, .init = d.init });
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
    for (self.global_inits.items) |gi| {
        const g = self.globals.get(gi.name) orelse continue;
        if (g.placement == .addr) continue;
        try self.emitExpr(gi.init);
        try emitGlobalStore(self, Reg.acu, g);
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
/// or the widest primitive (2 bytes) when unannotated.
fn widthOfLetDecl(self: *const Emitter, d: *const ast.LetDecl) u16 {
    return if (d.type_ann) |t| self.widthOfTypeAnn(t.*) else 2;
}

fn widthOfConstDecl(self: *const Emitter, d: *const ast.ConstDecl) u16 {
    return if (d.type_ann) |t| self.widthOfTypeAnn(t.*) else 2;
}

/// Load `g`'s value into `acu`. The instruction shape depends on the
/// placement family + byte width.
pub fn emitGlobalLoad(self: *Emitter, g: Global) !void {
    switch (g.placement) {
        .addr, .data => {
            if (g.width == 1) {
                try isa.mov8AddrToReg(self, g.address, Reg.acu);
            } else {
                try isa.movAddrToReg(self, g.address, Reg.acu);
            }
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
            if (g.width == 1) {
                try isa.movlRegToAddr(self, src, g.address);
            } else {
                try isa.movRegToAddr(self, src, g.address);
            }
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
