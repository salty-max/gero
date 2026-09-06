const std = @import("std");
const codegen = @import("../codegen.zig");
const strings = @import("strings.zig");
const ast = @import("../ast.zig");

const Emitter = codegen.Emitter;

/// Byte range one symbol's emission occupied, recorded as it is
/// emitted. A def's range covers the lambda bodies emitted alongside
/// it, so a fragment holds everything that def brought into the image.
pub const Span = struct {
    /// Primary symbol label — the def, method, or specialization name.
    symbol: []const u8,
    /// Module that declares it, as a `SourceMap` file id.
    module: u16,
    /// Bank buffer holding the range, or `null` for the base image.
    bank: ?u8,
    /// Start of the range within that buffer.
    start: usize,
    /// One past the last byte.
    end: usize,
};

/// A relocation rebased to its fragment.
pub const Reloc = struct {
    patch_offset: usize,
    target_offset: usize,
};

/// An unresolved call, rebased to its fragment. `callee` is null for
/// the cross-bank trampoline, which the link step supplies.
pub const Call = struct {
    patch_offset: usize,
    callee: ?[]const u8,
    span: ast.Span,
};

/// An unresolved string load, rebased to its fragment. The pool is a
/// link product, so the reference travels as the string's bytes rather
/// than a pool index that a later build would number differently.
pub const StringRef = struct {
    patch_offset: usize,
    bytes: []const u8,
};

/// One symbol's relocatable code: its bytes plus every reference that
/// leaves them, all offsets relative to `bytes`.
///
/// Emission writes every symbol into one shared buffer, but nothing
/// inside a symbol's range names an address — intra-body jumps are
/// relocations over buffer offsets, calls carry names, and string
/// loads carry pool ids. Rebasing those offsets so the range starts at
/// zero is what makes the range position-independent, and so reusable
/// at a different address on a later build.
pub const Fragment = struct {
    symbol: []const u8,
    module: u16,
    bank: ?u8,
    bytes: []const u8,
    relocs: []const Reloc,
    calls: []const Call,
    string_refs: []const StringRef,
};

/// Slice `emitter`'s buffers into one fragment per recorded span,
/// partitioning relocations, call patches, and string patches by the
/// range they fall in. Allocated through `arena`; the returned bytes
/// alias the emitter's buffers.
///
/// A reference outside every span belongs to a link product — the
/// string pool, a vtable, the trampoline — which the link step emits
/// itself rather than replaying from cache, so it has no fragment.
pub fn extract(arena: std.mem.Allocator, emitter: *const Emitter) ![]const Fragment {
    var out: std.ArrayList(Fragment) = .empty;
    for (emitter.fragment_spans.items) |s| {
        const buf: []const u8 = if (s.bank) |b|
            if (emitter.banks.getPtr(b)) |bl| bl.items else continue
        else
            emitter.code.items;
        if (s.end > buf.len or s.start > s.end) continue;

        var relocs: std.ArrayList(Reloc) = .empty;
        for (emitter.relocations.items) |r| {
            if (!sameBank(r.bank, s.bank) or !within(r.patch_offset, s)) continue;
            try relocs.append(arena, .{
                .patch_offset = r.patch_offset - s.start,
                .target_offset = r.target_offset - s.start,
            });
        }

        var calls: std.ArrayList(Call) = .empty;
        for (emitter.call_patches.items) |p| {
            if (!sameBank(p.bank, s.bank) or !within(p.code_offset, s)) continue;
            try calls.append(arena, .{
                .patch_offset = p.code_offset - s.start,
                .callee = switch (p.target) {
                    .fn_name => |n| try arena.dupe(u8, n),
                    .trampoline => null,
                },
                .span = p.span,
            });
        }

        var string_refs: std.ArrayList(StringRef) = .empty;
        for (emitter.string_patches.items) |p| {
            if (!sameBank(p.bank, s.bank) or !within(p.code_offset, s)) continue;
            if (p.string_id >= emitter.strings.items.len) continue;
            try string_refs.append(arena, .{
                .patch_offset = p.code_offset - s.start,
                .bytes = try arena.dupe(u8, emitter.strings.items[p.string_id].bytes),
            });
        }

        try out.append(arena, .{
            .symbol = try arena.dupe(u8, s.symbol),
            .module = s.module,
            .bank = s.bank,
            .bytes = try arena.dupe(u8, buf[s.start..s.end]),
            .relocs = relocs.items,
            .calls = calls.items,
            .string_refs = string_refs.items,
        });
    }
    return out.toOwnedSlice(arena);
}

fn within(offset: usize, s: Span) bool {
    return offset >= s.start and offset < s.end;
}

fn sameBank(a: ?u8, b: ?u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
}
