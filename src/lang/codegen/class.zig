/// Class lowering — instance layout, vtable emission, constructor
/// calls, field read/write, and method dispatch via vtable.
/// Handles single inheritance via `extends`: a child class
/// inherits the parent's field layout (own fields appended;
/// shadowed names occupy distinct slots and `super.field` reaches
/// the parent's), and the child's vtable copies the parent's
/// method addresses, overrides re-declared slots, and appends
/// brand-new methods at fresh slot indices.
///
/// Per spec §6 a class instance is `[vtable_ptr: u16][field bytes
/// contiguous]`. The vtable lives in static data (appended after
/// the code body and string pool, same pattern as
/// `codegen/strings.zig`) — one u16 entry per method, in slot
/// order. Method calls load the vtable pointer from the instance,
/// index into the table, and `call_reg` the resolved address.
/// `super.method(args)` bypasses the vtable and emits a direct
/// call to the parent's mangled label.
const std = @import("std");
const ast = @import("../ast.zig");
const opcodes = @import("opcodes.zig");
const codegen_mod = @import("../codegen.zig");

const Emitter = codegen_mod.Emitter;
const Op = opcodes.Op;
const Reg = opcodes.Reg;
const Sys = opcodes.Sys;

/// Layout for one class: total instance size in bytes, per-field
/// byte offset relative to the instance base, per-method vtable
/// slot, method-by-slot order for vtable emission, the parent
/// class name (for `super` resolution), and the vtable address
/// (populated after vtable emission).
pub const ClassLayout = struct {
    instance_size: u16,
    field_offsets: std.StringHashMapUnmanaged(FieldInfo),
    /// Method name → slot index inside this class's vtable.
    /// Inherited methods sit at the parent's slot indices;
    /// overrides reuse those slots; brand-new methods append at
    /// the tail.
    method_slots: std.StringHashMapUnmanaged(u16),
    /// Method name → name of the class that actually defines this
    /// method (after inheritance + override resolution). Drives
    /// the `ClassName.methodName` label lookup at vtable-emit time
    /// and at `super.method` direct-call sites.
    method_owners: std.StringHashMapUnmanaged([]const u8),
    /// Method names in slot order. `method_order.items[N]` is the
    /// method that occupies slot N — the vtable emits its address
    /// in that order.
    method_order: std.ArrayListUnmanaged([]const u8),
    /// Parent class name when this class `extends` something;
    /// `null` for root classes. Drives `super.method` direct call
    /// and `super.field` parent-shadowed access.
    parent_name: ?[]const u8,
    vtable_addr: ?u16,
};

/// Per-field metadata captured at layout time.
pub const FieldInfo = struct {
    offset: u16,
    width: u8,
};

/// Pre-pass: index every top-level class decl by name. Layouts
/// (which need to walk parents first) get computed in the
/// follow-up `computeLayouts` pass.
pub fn collectClassDecls(self: *Emitter, program: *const ast.Program) !void {
    for (program.statements) |*stmt| switch (stmt.*) {
        .class_decl => |cd| {
            const name = self.source[cd.name.start..cd.name.end];
            const dup = try self.arena.dupe(u8, name);
            try self.class_decls.put(self.arena, dup, &stmt.class_decl);
        },
        else => {},
    };
}

/// Compute layouts for every indexed class. Single-pass with
/// recursive parent resolution — `computeLayout` is memoized so a
/// chain `A ← B ← C` collapses to one walk per class.
pub fn computeLayouts(self: *Emitter) !void {
    var it = self.class_decls.iterator();
    while (it.next()) |entry| {
        _ = try computeLayout(self, entry.key_ptr.*);
    }
}

