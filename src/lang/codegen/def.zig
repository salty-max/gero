// Per-def emission: prologue (param binding + frame reservation + sret
// setup), body, epilogue (`hlt` / `ret` / `rti`). Methods reuse the
// same path under a mangled label. Forward-reference call sites are
// resolved here once every def's address is known.

const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const opcodes = @import("opcodes.zig");
const isa = @import("isa.zig");
const archive = @import("archive.zig");
const lambda = @import("lambda.zig");
const globals = @import("globals.zig");

const Emitter = codegen.Emitter;
const DefKind = Emitter.DefKind;
const Op = opcodes.Op;
const Reg = opcodes.Reg;
const bank_window_base = archive.bank_window_base;

/// Emit one def under its own name: prologue + body + epilogue.
pub fn emitDef(self: *Emitter, def: *const ast.DefDecl, kind: DefKind) !void {
    return emitDefWithLabel(self, def, kind, self.source[def.name.start..def.name.end]);
}

/// Emit a method as a plain def under a mangled `ClassName.methodName`
/// label, threading `current_class_name` so `super` resolves correctly.
pub fn emitMethodAsDef(self: *Emitter, def: *const ast.DefDecl, class_name: []const u8, label: []const u8) !void {
    const saved = self.current_class_name;
    self.current_class_name = class_name;
    defer self.current_class_name = saved;
    return emitDefWithLabel(self, def, .regular, label);
}

fn emitDefWithLabel(self: *Emitter, def: *const ast.DefDecl, kind: DefKind, label: []const u8) !void {
    // `@bank N` routes this def's body bytes + resolved address into a
    // bank window; `@interrupt N` swaps the epilogue from `ret` to `rti`.
    var bank_target: ?u8 = null;
    var is_isr: bool = false;
    for (def.annotations) |ann| {
        const ann_name = self.source[ann.name.start..ann.name.end];
        if (std.mem.eql(u8, ann_name, "bank") and ann.args.len == 1 and ann.args[0].* == .int_lit) {
            // @as: typechecker enforces u8 range on `@bank N`.
            bank_target = @intCast(ann.args[0].int_lit.value & 0xFF);
        } else if (std.mem.eql(u8, ann_name, "interrupt")) {
            is_isr = true;
        }
    }

    // Save + restore per-fn state for a fresh frame view.
    const saved_locals = self.locals;
    const saved_params = self.params;
    const saved_frame = self.frame_bytes;
    const saved_overflow = self.frame_overflow;
    const saved_entry = self.is_entry;
    const saved_isr = self.is_isr;
    const saved_bank = self.current_bank;
    const saved_ret_struct = self.current_ret_struct;
    const saved_sret_param = self.sret_param_ofs;
    const saved_sret_scratch = self.sret_scratch_ofs;
    self.locals = .{};
    self.params = .{};
    self.frame_bytes = 0;
    self.frame_overflow = false;
    self.is_entry = (kind == .entry);
    self.is_isr = is_isr;
    self.current_bank = bank_target;
    self.sret_scratch_ofs = null;
    defer {
        self.locals = saved_locals;
        self.params = saved_params;
        self.frame_bytes = saved_frame;
        self.frame_overflow = saved_overflow;
        self.is_entry = saved_entry;
        self.is_isr = saved_isr;
        self.current_bank = saved_bank;
        self.current_ret_struct = saved_ret_struct;
        self.sret_param_ofs = saved_sret_param;
        self.sret_scratch_ofs = saved_sret_scratch;
    }

    const dup_name = try self.arena.dupe(u8, label);
    const base = if (bank_target) |_| bank_window_base else codegen.code_base;
    const addr = codegen.offsetToAddr(base, try self.currentOffset());
    try self.fn_addresses.put(self.arena, dup_name, addr);

    // Bind params to positive fp-relative offsets. `call` leaves the
    // stack as [low] ret_ip, old_fp, arg_N-1 … arg_0 [high], so param 0
    // sits at fp+4. Each param sits just above the previous; a struct
    // param occupies its full width (passed by value), so offsets sum
    // widths rather than stepping a fixed 2 bytes.
    var param_ofs: i32 = 4;
    for (def.params) |p| {
        const dup_p = try self.arena.dupe(u8, self.source[p.name.start..p.name.end]);
        // Params sit at positive fp-offsets, addressed via `[fp + imm8]`
        // (±127). Past that, flag it (reported below) and bind a
        // placeholder so we don't panic on the i8 cast.
        const ofs: i8 = if (param_ofs > 127) blk: {
            self.frame_overflow = true;
            break :blk 4;
        } else @intCast(param_ofs);
        try self.params.put(self.arena, dup_p, ofs);
        param_ofs += self.paramWidthAligned(p);
    }

    // A struct-returning def takes a hidden sret destination pointer
    // just above its last user param (the caller pushes it first);
    // `return` copies the result there instead of into `acu`.
    self.current_ret_struct = if (def.ret_type) |rt| self.structNameOfTypeAnn(rt.*) else null;
    self.current_ret_is_tuple = if (def.ret_type) |rt| rt.* == .tuple else false;
    // A param list overrunning the fp range already set `frame_overflow`
    // above, so this clamped value is unused; the clamp only keeps the
    // narrowing from panicking on a pathologically long param list.
    // @as: clamp `param_ofs` into i16 before the narrowing cast.
    self.sret_param_ofs = @intCast(@min(param_ofs, @as(i32, std.math.maxInt(i16))));

    // Banked programs relocate the stack into low RAM (the ISA's flat
    // stack home) before reserving any frame, so call frames never land
    // in the bank-switched window. Must precede the frame reserve below;
    // non-banked programs keep the boot `sp` (no-op).
    if (self.is_entry) try self.relocateBankStack();

    // `@interrupt` handlers save the GP registers + open their own frame
    // before reserving locals, so they're transparent to the interrupted
    // code (interrupt entry preserves only ip/fp/flg).
    if (is_isr) try self.emitIsrPrologue();

    // Reserve the frame up front (fixed reservation — a real allocator
    // would compute live ranges). The sret scratch buffer (holds a
    // returned struct until its consumer copies it out) is carved first
    // so its offset stays stable across the body.
    const scratch_bytes: u16 = self.global_sret_scratch;
    // A frame past the 127-byte fp range is caught by `reserveFrameSlot`
    // as the body emits (→ `E_CODEGEN_FRAME_TOO_LARGE`); this clamp only
    // keeps the static estimate's narrowing from panicking on a huge frame.
    // @as: clamp the frame estimate into u16 before the narrowing cast.
    const reserve_bytes: u16 = @intCast(@min(self.countFrameBytes(def.body) + scratch_bytes, @as(usize, std.math.maxInt(u16))));
    if (reserve_bytes > 0) try isa.subImmFromReg(self, reserve_bytes, Reg.sp);
    if (scratch_bytes > 0) self.sret_scratch_ofs = try self.allocLocalSized("\x00sret", scratch_bytes);

    // Closure-analysis pre-pass — the lambda inventory, capture layouts,
    // and promotion set drive the heap-cell paths in let / ident / assign
    // and the closure-call dispatch.
    try lambda.analyzeFn(self, def);
    defer lambda.resetFnInfo(self);

    // Entry-def prologue: write every `@interrupt N` handler address into
    // its IVT slot before the body runs — boot leaves `flg.I = 0`, so an
    // interrupt could otherwise fire against an uninitialized vector.
    if (self.is_entry) try emitIvtInit(self);

    // Entry-def prologue: seed the cross-bank save-stack pointer before
    // any cross-bank call (no-op when the program has no banked defs).
    if (self.is_entry) try self.seedBankSaveStack();

    // Entry-def prologue: seed every non-`bake` top-level `let` / `const`
    // slot with its initializer before the body can read it.
    if (self.is_entry) try globals.emitGlobalInits(self);

    // The body opens the outermost block — top-level `defer`s run before
    // the implicit epilogue.
    try self.pushBlock();
    for (def.body) |stmt| try self.emitStatement(stmt);
    try self.popBlockWithDefers();

    // Implicit epilogue (no explicit `return`). `ret` resets sp = fp then
    // pops ret_ip + old_fp; the return value rides `acu` for the caller.
    if (self.is_entry) {
        try isa.hlt(self);
    } else if (is_isr) {
        try self.emitIsrEpilogue();
    } else {
        try self.emitByte(Op.ret_op);
    }

    // A frame slot or param that overran the i8 fp-offset range during
    // body emission can't be addressed — fail cleanly rather than ship
    // the placeholder offsets reserveFrameSlot / the param loop emitted.
    if (self.frame_overflow) {
        try self.diagFatal(def.span, "E_CODEGEN_FRAME_TOO_LARGE", "function frame exceeds the 127-byte limit on fp-relative addressing — reduce its locals or parameters");
    }

    // Lambda bodies discovered during analysis emit as plain defs
    // adjacent to the parent so their call sites + closure-creation
    // patches resolve normally.
    try lambda.emitLambdaBodies(self, def);
}

