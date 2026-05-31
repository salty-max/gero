// Leaf statement lowering: `let` / `const` bindings, assignment (and
// its compound + inc/dec desugarings), `return`, and `print`. The
// dispatch hub (`emitStatement`) and control-flow forms live elsewhere;
// these are the terminal statement shapes.

const std = @import("std");
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
    // Tuple-typed reassignment — same inline value copy.
    if (self.tupleElemsOf(a.target)) |elems| {
        if (self.locals.get(name)) |ofs| {
            try value_struct.emitTupleInto(self, a.value, elems, ofs);
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

    // Tuple-typed binding — inline value semantics like a struct, sized
    // by the tuple width (annotated width, or the initializer's).
    const tuple_elems = if (d.init) |e| self.tupleElemsOf(e) else null;
    const ann_tuple = if (d.type_ann) |t| t.* == .tuple else false;
    if (tuple_elems != null or ann_tuple) {
        const width = if (d.type_ann) |t| self.widthOfTypeAnn(t.*) else self.tupleWidth(tuple_elems.?);
        const slot = try self.allocLocalSized(dup_name, width);
        if (d.init) |init_expr| {
            if (tuple_elems) |elems| {
                try value_struct.emitTupleInto(self, init_expr, elems, slot);
            } else try self.unsupported(d.span, "tuple binding initialized from a non-tuple value");
        }
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
        } else if (self.current_ret_is_tuple) {
            // Tuple return: same sret convention as a struct. The element
            // layout comes from the return expression's inferred type.
            if (self.tupleElemsOf(v)) |elems| {
                try value_struct.emitTupleIntoSret(self, v, elems, self.sret_param_ofs);
                try isa.movRegToReg(self, Reg.fp, Reg.acu);
                if (self.sret_param_ofs > 0) try isa.addImmToReg(self, @intCast(self.sret_param_ofs), Reg.acu);
                try isa.movRegOffsetToReg(self, Reg.acu, 0, Reg.acu);
            } else try self.unsupported(r.span, "tuple return from a non-tuple value");
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
    // A struct renders as `Name { field: value, ... }` — its base
    // address is in `acu` after evaluation.
    if (self.structNameOf(arg)) |sname| {
        if (!printSupported(self, sname)) {
            try self.unsupported(arg.span(), "printing a struct with a field type that has no default rendering (array / tuple / Vec / class / reference)");
            return;
        }
        // A struct literal has no standalone address — materialize it as
        // a by-value stack copy first; struct *values* already evaluate
        // to a base address.
        if (arg.* == .struct_lit) {
            try value_struct.pushArg(self, arg, sname);
            try isa.movRegToReg(self, Reg.sp, Reg.acu);
            try emitPrintStruct(self, sname);
            try isa.addImmToReg(self, self.structSlotWidth(sname), Reg.sp);
        } else {
            try self.emitExpr(arg);
            try emitPrintStruct(self, sname);
        }
        return;
    }
    // An enum renders as `Enum.Variant` (`Enum.Variant(a, b)` with a
    // payload) — `acu` holds the tag (payload-free) or slot pointer.
    if (self.enumDeclForExpr(arg)) |ed| {
        if (!enumPrintSupported(self, ed)) {
            try self.unsupported(arg.span(), "printing an enum with a payload field type that has no default rendering (array / tuple / Vec / class / reference)");
            return;
        }
        try self.emitExpr(arg);
        try emitPrintEnum(self, ed);
        return;
    }
    // A whole-tuple default rendering isn't lowered yet (deferred from
    // #305) — reject rather than print the base address as an int.
    if (self.tupleElemsOf(arg) != null) {
        try self.unsupported(arg.span(), "printing a whole tuple — print its elements (`t.0`, `t.1`, …)");
        return;
    }
    try self.emitExpr(arg);
    try isa.sys(self, if (self.isUnsignedInt(arg)) Sys.print_uint else Sys.print_int);
}

/// Render an enum value (tag or slot pointer in `acu`) as
/// `Enum.Variant` / `Enum.Variant(a, b)`. The value is parked at `[sp]`
/// across the tag dispatch, then dropped.
fn emitPrintEnum(self: *Emitter, ed: *const ast.EnumDecl) error{OutOfMemory}!void {
    try isa.pushReg(self, Reg.acu);
    try emitEnumDispatchAtSp(self, ed);
    try isa.addImmToReg(self, 2, Reg.sp);
}

/// Tag-dispatch + render the enum value parked at `[sp]` (a tag word for
/// payload-free enums, a `[tag|payload]` slot pointer otherwise). Each
/// arm compares the tag, prints `Enum.Variant`, then walks the variant's
/// payload fields off the slot base; a final jump skips the other arms.
fn emitEnumDispatchAtSp(self: *Emitter, ed: *const ast.EnumDecl) error{OutOfMemory}!void {
    const enum_name = self.source[ed.name.start..ed.name.end];
    const payload = self.enumHasPayload(ed);
    var end_patches: std.ArrayList(usize) = .empty;
    defer end_patches.deinit(self.allocator);
    for (ed.variants, 0..) |v, ti| {
        // @as: variant count is bounded by the u8 tag (§3.6).
        const tag: u16 = @intCast(ti);
        if (payload) {
            try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.r2); // r2 = slot ptr
            try class.emitByteLoadAtOffset(self, Reg.r2, 0, Reg.r1); // r1 = tag
        } else {
            try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.r1); // r1 = tag word
        }
        try isa.cmpRegImm(self, Reg.r1, tag);
        const next = try isa.emitJumpPlaceholder(self, Op.jne_addr);
        const variant_name = self.source[v.name.start..v.name.end];
        try printLiteral(self, try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ enum_name, variant_name }));
        if (v.payload.len > 0) {
            try printLiteral(self, "(");
            for (v.payload, 0..) |pf, j| {
                if (j > 0) try printLiteral(self, ", ");
                // Payload fields read off the slot base parked at `[sp]`,
                // at the variant's per-field offset (past the tag byte).
                try emitPrintField(self, pf.type_ann.*, self.variantFieldOffset(v, j));
            }
            try printLiteral(self, ")");
        }
        try end_patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jmp_addr));
        try isa.patchJumpTo(self, next, try self.currentOffset());
    }
    const end = try self.currentOffset();
    for (end_patches.items) |p| try isa.patchJumpTo(self, p, end);
}