/// Compute one class's layout, recursing to the parent first when
/// the class `extends`. Memoized via `class_layouts.contains` so
/// the same layout never gets built twice.
fn computeLayout(self: *Emitter, class_name: []const u8) !void {
    if (self.class_layouts.contains(class_name)) return;
    const cd = self.class_decls.get(class_name) orelse return;

    var layout: ClassLayout = .{
        .instance_size = 2, // vtable_ptr at offset 0
        .field_offsets = .{},
        .method_slots = .{},
        .method_owners = .{},
        .method_order = .empty,
        .parent_name = null,
        .vtable_addr = null,
    };

    // Inherit from parent — fields + methods seed the layout
    // before this class's own additions get applied on top.
    if (cd.extends) |ext_span| {
        const parent_name = self.source[ext_span.start..ext_span.end];
        try computeLayout(self, parent_name);
        if (self.class_layouts.getPtr(parent_name)) |parent_layout| {
            layout.parent_name = try self.arena.dupe(u8, parent_name);
            layout.instance_size = parent_layout.instance_size;
            var fit = parent_layout.field_offsets.iterator();
            while (fit.next()) |e| {
                try layout.field_offsets.put(self.arena, e.key_ptr.*, e.value_ptr.*);
            }
            var mit = parent_layout.method_slots.iterator();
            while (mit.next()) |e| {
                try layout.method_slots.put(self.arena, e.key_ptr.*, e.value_ptr.*);
            }
            var oit = parent_layout.method_owners.iterator();
            while (oit.next()) |e| {
                try layout.method_owners.put(self.arena, e.key_ptr.*, e.value_ptr.*);
            }
            for (parent_layout.method_order.items) |mname| {
                try layout.method_order.append(self.arena, mname);
            }
        }
    }

    // Own fields — shadowing replaces the inherited entry in
    // `field_offsets` so `self.X` resolves to the child's slot.
    // The parent's slot remains in memory (instance_size already
    // counted it) and stays reachable via `super.X`.
    for (cd.fields) |field| {
        const width: u8 = if (field.type_ann) |t|
            self.widthOfTypeAnn(t.*)
        else
            2;
        const fname = self.source[field.name.start..field.name.end];
        const dup_f = try self.arena.dupe(u8, fname);
        try layout.field_offsets.put(self.arena, dup_f, .{
            .offset = layout.instance_size,
            .width = width,
        });
        layout.instance_size += width;
    }

    // Own methods — overrides reuse the parent's slot (same name
    // already in `method_slots`); brand-new methods append.
    const dup_class = try self.arena.dupe(u8, class_name);
    for (cd.methods) |method| {
        const mname = self.source[method.name.start..method.name.end];
        const dup_m = try self.arena.dupe(u8, mname);
        if (layout.method_slots.get(mname) != null) {
            // Override — slot stays, only the owner changes.
            try layout.method_owners.put(self.arena, dup_m, dup_class);
        } else {
            // @as: method slot fits u16; practical caps are well below 32k.
            const slot: u16 = @intCast(layout.method_order.items.len);
            try layout.method_slots.put(self.arena, dup_m, slot);
            try layout.method_owners.put(self.arena, dup_m, dup_class);
            try layout.method_order.append(self.arena, dup_m);
        }
    }

    try self.class_layouts.put(self.arena, dup_class, layout);
}

/// Mangled label for a class method — internal map key only, not
/// emitted as a user-visible symbol. `.` keeps the two halves
/// visually distinct in diagnostics.
pub fn methodLabel(self: *Emitter, class_name: []const u8, method_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(self.arena, "{s}.{s}", .{ class_name, method_name });
}

/// Iterate every class's methods and emit each one as a plain def
/// with a mangled label. Mirrors the top-level def loop in
/// `emitProgram`; reuses the same calling convention so methods
/// look like free fns at the bytecode level (self is param 0).
pub fn emitClassMethods(self: *Emitter, program: *const ast.Program) !void {
    for (program.statements) |*stmt| switch (stmt.*) {
        .class_decl => |cd| {
            const cname = self.source[cd.name.start..cd.name.end];
            for (cd.methods) |*method| {
                const mname = self.source[method.name.start..method.name.end];
                const label = try methodLabel(self, cname, mname);
                try self.emitMethodAsDef(method, cname, label);
            }
        },
        else => {},
    };
}

