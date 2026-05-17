/// Class lowering — instance layout, vtable emission, constructor
/// calls, field read/write, and method dispatch via vtable.
///
/// Per spec §6 a class instance is `[vtable_ptr: u16][field bytes
/// contiguous]`. The vtable lives in static data (appended after
/// the code body and string pool, same pattern as
/// `codegen/strings.zig`) — one u16 entry per method, in
/// declaration order. Method calls load the vtable pointer from
/// the instance, index into the table, and `call_reg` the
/// resolved address.
///
/// Single-class scope only: inheritance + `super` land in a
/// follow-up PR.
const std = @import("std");
const ast = @import("../ast.zig");
const opcodes = @import("opcodes.zig");
const codegen_mod = @import("../codegen.zig");

const Emitter = codegen_mod.Emitter;
const Op = opcodes.Op;
const Reg = opcodes.Reg;
const Sys = opcodes.Sys;

/// Layout for one class: total instance size in bytes, per-field
/// byte offset relative to the instance base, and the vtable
/// address (populated after vtable emission).
pub const ClassLayout = struct {
    instance_size: u16,
    field_offsets: std.StringHashMapUnmanaged(FieldInfo),
    method_slots: std.StringHashMapUnmanaged(u16),
    vtable_addr: ?u16,
};

/// Per-field metadata captured at layout time.
pub const FieldInfo = struct {
    offset: u16,
    width: u8,
};

/// Pre-pass: index every top-level class decl + compute its
/// instance layout. The vtable address is left `null` here and
/// populated later by `emitVtables`, once method addresses exist.
pub fn collectClassDecls(self: *Emitter, program: *const ast.Program) !void {
    for (program.statements) |*stmt| switch (stmt.*) {
        .class_decl => |cd| {
            const name = self.source[cd.name.start..cd.name.end];
            const dup = try self.arena.dupe(u8, name);
            try self.class_decls.put(self.arena, dup, &stmt.class_decl);

            var layout: ClassLayout = .{
                .instance_size = 2, // vtable_ptr at offset 0
                .field_offsets = .{},
                .method_slots = .{},
                .vtable_addr = null,
            };
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
            for (cd.methods, 0..) |method, slot| {
                const mname = self.source[method.name.start..method.name.end];
                const dup_m = try self.arena.dupe(u8, mname);
                // @as: method slot fits u16 — practical class size is well below 64k methods.
                try layout.method_slots.put(self.arena, dup_m, @intCast(slot));
            }
            try self.class_layouts.put(self.arena, dup, layout);
        },
        else => {},
    };
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
                try self.emitMethodAsDef(method, label);
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
        const cd = entry.value_ptr.*;
        const layout = self.class_layouts.getPtr(class_name) orelse continue;

        // @as: currentOffset returns usize, narrow to u16 — base image is ≤ 64 KiB.
        const offset: u16 = @intCast(try self.currentOffset());
        layout.vtable_addr = codegen_mod.code_base +% offset;

        for (cd.methods) |method| {
            const mname = self.source[method.name.start..method.name.end];
            const label = try methodLabel(self, class_name, mname);
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
    if (hasInitMethod(self, class_name)) {
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

        const init_label = try methodLabel(self, class_name, "init");
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

/// `true` when the class declares an `init` method.
fn hasInitMethod(self: *Emitter, class_name: []const u8) bool {
    const cd = self.class_decls.get(class_name) orelse return false;
    for (cd.methods) |m| {
        const mname = self.source[m.name.start..m.name.end];
        if (std.mem.eql(u8, mname, "init")) return true;
    }
    return false;
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