/// Render struct `sname` (base address in `acu`) as
/// `Name { f1: v1, f2: v2 }`. Each field prints per its type; nested
/// structs recurse. The base is parked on the stack across the field
/// prints (the `print_*` syscalls + recursion churn registers but
/// leave `sp` alone), and reloaded per field.
fn emitPrintStruct(self: *Emitter, sname: []const u8) error{OutOfMemory}!void {
    const sd = self.struct_decls.get(sname).?;
    try isa.pushReg(self, Reg.acu); // park base at [sp]

    try printLiteral(self, try std.fmt.allocPrint(self.arena, "{s} {{ ", .{sname}));

    var fo: u16 = 0;
    for (sd.fields, 0..) |f, i| {
        if (i > 0) try printLiteral(self, ", ");
        const fname = self.source[f.name.start..f.name.end];
        try printLiteral(self, try std.fmt.allocPrint(self.arena, "{s}: ", .{fname}));
        try emitPrintField(self, f.type_ann.*, fo);
        fo += self.widthOfTypeAnn(f.type_ann.*);
    }

    try printLiteral(self, " }");
    try isa.addImmToReg(self, 2, Reg.sp); // drop the parked base
}

/// Print the field at `fo` of the struct whose base is parked at `[sp]`.
/// Dispatches per type; a nested struct recurses (its base = base + fo).
fn emitPrintField(self: *Emitter, t: ast.TypeAnn, fo: u16) error{OutOfMemory}!void {
    try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.r1); // r1 = parked base
    if (self.structNameOfTypeAnn(t)) |sub| {
        try isa.movRegToReg(self, Reg.r1, Reg.acu);
        if (fo != 0) try isa.addImmToReg(self, fo, Reg.acu); // acu = nested base
        try emitPrintStruct(self, sub);
        return;
    }
    if (enumDeclOfTypeAnn(self, t)) |ed| {
        // Load the field's stored value — a slot pointer (payload-
        // carrying) or the bare tag byte — then dispatch off a fresh
        // park so payload fields re-address from the slot base.
        if (self.enumHasPayload(ed)) {
            try class.emitWordLoadAtOffset(self, Reg.r1, fo, Reg.acu);
        } else {
            try class.emitByteLoadAtOffset(self, Reg.r1, fo, Reg.acu);
        }
        try isa.pushReg(self, Reg.acu);
        try emitEnumDispatchAtSp(self, ed);
        try isa.addImmToReg(self, 2, Reg.sp);
        return;
    }
    if (isPrimNamed(self, t, "char")) {
        try class.emitByteLoadAtOffset(self, Reg.r1, fo, Reg.acu);
        try isa.sys(self, Sys.print_char);
    } else if (isPrimNamed(self, t, "fixed")) {
        try class.emitWordLoadAtOffset(self, Reg.r1, fo, Reg.acu);
        try isa.sys(self, Sys.print_fixed);
    } else if (isPrimNamed(self, t, "str")) {
        try class.emitWordLoadAtOffset(self, Reg.r1, fo, Reg.acu);
        try isa.sys(self, Sys.print_str);
    } else if (self.widthOfTypeAnn(t) == 1) {
        try class.emitByteLoadAtOffset(self, Reg.r1, fo, Reg.acu);
        // `i8` is the only signed byte type — sign-extend so `print_int`
        // (which formats a signed word) shows a negative value. `u8`
        // routes to the unsigned printer like any unsigned int.
        if (self.isPrimitiveTypeAnn(t, "i8")) try isa.signExtendByte(self, Reg.acu);
        try isa.sys(self, if (self.isPrimitiveTypeAnn(t, "u8")) Sys.print_uint else Sys.print_int);
    } else {
        try class.emitWordLoadAtOffset(self, Reg.r1, fo, Reg.acu);
        try isa.sys(self, if (self.isPrimitiveTypeAnn(t, "u16")) Sys.print_uint else Sys.print_int);
    }
}