/// Emit per-class vtables after all method addresses are known.
/// Vtable bytes go into the base image (same pattern as
/// `emitStringPool`) so the runtime can read them via fixed
/// addresses recorded in `vtable_addr`. Each vtable is `N * 2`
/// bytes of little-endian u16 method addresses.
pub fn emitVtables(self: *Emitter) !void {
    // Vtables live in the base image so banked code can still
    // address them. Save + restore buffer routing.
    const saved_bank = self.current_bank;
    self.current_bank = null;
    defer self.current_bank = saved_bank;

    var it = self.class_decls.iterator();
    while (it.next()) |entry| {
        const class_name = entry.key_ptr.*;
        const layout = self.class_layouts.getPtr(class_name) orelse continue;

        // @as: currentOffset returns usize, narrow to u16 — base image is ≤ 64 KiB.
        const offset: u16 = @intCast(try self.currentOffset());
        layout.vtable_addr = codegen_mod.code_base +% offset;

        // Iterate in slot order — each slot's address comes from
        // the class that actually owns the method (inherited
        // methods → parent's label; overrides → child's label).
        for (layout.method_order.items) |mname| {
            const owner = layout.method_owners.get(mname) orelse class_name;
            const label = try methodLabel(self, owner, mname);
            const method_addr = self.fn_addresses.get(label) orelse 0;
            try self.emitU16Le(method_addr);
        }
    }
}

/// `true` when `name` is a registered class — used by `emitCall`
/// to detect `ClassName(args)` constructor shapes before falling
/// into the free-fn calling path.
pub fn isClassName(self: *const Emitter, name: []const u8) bool {
    return self.class_decls.contains(name);
}

/// Resolve every constructor-side vtable-address placeholder. Runs
/// after `emitVtables` so each `class_layouts.vtable_addr` is set.
pub fn patchVtableSlots(self: *Emitter) !void {
    for (self.vtable_patches.items) |p| {
        const layout = self.class_layouts.get(p.class_name) orelse continue;
        const addr = layout.vtable_addr orelse 0;
        const buf: []u8 = if (p.bank) |b|
            if (self.banks.getPtr(b)) |bl| bl.items else continue
        else
            self.code.items;
        if (p.code_offset + 2 > buf.len) continue;
        // safety: addr is u16; the two-byte slot fits cleanly.
        buf[p.code_offset] = @intCast(addr & 0xFF);
        buf[p.code_offset + 1] = @intCast((addr >> 8) & 0xFF);
    }
}

