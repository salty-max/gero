// Inline-assembly lowering (§4.11). An `asm "<instruction>"` statement
// emits one bytecode instruction directly. Each `{name}` operand resolves
// to the named local / parameter's `[fp ± ofs]` slot; the substituted
// instruction is assembled through the asm layer and its bytes emitted in
// place. No labels, banks, or control flow — one instruction, full stop.

const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");

const Emitter = codegen.Emitter;

/// Lower `asm "<instruction>"`: substitute `{name}` operands, assemble the
/// single instruction, and emit its bytes. Any failure (unknown operand,
/// malformed instruction, no matching opcode form) is a fatal
/// `E_CODEGEN_INLINE_ASM` pointing at the statement.
pub fn emitInlineAsm(self: *Emitter, stmt: ast.AsmStmt) error{OutOfMemory}!void {
    // `body` spans the string literal including its quotes — strip them.
    const raw = self.source[stmt.body.start..stmt.body.end];
    const body = if (raw.len >= 2 and raw[0] == '"') raw[1 .. raw.len - 1] else raw;

    var sub: std.ArrayList(u8) = .empty;
    defer sub.deinit(self.allocator);
    var i: usize = 0;
    while (i < body.len) {
        if (body[i] != '{') {
            try sub.append(self.allocator, body[i]);
            i += 1;
            continue;
        }
        const close = std.mem.indexOfScalarPos(u8, body, i + 1, '}') orelse
            return self.diagFatal(stmt.span, "E_CODEGEN_INLINE_ASM", "inline `asm` has an unclosed `{` operand reference");
        const name = body[i + 1 .. close];
        const ofs = localOffset(self, name) orelse {
            const msg = try std.fmt.allocPrint(self.diag_arena, "inline `asm` references `{s}`, which isn't a local or parameter in scope (§4.11)", .{name});
            return self.diagFatal(stmt.span, "E_CODEGEN_INLINE_ASM", msg);
        };
        // `[fp + $N]` / `[fp - $N]` — the slot holding the named value.
        // Asm offsets are `$`-prefixed hex (§asm spec).
        const op = if (ofs >= 0) blk: {
            // safety: a non-negative fp-offset fits u8.
            const slot: u8 = @intCast(ofs);
            break :blk try std.fmt.allocPrint(self.allocator, "[fp + ${x}]", .{slot});
        } else blk: {
            // safety: negating the i16-widened offset gives 1..128, fits u8.
            const wide: i16 = ofs;
            const slot: u8 = @intCast(-wide);
            break :blk try std.fmt.allocPrint(self.allocator, "[fp - ${x}]", .{slot});
        };
        defer self.allocator.free(op);
        try sub.appendSlice(self.allocator, op);
        i = close + 1;
    }
    // The asm parser is line-oriented — terminate the instruction.
    try sub.append(self.allocator, '\n');

    const result = try codegen.assembleInstruction(self.allocator, sub.items);
    defer self.allocator.free(result.bytes);
    defer self.allocator.free(result.errors);

    if (result.errors.len > 0) {
        const msg = try std.fmt.allocPrint(self.diag_arena, "inline `asm` did not assemble: {s} (§4.11)", .{result.errors[0].parse_error.message});
        return self.diagFatal(stmt.span, "E_CODEGEN_INLINE_ASM", msg);
    }
    // §4.11: exactly one instruction, no labels or directives — a
    // multi-instruction or label-bearing body would otherwise emit only
    // the last instruction and silently drop the rest.
    if (result.instruction_count != 1 or result.other_count != 0)
        return self.diagFatal(stmt.span, "E_CODEGEN_INLINE_ASM", "inline `asm` must be exactly one instruction — no labels, directives, or multiple instructions (§4.11)");

    for (result.bytes) |b| try self.emitByte(b);
}

/// fp-relative offset of `name` — a local first, then a parameter.
fn localOffset(self: *const Emitter, name: []const u8) ?i8 {
    if (self.locals.get(name)) |o| return o;
    if (self.params.get(name)) |o| return o;
    return null;
}