/// Intern `text` and emit a `print_str` of it (the constant separators
/// + field labels in a struct rendering).
fn printLiteral(self: *Emitter, text: []const u8) error{OutOfMemory}!void {
    const id = try strings.internString(self, text);
    try strings.emitMovStringAddrToReg(self, id, Reg.acu);
    try isa.sys(self, Sys.print_str);
}

/// Whether `print` can render every field of `sname`. Supported:
/// scalars / bool / char / fixed (decimal/char/fixed), `str`, enums
/// (`Enum.Variant` + printable payload), and nested supported structs.
/// Rejected: array / tuple / `Vec` / class / reference / fn-ptr /
/// nullable — no default rendering yet. A type cycle (a struct / enum
/// reachable from itself) is rejected too — it has no finite rendering.
fn printSupported(self: *const Emitter, sname: []const u8) bool {
    var visited: std.ArrayList([]const u8) = .empty;
    defer visited.deinit(self.allocator);
    return printSupportedRec(self, sname, &visited) catch false;
}

/// Whether `print` can render every variant of `ed` (entry point — see
/// `enumPrintSupportedRec`).
fn enumPrintSupported(self: *const Emitter, ed: *const ast.EnumDecl) bool {
    var visited: std.ArrayList([]const u8) = .empty;
    defer visited.deinit(self.allocator);
    return enumPrintSupportedRec(self, ed, &visited) catch false;
}

// `visited` is the current type path (push on descent, pop on return), so
// a name reappearing on the path is a cycle — distinct from a diamond
// (the same type used by two sibling fields), which is fine.
fn printSupportedRec(self: *const Emitter, sname: []const u8, visited: *std.ArrayList([]const u8)) error{OutOfMemory}!bool {
    const sd = self.struct_decls.get(sname) orelse return false;
    for (visited.items) |seen| if (std.mem.eql(u8, seen, sname)) return false;
    try visited.append(self.allocator, sname);
    defer _ = visited.pop();
    for (sd.fields) |f| {
        if (!try fieldPrintSupportedRec(self, f.type_ann.*, visited)) return false;
    }
    return true;
}

/// A payload field is stored as a single register-width slot value (a
/// scalar, or a `str` / enum pointer), so a struct payload — which has
/// no inline slot representation — is rejected here, matching what
/// construction emits.
fn enumPrintSupportedRec(self: *const Emitter, ed: *const ast.EnumDecl, visited: *std.ArrayList([]const u8)) error{OutOfMemory}!bool {
    const name = self.source[ed.name.start..ed.name.end];
    for (visited.items) |seen| if (std.mem.eql(u8, seen, name)) return false;
    try visited.append(self.allocator, name);
    defer _ = visited.pop();
    for (ed.variants) |v| {
        for (v.payload) |pf| {
            if (self.structNameOfTypeAnn(pf.type_ann.*) != null) return false;
            if (!try fieldPrintSupportedRec(self, pf.type_ann.*, visited)) return false;
        }
    }
    return true;
}

fn fieldPrintSupportedRec(self: *const Emitter, t: ast.TypeAnn, visited: *std.ArrayList([]const u8)) error{OutOfMemory}!bool {
    if (t != .named) return false; // array / tuple / vec / reference / fn / nullable
    const name = self.source[t.named.name.start..t.named.name.end];
    if (self.struct_decls.contains(name)) return printSupportedRec(self, name, visited);
    if (self.enum_decls.get(name)) |ed| return enumPrintSupportedRec(self, ed, visited);
    if (self.class_decls.contains(name)) return false;
    return true; // a primitive (i8/u8/i16/u16/bool/char/fixed/str)
}

fn enumDeclOfTypeAnn(self: *const Emitter, t: ast.TypeAnn) ?*const ast.EnumDecl {
    if (t != .named) return null;
    return self.enum_decls.get(self.source[t.named.name.start..t.named.name.end]);
}

fn isPrimNamed(self: *const Emitter, t: ast.TypeAnn, name: []const u8) bool {
    return t == .named and std.mem.eql(u8, self.source[t.named.name.start..t.named.name.end], name);
}
