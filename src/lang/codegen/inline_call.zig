// `@inline` call expansion: splice the callee's body at the call site
// instead of emitting `call addr`. Args bind to fresh caller-frame
// locals, `return` redirects to a forward jmp past the splice, and the
// spliced body is size-capped (decoded through the disassembler so the
// limit counts real instructions, not Zig emit calls).

const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const opcodes = @import("opcodes.zig");
const isa = @import("isa.zig");
const expr_emit = @import("expr.zig");
const value_struct = @import("value_struct.zig");
const lambda = @import("lambda.zig");
const disasm_decoder = codegen.disasm_decoder;

const Emitter = codegen.Emitter;
const Reg = opcodes.Reg;

/// Splice an `@inline` callee's body at the current emit position. Args
/// land in fresh locals in the caller's frame; `return` in the body
/// redirects to a jmp past the splice. Body size is capped at
/// `Emitter.inline_body_instruction_cap` (over → `E_ANN_INLINE_TOO_LARGE`).
pub fn emitInlineCall(self: *Emitter, callee: *const ast.DefDecl, c: ast.CallExpr) !void {
    if (self.inline_depth >= Emitter.inline_max_depth) {
        try self.diagFatal(c.span, "E_ANN_INLINE_RECURSIVE", "codegen: `@inline` def expanded past nesting cap — likely recursive inlining");
        return;
    }
    self.inline_depth += 1;
    defer self.inline_depth -= 1;

    if (c.args.len != callee.params.len) {
        try self.diagFatal(c.span, "E_ANN_INLINE_ARITY", "codegen: `@inline` call arity mismatch — typechecker should have flagged");
        return;
    }

    // Bind args → fresh caller-frame locals. The slots are fp-relative
    // and backed up front by the caller's prologue (`countFrameBytes`
    // counts every inline expansion), so no `sub sp` here — keeping `sp`
    // put is what lets an inline call sit mid-expression without aliasing
    // already-pushed operands. Args materialize in the CALLER's scope —
    // locals still live — then bind into the fresh body scope below.
    const Binding = struct { name: []const u8, ofs: i8 };
    const bindings = try self.arena.alloc(Binding, callee.params.len);
    for (callee.params, c.args, bindings) |p, arg, *b| {
        const dup = try self.arena.dupe(u8, self.source[p.name.start..p.name.end]);
        // A struct param binds to a full-width local materialized by
        // value; a scalar param to a single word.
        if (self.argStructName(arg)) |sname| {
            const ofs = self.reserveFrameSlot(self.structSlotWidth(sname));
            try value_struct.emitInto(self, arg, sname, ofs);
            b.* = .{ .name = dup, .ofs = ofs };
        } else if (self.tupleElemsOf(arg)) |elems| {
            const ofs = self.reserveFrameSlot(self.tupleSlotWidth(elems));
            try value_struct.emitTupleInto(self, arg, elems, ofs);
            b.* = .{ .name = dup, .ofs = ofs };
        } else {
            try expr_emit.emitExpr(self, arg);
            const ofs = self.reserveFrameSlot(2);
            try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, ofs);
            b.* = .{ .name = dup, .ofs = ofs };
        }
    }

    const saved_locals = self.locals;
    const saved_params = self.params;
    self.locals = .{};
    self.params = .{};
    defer {
        self.locals = saved_locals;
        self.params = saved_params;
    }
    for (bindings) |b| try self.locals.put(self.arena, b.name, b.ofs);

    // A struct-returning inline writes its result into a caller-frame
    // slot (there's no callee frame to hold it); each `return` copies
    // there and leaves the slot's address in `acu`.
    const saved_inline_ret = self.inline_ret_struct;
    const saved_inline_slot = self.inline_ret_slot;
    defer {
        self.inline_ret_struct = saved_inline_ret;
        self.inline_ret_slot = saved_inline_slot;
    }
    if (callee.ret_type) |rt| if (self.structNameOfTypeAnn(rt.*)) |sname| {
        self.inline_ret_struct = sname;
        self.inline_ret_slot = self.reserveFrameSlot(self.structWidth(sname));
    };
    // A tuple-returning inline mirrors the struct path; the element
    // layout is read from each `return` expression's inferred type.
    const saved_inline_tuple = self.inline_ret_is_tuple;
    const saved_inline_tuple_slot = self.inline_ret_tuple_slot;
    defer {
        self.inline_ret_is_tuple = saved_inline_tuple;
        self.inline_ret_tuple_slot = saved_inline_tuple_slot;
    }
    if (callee.ret_type) |rt| if (rt.* == .tuple) {
        self.inline_ret_is_tuple = true;
        self.inline_ret_tuple_slot = self.reserveFrameSlot(self.widthOfTypeAnn(rt.*));
    };

    // Install a fresh `inline_returns` collector so nested `return`s
    // rewrite to a forward jmp instead of `ret`.
    const start_offset = try self.currentOffset();
    const saved_returns = self.inline_returns;
    self.inline_returns = std.ArrayList(usize).empty;
    defer self.inline_returns = saved_returns;

    // Lambdas inside `@inline` bodies are unsupported — their mangled
    // labels would collide across call sites.
    const saved_fn_info = self.fn_closure_info;
    defer self.fn_closure_info = saved_fn_info;
    try lambda.analyzeFn(self, callee);
    if (self.fn_closure_info.lambdas.items.len > 0) {
        const name = self.source[callee.name.start..callee.name.end];
        const msg = try std.fmt.allocPrint(
            self.arena,
            "`@inline` def `{s}` declares a lambda in its body — unsupported (lambdas need a host def, but inlined bodies don't emit one)",
            .{name},
        );
        try self.diagFatal(c.span, "E_ANN_INLINE_LAMBDA_BODY", msg);
        return;
    }

    try self.pushBlock();
    for (callee.body) |stmt| try self.emitStatement(stmt);
    try self.popBlockWithDefers();

    // Patch every `return`-redirected jmp to land here, past the body.
    // The return value rides `acu` for the caller — matches the
    // regular-call ABI.
    const end_offset = try self.currentOffset();
    if (self.inline_returns) |*returns| {
        for (returns.items) |patch| try isa.patchJumpTo(self, patch, end_offset);
        returns.deinit(self.allocator);
    }

    // Size gate: decode the spliced bytes so the count matches what the
    // ISA considers an instruction, then enforce the cap.
    const buf: []const u8 = self.currentBufferMut();
    var inst_count: usize = 0;
    var cursor: usize = start_offset;
    while (cursor < end_offset) {
        const dec = disasm_decoder.decodeOne(self.allocator, buf, cursor) catch break;
        defer self.allocator.free(dec.instruction.operands);
        inst_count += 1;
        if (cursor == dec.next_offset) break;
        cursor = dec.next_offset;
    }
    if (inst_count > Emitter.inline_body_instruction_cap) {
        const name = self.source[callee.name.start..callee.name.end];
        const msg = try std.fmt.allocPrint(
            self.arena,
            "`@inline` body of `{s}` lowers to {d} instructions — over the cap of {d}",
            .{ name, inst_count, Emitter.inline_body_instruction_cap },
        );
        try self.diagFatal(c.span, "E_ANN_INLINE_TOO_LARGE", msg);
    }
}
