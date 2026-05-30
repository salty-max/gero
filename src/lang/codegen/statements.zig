// Leaf statement lowering: `let` / `const` bindings, assignment (and
// its compound + inc/dec desugarings), `return`, and `print`. The
// dispatch hub (`emitStatement`) and control-flow forms live elsewhere;
// these are the terminal statement shapes.

const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const opcodes = @import("opcodes.zig");
const isa = @import("isa.zig");
const class = @import("class.zig");
const value_struct = @import("value_struct.zig");
const lambda = @import("lambda.zig");
const strings = @import("strings.zig");

const Emitter = codegen.Emitter;
const Op = opcodes.Op;
const Reg = opcodes.Reg;
const Sys = opcodes.Sys;

/// The binary operator a compound assignment desugars to — `+=` → `+`,
/// `<<=` → `<<`, and so on. `.set` has no binary form.
fn compoundBinaryOp(op: ast.AssignOp) ast.BinaryOp {
    return switch (op) {
        // plain `=` never reaches this desugar helper
        .set => unreachable,
        .add_set => .add,
        .sub_set => .sub,
        .mul_set => .mul,
        .div_set => .div,
        .mod_set => .mod,
        .bit_and_set => .bit_and,
        .bit_or_set => .bit_or,
        .bit_xor_set => .bit_xor,
        .shl_set => .shl,
        .shr_set => .shr,
    };
}

/// `target = value`, with `target op= value` and `target++/--`
/// desugaring to this path. Targets: ident, class field, struct field.
pub fn emitAssign(self: *Emitter, a_in: ast.AssignStmt) !void {
    var a = a_in;
    if (a.op != .set) {
        // Desugar `target op= value` into `target = (target op value)`
        // and fall through to the plain-store path.
        const rhs = try self.arena.create(ast.Expr);
        rhs.* = .{ .binary = .{
            .op = compoundBinaryOp(a.op),
            .lhs = a.target,
            .rhs = a.value,
            .span = a.span,
        } };
        a.value = rhs;
        a.op = .set;
    }
    // `recv.field = value` routes to the class or struct field-store path.
    if (a.target.* == .field) {
        if (self.classNameOf(a.target.field.receiver)) |cname| {
            const fname = self.source[a.target.field.field.start..a.target.field.field.end];
            try class.emitFieldStore(self, a.target.field.receiver, cname, fname, a.value, a.target.field.span);
            return;
        }
        if (self.structNameOf(a.target.field.receiver)) |sname| {
            const fname = self.source[a.target.field.field.start..a.target.field.field.end];
            try value_struct.emitFieldStore(self, a.target.field.receiver, sname, fname, a.value);
            return;
        }
    }
    if (a.target.* != .ident) {
        try self.unsupported(a.span, "non-ident assignment targets (field / index)");
        return;
    }
    const name = self.source[a.target.ident.span.start..a.target.ident.span.end];
    // Struct-typed reassignment (`b = a`) copies the value's bytes into
    // the binding's slot (§3.4 value semantics).
    if (self.structNameOf(a.target)) |sname| {
        if (self.locals.get(name)) |ofs| {
            try value_struct.emitInto(self, a.value, sname, ofs);
            return;
        }
    }
    // Captured-binding write inside a lambda body — store through the
    // env-relative cell pointer (the parent promoted the binding so the
    // write is visible everywhere).
    if (self.captures.get(name)) |slot| {
        try lambda.emitCaptureStore(self, slot, a.value);
        return;
    }
    // Promoted local in the parent fn — store through the local-slot
    // cell pointer.
    if (lambda.isPromoted(self, name)) {
        if (self.locals.get(name)) |ofs| {
            try lambda.emitPromotedAssign(self, ofs, a.value);
            return;
        }
    }
    try self.emitExpr(a.value); // result in acu
    if (self.locals.get(name)) |ofs| {
        try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, ofs);
        return;
    }
    if (self.params.get(name)) |ofs| {
        try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, ofs);
        return;
    }
    if (self.globals.get(name)) |g| {
        try self.emitGlobalStore(Reg.acu, g);
        return;
    }
    try self.unsupported(a.target.span(), "assignment target not in scope");
}

/// `target++` / `target--` — desugars to `target = target ± 1` and
/// reuses the assignment path.
pub fn emitIncDec(self: *Emitter, id: ast.IncDecStmt) !void {
    const one = try self.arena.create(ast.Expr);
    one.* = .{ .int_lit = .{ .value = 1, .span = id.span } };
    const rhs = try self.arena.create(ast.Expr);
    rhs.* = .{ .binary = .{
        .op = if (id.inc) .add else .sub,
        .lhs = id.target,
        .rhs = one,
        .span = id.span,
    } };
    try emitAssign(self, .{ .target = id.target, .op = .set, .value = rhs, .span = id.span });
}