/// Write each `@interrupt N` handler's address into its IVT slot. The
/// handler address is patched later (forward reference); the slot
/// address is known now.
fn emitIvtInit(self: *Emitter) !void {
    for (self.interrupt_defs.items) |handler| {
        try self.emitByte(Op.mov_imm16_addr);
        const addr_patch_offset = try self.currentOffset();
        try self.emitU16Le(0);
        // @as: widen u8 vector before doubling so the wrap-add stays in u16.
        try self.emitU16Le(codegen.ivt_base +% (@as(u16, handler.vector) *% 2));
        try self.call_patches.append(self.allocator, .{
            .bank = self.current_bank,
            .code_offset = addr_patch_offset,
            .target = .{ .fn_name = handler.def_name },
            .span = .{ .start = 0, .end = 0 },
        });
    }
}

/// Rewrite each unresolved call's 2-byte address slot once every def's
/// address is known. Unknown callees emit `E_CODEGEN_UNDEFINED_FN`.
pub fn patchCalls(self: *Emitter) !void {
    for (self.call_patches.items) |p| {
        const target_addr: u16 = switch (p.target) {
            .fn_name => |name| self.fn_addresses.get(name) orelse {
                const msg = try std.fmt.allocPrint(
                    self.diag_arena,
                    "codegen: call target `{s}` is not a known top-level def",
                    .{name},
                );
                try self.diagnostics.append(self.allocator, .{
                    .severity = .fatal,
                    .code = "E_CODEGEN_UNDEFINED_FN",
                    .message = msg,
                    .span = p.span,
                });
                continue;
            },
            .trampoline => self.trampoline_addr orelse continue,
        };
        // Resolve which buffer holds this patch — base or a bank list.
        const buf: []u8 = if (p.bank) |b|
            if (self.banks.getPtr(b)) |bl| bl.items else continue
        else
            self.code.items;
        // safety: u16 → 2 LE bytes; both casts are byte-masks.
        buf[p.code_offset] = @intCast(target_addr & 0xFF);
        buf[p.code_offset + 1] = @intCast(target_addr >> 8);
    }
}