/// Lower `ClassName(args)` — bump-allocate an instance, write the
/// vtable pointer at offset 0, optionally call `init`, then leave
/// the instance address in `acu` (so callers can store it in a
/// `let` binding).
pub fn emitConstructor(
    self: *Emitter,
    class_name: []const u8,
    c: ast.CallExpr,
) !void {
    const layout = self.class_layouts.get(class_name) orelse {
        try self.diagFatal(c.span, "E_CODEGEN_UNKNOWN_CLASS", "codegen: constructor for unknown class");
        return;
    };
    // 1. mov instance_size, acu ; sys alloc
    try self.movImmToReg(layout.instance_size, Reg.acu);
    try self.emitByte(Op.sys);
    try self.emitByte(Sys.alloc);

    // 2. Save instance pointer in r1 for the vtable write.
    try self.movRegToReg(Reg.acu, Reg.r1);

    // 3. Write vtable address into the instance's word at offset 0.
    //    The vtable's address isn't known yet (vtables emit after
    //    all defs), so leave a placeholder + record a patch that
    //    `patchVtableSlots` rewrites once `emitVtables` runs.
    try self.emitByte(Op.mov_imm16_reg);
    const vtable_slot = try self.currentOffset();
    try self.emitU16Le(0); // placeholder, patched in patchVtableSlots
    try self.emitByte(Reg.r2);
    try self.vtable_patches.append(self.allocator, .{
        .bank = self.current_bank,
        .code_offset = vtable_slot,
        .class_name = try self.arena.dupe(u8, class_name),
    });
    // store r2 → [r1] (word)
    try self.emitByte(Op.mov_reg_to_ptr);
    try self.emitByte(Reg.r1);
    try self.emitByte(Reg.r2);

    // 4. If the class declares an `init` method, call it with
    //    (self=r1, user_args...). The free-fn calling convention
    //    pushes right-to-left.
    if (initOwner(self, class_name)) |owner| {
        // Push user args right-to-left, preserving r1 across eval.
        var i: usize = c.args.len;
        while (i > 0) {
            i -= 1;
            try self.pushReg(Reg.r1);
            try self.emitExpr(c.args[i]);
            try self.popReg(Reg.r1);
            try self.pushReg(Reg.acu);
        }
        // Push self last so it lands at fp+4 in the callee frame.
        try self.pushReg(Reg.r1);

        // Direct-call the inheritance-resolved `init` — may live
        // on an ancestor when the child doesn't define its own.
        const init_label = try methodLabel(self, owner, "init");
        try emitDirectCall(self, init_label, c.span);

        // Drop args: 1 (self) + user args, 2 bytes each.
        // @as: widen usize args.len to u16 — practical method arity caps well below 32k.
        const drop_bytes: u16 = 2 + @as(u16, @intCast(c.args.len * 2));
        try self.addImmToReg(drop_bytes, Reg.sp);
        // init may have clobbered acu — restore the instance ptr
        // from r1 so the caller's let-bind reads the right value.
        try self.movRegToReg(Reg.r1, Reg.acu);
    }
    // No-init path leaves acu holding the instance ptr from the
    // `sys alloc` above — none of the intervening ops touched it.
}

/// Look up which class actually owns `init` for this class
/// (walking the inheritance chain). Returns `null` when no
/// ancestor declares `init`.
fn initOwner(self: *Emitter, class_name: []const u8) ?[]const u8 {
    const layout = self.class_layouts.get(class_name) orelse return null;
    return layout.method_owners.get("init");
}

/// Look up a class's parent name (one level up the chain).
pub fn parentOf(self: *const Emitter, class_name: []const u8) ?[]const u8 {
    const layout = self.class_layouts.get(class_name) orelse return null;
    return layout.parent_name;
}

/// Find the closest ancestor of `class_name` whose own layout
/// declares `field_name` (i.e. resolves `super.field`). Returns
/// the field info or `null` if no ancestor field matches.
fn findInheritedField(
    self: *const Emitter,
    class_name: []const u8,
    field_name: []const u8,
) ?FieldInfo {
    var cur = self.class_layouts.get(class_name) orelse return null;
    var parent = cur.parent_name orelse return null;
    while (true) {
        const player = self.class_layouts.get(parent) orelse return null;
        if (player.field_offsets.get(field_name)) |fi| {
            // The inherited entry sits at the parent's own offset
            // (before any further shadowing in deeper chains).
            const cd = self.class_decls.get(parent) orelse return fi;
            // Walk the parent's own fields to find the actual
            // offset that parent's `self.field` would use — same
            // entry the parent's layout has at its own slot.
            for (cd.fields) |f| {
                if (std.mem.eql(u8, self.source[f.name.start..f.name.end], field_name)) {
                    return fi;
                }
            }
            // Field was inherited by parent too — keep walking up.
        }
        parent = player.parent_name orelse return null;
        cur = player;
    }
}