/// `let name [: T] [= init]` — reserve the binding's slot (full width
/// for a struct, one word otherwise) and lower its initializer.
pub fn emitLetDecl(self: *Emitter, d: ast.LetDecl) !void {
    if (d.pattern.* != .ident) {
        try self.unsupported(d.span, "non-ident `let` patterns");
        return;
    }
    const name = self.source[d.pattern.ident.name.start..d.pattern.ident.name.end];
    const dup_name = try self.arena.dupe(u8, name);

    // Struct-typed binding: reserve the full inline slot and materialize
    // the initializer (literal fields or a value copy) straight into it
    // (§3.4 value semantics).
    const struct_name: ?[]const u8 = if (d.type_ann) |t|
        self.structNameOfTypeAnn(t.*)
    else if (d.init) |e|
        self.structNameOf(e)
    else
        null;
    if (struct_name) |sname| {
        const slot = try self.allocLocalSized(dup_name, self.structWidth(sname));
        if (d.init) |init_expr| try value_struct.emitInto(self, init_expr, sname, slot);
        return;
    }

    const ofs = try self.allocLocal(dup_name);
    // Promoted bindings live as heap cells — the slot holds the cell
    // pointer instead of the value directly.
    if (lambda.isPromoted(self, name)) {
        try lambda.emitPromotedLetInit(self, d.init, ofs);
        return;
    }
    if (d.init) |init_expr| {
        try self.emitExpr(init_expr); // result in acu
        try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, ofs);
    }
    // An uninitialized `let` leaves the slot at whatever the prologue's
    // sub-imm gave it (sp padded downward without zeroing).
}

/// `const name = init` as a local binding — same slot mechanics as a
/// scalar `let` (top-level consts are handled as globals instead).
pub fn emitConstDecl(self: *Emitter, d: ast.ConstDecl) !void {
    const dup_name = try self.arena.dupe(u8, self.source[d.name.start..d.name.end]);
    const ofs = try self.allocLocal(dup_name);
    try self.emitExpr(d.init);
    try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, ofs);
}

/// `return [value]` — places the value (scalar in `acu`, struct via the
/// sret/inline buffer), runs pending defers, then `ret` / `rti` / `hlt`
/// (or a forward jmp inside an `@inline` body).
pub fn emitReturnStmt(self: *Emitter, r: ast.ReturnStmt) !void {
    if (r.value) |v| {
        if (self.inline_ret_struct) |sname| {
            // Inlined struct return: materialize into the caller-frame
            // result slot, then leave its address in `acu`.
            try value_struct.emitInto(self, v, sname, self.inline_ret_slot);
            try isa.movRegToReg(self, Reg.fp, Reg.acu);
            const slot = self.inline_ret_slot; // negative — a caller-frame local
            // @as: widen i8 → i16 so negating the min value is safe; |slot| ≤ frame cap fits u16.
            if (slot < 0) try isa.subImmFromReg(self, @intCast(-@as(i16, slot)), Reg.acu);
        } else if (self.current_ret_struct) |sname| {
            // Struct return: copy the value into the caller's sret buffer,
            // then leave that buffer's address in `acu` (a struct value
            // *is* an address).
            try value_struct.emitIntoSret(self, v, sname, self.sret_param_ofs);
            try isa.movRegToReg(self, Reg.fp, Reg.acu);
            if (self.sret_param_ofs > 0) try isa.addImmToReg(self, @intCast(self.sret_param_ofs), Reg.acu);
            try isa.movRegOffsetToReg(self, Reg.acu, 0, Reg.acu);
        } else {
            try self.emitExpr(v);
        }
    }
    // Defers on every still-active block fire before the frame tears
    // down — innermost first, LIFO within each block. `acu` carries the
    // return value through the cleanup (the defer-emitter saves it).
    try self.unwindAllDefersForReturn();
    if (self.inline_returns) |*returns| {
        // Inside an `@inline` body — redirect `return` to a forward jmp
        // past the splice; the slot is patched once the body emits.
        try self.emitByte(Op.jmp_addr);
        const patch = try self.currentOffset();
        try self.emitU16Le(0);
        try returns.append(self.allocator, patch);
        return;
    }
    if (self.is_entry) {
        try isa.hlt(self);
    } else if (self.is_isr) {
        try self.emitByte(Op.rti_op);
    } else {
        try self.emitByte(Op.ret_op);
    }
}

/// `print a, b, …` — emit each arg by its type, space-separated, with a
/// trailing newline (§4.9).
pub fn emitPrintStmt(self: *Emitter, p: ast.PrintStmt) !void {
    for (p.args, 0..) |arg, i| {
        // Space separator between args (§4.9).
        if (i > 0) {
            try isa.movImmToReg(self, ' ', Reg.acu);
            try isa.sys(self, Sys.print_char);
        }
        try emitPrintArg(self, arg);
    }
    try isa.sys(self, Sys.print_newline); // trailing newline (§4.9)
}

/// Emit one `print` argument, routing to the syscall its inferred type
/// calls for (§4.9): `char` → `print_char`, `fixed` → `print_fixed`,
/// `str` → `print_str` (string literals emit per-part for
/// interpolation), everything else → `print_int`.
fn emitPrintArg(self: *Emitter, arg: *const ast.Expr) !void {
    if (arg.* == .str_lit) {
        try strings.emitPrintStrLit(self, arg.str_lit);
        return;
    }
    if (self.isPrimitiveType(arg, .char)) {
        try self.emitExpr(arg);
        try isa.sys(self, Sys.print_char);
        return;
    }
    if (self.isPrimitiveType(arg, .fixed)) {
        try self.emitExpr(arg);
        try isa.sys(self, Sys.print_fixed);
        return;
    }
    if (self.isPrimitiveType(arg, .str)) {
        try self.emitExpr(arg);
        try isa.sys(self, Sys.print_str);
        return;
    }
    // A struct has no scalar rendering — `print p` would otherwise emit
    // `print_int` of its base address. Print fields explicitly.
    if (self.structNameOf(arg)) |_| {
        try self.unsupported(arg.span(), "printing a whole struct — print its fields instead");
        return;
    }
    try self.emitExpr(arg);
    try isa.sys(self, Sys.print_int);
}
