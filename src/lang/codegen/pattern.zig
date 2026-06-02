const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const opcodes = @import("opcodes.zig");
const isa = @import("isa.zig");

const Emitter = codegen.Emitter;
const Op = opcodes.Op;
const Reg = opcodes.Reg;

/// Emit the per-pattern test against the scrutinee value sitting
/// in `acu`. Match success falls through to the caller (which
/// then emits the body); failure pushes a forward-jump patch
/// onto `skip_patches`. The caller resolves every patch to the
/// post-body offset.
pub fn emitPatternTest(
    self: *Emitter,
    pat: ast.Pattern,
    skip_patches: *std.ArrayList(usize),
) !void {
    switch (pat) {
        .wildcard => {
            // Always matches — emit nothing.
        },
        .ident => |ip| {
            // Bind the value to a local slot. Always matches.
            const name = self.source[ip.name.start..ip.name.end];
            const dup = try self.arena.dupe(u8, name);
            const ofs = try self.allocLocal(dup);
            try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, ofs);
        },
        .int_lit, .char_lit, .bool_lit, .nil_lit, .range_pattern, .or_pattern => try emitLeafTest(self, pat, skip_patches),
        .variant_pattern => |vp| {
            // Payload binders don't affect the tag test — they're
            // extracted into locals by the match lowerer once the tag
            // matches. The test is the tag comparison either way.
            const path = self.source[vp.path.start..vp.path.end];
            const dot = std.mem.indexOfScalar(u8, path, '.') orelse {
                try self.diagFatal(vp.span, "E_CODEGEN_BAD_VARIANT_PATH", "codegen: variant pattern must be `EnumName.Variant`");
                return;
            };
            const enum_name = path[0..dot];
            const variant_name = path[dot + 1 ..];
            const tag = self.variantTag(enum_name, variant_name) orelse {
                try self.diagFatal(vp.span, "E_CODEGEN_UNDEFINED_VARIANT", "codegen: unknown enum variant in match pattern");
                return;
            };
            try isa.cmpRegImm(self, Reg.acu, tag);
            try skip_patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jne_addr));
        },
        else => try self.unsupported(pat.span(), "this pattern shape"),
    }
}

/// Test a scalar value sitting in `acu` against a leaf pattern — a
/// literal (`42` / `'A'` / `true` / `nil`), a range, or an or-pattern of
/// those. A mismatch pushes a forward-skip patch onto `skip_patches`;
/// a match falls through. Shared by `emitPatternTest` (match) and the
/// destructuring matcher (`destructure.zig`).
pub fn emitLeafTest(self: *Emitter, pat: ast.Pattern, skip_patches: *std.ArrayList(usize)) error{OutOfMemory}!void {
    switch (pat) {
        .int_lit => |lit| {
            // @as: parser holds int_lit.value as i32; literals fit i16 by typecheck rule.
            const trimmed: i16 = @truncate(lit.value);
            // safety: i16 → u16 bit pattern preserved.
            const v: u16 = @bitCast(trimmed);
            try isa.cmpRegImm(self, Reg.acu, v);
            try skip_patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jne_addr));
        },
        .char_lit => |c| {
            try isa.cmpRegImm(self, Reg.acu, c.value);
            try skip_patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jne_addr));
        },
        .bool_lit => |b| {
            const v: u16 = if (b.value) 1 else 0;
            try isa.cmpRegImm(self, Reg.acu, v);
            try skip_patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jne_addr));
        },
        .nil_lit => {
            try isa.cmpRegImm(self, Reg.acu, 0);
            try skip_patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jne_addr));
        },
        .range_pattern => |rp| {
            // Lower `start..end` as: cmp acu, start; jlt skip;
            //                       cmp acu, end;   j(g[te]) skip.
            // Endpoints must be compile-time integer literals so they
            // emit as immediate operands.
            if (rp.start.* != .int_lit or rp.end.* != .int_lit) {
                try self.unsupported(rp.span, "non-literal range pattern endpoints");
                return;
            }
            // @as: parser holds int_lit.value as i32; range bounds fit i16 by spec.
            const start_i16: i16 = @truncate(rp.start.int_lit.value);
            // safety: i16 → u16 keeps the two's-complement bit pattern.
            const start_v: u16 = @bitCast(start_i16);
            // @as: same i32 → i16 truncation for the end bound.
            const end_i16: i16 = @truncate(rp.end.int_lit.value);
            // safety: i16 → u16 keeps the two's-complement bit pattern.
            const end_v: u16 = @bitCast(end_i16);
            try isa.cmpRegImm(self, Reg.acu, start_v);
            try skip_patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jlt_addr));
            try isa.cmpRegImm(self, Reg.acu, end_v);
            const above_bound_op: u8 = if (rp.inclusive) Op.jgt_addr else Op.jge_addr;
            try skip_patches.append(self.allocator, try isa.emitJumpPlaceholder(self, above_bound_op));
        },
        .or_pattern => |op_| {
            // Each alt emits its own cmp + branch. A match jumps OVER the
            // remaining alts to the body; a non-match falls through to the
            // next alt. After the last alt, a non-match jumps to the
            // shared skip target. The scrutinee stays in `acu` throughout,
            // so each alt re-tests the same value.
            var match_patches: std.ArrayList(usize) = .empty;
            defer match_patches.deinit(self.allocator);
            for (op_.alts) |alt| {
                var alt_skip: std.ArrayList(usize) = .empty;
                defer alt_skip.deinit(self.allocator);
                try emitLeafTest(self, alt.*, &alt_skip);
                try match_patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jmp_addr));
                const after_alt = try self.currentOffset();
                for (alt_skip.items) |p| try isa.patchJumpTo(self, p, after_alt);
            }
            try skip_patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jmp_addr));
            const body_offset = try self.currentOffset();
            for (match_patches.items) |p| try isa.patchJumpTo(self, p, body_offset);
        },
        else => try self.unsupported(pat.span(), "non-leaf pattern in leaf test"),
    }
}