/// Lower `recv.field` (class-typed receiver) — evaluate the
/// receiver into `acu` (instance pointer), then word- or byte-
/// load at the field's offset.
pub fn emitFieldLoad(
    self: *Emitter,
    recv: *const ast.Expr,
    class_name: []const u8,
    field_name: []const u8,
    recv_span: ast.Span,
) !void {
    const layout = self.class_layouts.get(class_name) orelse {
        try self.diagFatal(recv_span, "E_CODEGEN_UNKNOWN_CLASS", "codegen: field access on unknown class");
        return;
    };
    const field = layout.field_offsets.get(field_name) orelse {
        try self.diagFatal(recv_span, "E_CODEGEN_UNDEFINED_FIELD", "codegen: unknown class field");
        return;
    };

    try self.emitExpr(recv);
    // acu = instance ptr; load at acu + field.offset.
    try self.movRegToReg(Reg.acu, Reg.r1);
    if (field.width == 1) {
        try emitByteLoadAtOffset(self, Reg.r1, field.offset, Reg.acu);
    } else {
        try emitWordLoadAtOffset(self, Reg.r1, field.offset, Reg.acu);
    }
}

/// Lower `recv.field = value` — evaluate value, push, evaluate
/// recv, pop value back, store at the field's offset.
pub fn emitFieldStore(
    self: *Emitter,
    recv: *const ast.Expr,
    class_name: []const u8,
    field_name: []const u8,
    value: *const ast.Expr,
    recv_span: ast.Span,
) !void {
    const layout = self.class_layouts.get(class_name) orelse {
        try self.diagFatal(recv_span, "E_CODEGEN_UNKNOWN_CLASS", "codegen: field store on unknown class");
        return;
    };
    const field = layout.field_offsets.get(field_name) orelse {
        try self.diagFatal(recv_span, "E_CODEGEN_UNDEFINED_FIELD", "codegen: unknown class field");
        return;
    };

    try self.emitExpr(value);
    try self.pushReg(Reg.acu);
    try self.emitExpr(recv);
    try self.movRegToReg(Reg.acu, Reg.r1);
    try self.popReg(Reg.r2);
    if (field.width == 1) {
        try emitByteStoreAtOffset(self, Reg.r1, field.offset, Reg.r2);
    } else {
        try emitWordStoreAtOffset(self, Reg.r1, field.offset, Reg.r2);
    }
}

/// Lower `recv.method(args)` (class-typed receiver) — vtable
/// dispatch: load vtable_ptr from instance, load method address
/// from `[vtable + slot*2]`, push self + user args right-to-left,
/// `call_reg`, drop args.
pub fn emitMethodDispatch(
    self: *Emitter,
    recv: *const ast.Expr,
    class_name: []const u8,
    method_name: []const u8,
    args: []const *const ast.Expr,
    span: ast.Span,
) !void {
    const layout = self.class_layouts.get(class_name) orelse {
        try self.diagFatal(span, "E_CODEGEN_UNKNOWN_CLASS", "codegen: method call on unknown class");
        return;
    };
    const slot = layout.method_slots.get(method_name) orelse {
        try self.diagFatal(span, "E_CODEGEN_UNDEFINED_METHOD", "codegen: unknown class method");
        return;
    };

    // 1. Evaluate receiver, stash instance ptr in r1.
    try self.emitExpr(recv);
    try self.movRegToReg(Reg.acu, Reg.r1);

    // 2. Load vtable pointer from [r1+0] into r2.
    try emitWordLoadAtOffset(self, Reg.r1, 0, Reg.r2);

    // 3. Load method address from [r2 + slot*2] into r3.
    // @as: slot index fits u16; the *2 product fits comfortably.
    const slot_offset: u16 = @as(u16, slot) * 2;
    try emitWordLoadAtOffset(self, Reg.r2, slot_offset, Reg.r3);

    // 4. Push args right-to-left, preserving r1 (instance ptr)
    //    and r3 (method addr) across arg eval.
    var i: usize = args.len;
    while (i > 0) {
        i -= 1;
        try self.pushReg(Reg.r1);
        try self.pushReg(Reg.r3);
        try self.emitExpr(args[i]);
        try self.popReg(Reg.r3);
        try self.popReg(Reg.r1);
        try self.pushReg(Reg.acu);
    }

    // 5. Push self last so it lands at fp+4 in the callee frame.
    try self.pushReg(Reg.r1);

    // 6. call_reg r3 — indirect call to the resolved method.
    try self.emitByte(Op.call_reg);
    try self.emitByte(Reg.r3);

    // 7. Drop args: 1 (self) + user args.
    // @as: widen usize args.len to u16 — practical method arity caps well below 32k.
    const drop_bytes: u16 = 2 + @as(u16, @intCast(args.len * 2));
    try self.addImmToReg(drop_bytes, Reg.sp);
}

/// Lower `super.method(args)` — direct call to the named method
/// on the parent of the enclosing method's class. Bypasses vtable
/// lookup entirely (the dispatch is static at compile time).
/// `enclosing_class` is the class whose method body we're inside
/// (tracked on `Emitter.current_class_name` by `emitMethodAsDef`).
pub fn emitSuperMethodCall(
    self: *Emitter,
    enclosing_class: []const u8,
    method_name: []const u8,
    args: []const *const ast.Expr,
    span: ast.Span,
) !void {
    const parent = parentOf(self, enclosing_class) orelse {
        try self.diagFatal(span, "E_CODEGEN_NO_PARENT", "codegen: `super` used in a class with no parent");
        return;
    };
    // Resolve the actual ancestor that defines this method — walk
    // up from the parent until we find a class that owns it. Lets
    // `super.foo` skip past parents that inherited foo themselves.
    const owner = findMethodOwnerFrom(self, parent, method_name) orelse {
        try self.diagFatal(span, "E_CODEGEN_UNDEFINED_METHOD", "codegen: `super.method` resolves to no ancestor method");
        return;
    };

    // self for the super call is the current method's self (fp+4).
    // Load it into r1 first so arg eval can clobber acu freely.
    if (self.params.get("self")) |ofs| {
        try self.movRegOffsetToReg(Reg.fp, ofs, Reg.r1);
    } else {
        try self.diagFatal(span, "E_CODEGEN_NO_SELF", "codegen: `super.method` used outside a method body");
        return;
    }

    // Push args right-to-left, preserving r1 across eval.
    var i: usize = args.len;
    while (i > 0) {
        i -= 1;
        try self.pushReg(Reg.r1);
        try self.emitExpr(args[i]);
        try self.popReg(Reg.r1);
        try self.pushReg(Reg.acu);
    }
    // Push self last so it lands at fp+4 in the callee frame.
    try self.pushReg(Reg.r1);

    const label = try methodLabel(self, owner, method_name);
    try emitDirectCall(self, label, span);

    // @as: widen usize args.len to u16 — practical method arity caps well below 32k.
    const drop_bytes: u16 = 2 + @as(u16, @intCast(args.len * 2));
    try self.addImmToReg(drop_bytes, Reg.sp);
}

/// Lower `super.field` read — load `self`, then read at the
/// parent-side field offset (the shadowed slot from before the
/// child's own redefinition).
pub fn emitSuperFieldLoad(
    self: *Emitter,
    enclosing_class: []const u8,
    field_name: []const u8,
    span: ast.Span,
) !void {
    const field = findInheritedField(self, enclosing_class, field_name) orelse {
        try self.diagFatal(span, "E_CODEGEN_UNDEFINED_FIELD", "codegen: `super.field` resolves to no ancestor field");
        return;
    };

    if (self.params.get("self")) |ofs| {
        try self.movRegOffsetToReg(Reg.fp, ofs, Reg.r1);
    } else {
        try self.diagFatal(span, "E_CODEGEN_NO_SELF", "codegen: `super.field` used outside a method body");
        return;
    }
    if (field.width == 1) {
        try emitByteLoadAtOffset(self, Reg.r1, field.offset, Reg.acu);
    } else {
        try emitWordLoadAtOffset(self, Reg.r1, field.offset, Reg.acu);
    }
}

/// Walk the chain from `start_class` upward looking for the first
/// ancestor that defines a method named `method_name`. Returns
/// the ancestor's class name, or `null` if no ancestor declares it.
fn findMethodOwnerFrom(
    self: *const Emitter,
    start_class: []const u8,
    method_name: []const u8,
) ?[]const u8 {
    var cur = start_class;
    while (true) {
        const layout = self.class_layouts.get(cur) orelse return null;
        if (layout.method_owners.get(method_name)) |owner| return owner;
        cur = layout.parent_name orelse return null;
    }
}

/// Direct call helper — used by the constructor for the `init`
/// call. Records a patch so the address resolves at
/// end-of-emission alongside every other free-fn call.
fn emitDirectCall(self: *Emitter, label: []const u8, span: ast.Span) !void {
    const dup = try self.arena.dupe(u8, label);
    try self.emitByte(Op.call_addr);
    const patch_offset = try self.currentOffset();
    try self.emitU16Le(0);
    try self.call_patches.append(self.allocator, .{
        .bank = self.current_bank,
        .code_offset = patch_offset,
        .target = .{ .fn_name = dup },
        .span = span,
    });
}

/// Word load: `mov [base + offset], dst`. The native opcode
/// takes an i8 offset; widen via `add` + indirect load when the
/// offset exceeds 127.
fn emitWordLoadAtOffset(self: *Emitter, base: u8, offset: u16, dst: u8) !void {
    if (offset <= 127) {
        // @as: offset fits i8 (≤127); the cast is a no-op for the value range.
        try self.movRegOffsetToReg(base, @as(i8, @intCast(offset)), dst);
        return;
    }
    // tmp = base + offset; then load [tmp+0].
    try self.movRegToReg(base, Reg.r2);
    try self.addImmToReg(offset, Reg.r2);
    try self.movRegOffsetToReg(Reg.r2, 0, dst);
}

/// Word store: `mov src, [base + offset]`. Same `i8`-vs-widen
/// rule as the load helper.
fn emitWordStoreAtOffset(self: *Emitter, base: u8, offset: u16, src: u8) !void {
    if (offset <= 127) {
        // @as: offset fits i8 (≤127); the cast is a no-op for the value range.
        try self.movRegToRegOffset(src, base, @as(i8, @intCast(offset)));
        return;
    }
    try self.movRegToReg(base, Reg.r3);
    try self.addImmToReg(offset, Reg.r3);
    try self.movRegToRegOffset(src, Reg.r3, 0);
}

/// Byte load with `+offset` addressing — synthesized via a temp
/// pointer register. No native indexed-byte load opcode exists.
/// `mov8_ptr_to_reg` (0x24) operand order: ptr_reg byte, dst byte.
fn emitByteLoadAtOffset(self: *Emitter, base: u8, offset: u16, dst: u8) !void {
    if (offset == 0) {
        try self.emitByte(Op.mov8_ptr_to_reg);
        try self.emitByte(base);
        try self.emitByte(dst);
        return;
    }
    try self.movRegToReg(base, Reg.r2);
    try self.addImmToReg(offset, Reg.r2);
    try self.emitByte(Op.mov8_ptr_to_reg);
    try self.emitByte(Reg.r2);
    try self.emitByte(dst);
}

/// Byte store with `+offset` addressing. `mov8_reg_to_ptr` (0x23)
/// operand order: src byte, ptr_reg byte.
fn emitByteStoreAtOffset(self: *Emitter, base: u8, offset: u16, src: u8) !void {
    if (offset == 0) {
        try self.emitByte(Op.mov8_reg_to_ptr);
        try self.emitByte(src);
        try self.emitByte(base);
        return;
    }
    try self.movRegToReg(base, Reg.r3);
    try self.addImmToReg(offset, Reg.r3);
    try self.emitByte(Op.mov8_reg_to_ptr);
    try self.emitByte(src);
    try self.emitByte(Reg.r3);
}
