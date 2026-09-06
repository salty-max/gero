const std = @import("std");
const codegen = @import("../codegen.zig");
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

/// An intra-fragment jump, rebased to its fragment.
pub const Reloc = struct {
    patch_offset: usize,
    target_offset: usize,
};

/// What a `SymbolRef`'s address slot is waiting for.
pub const RefKind = enum {
    /// A `call` to a named def, method, or specialization.
    call,
    /// The cross-bank trampoline, whose address the link step sets.
    trampoline,
    /// A closure-creation site's fn_ptr slot, naming a lambda body.
    lambda,
    /// A constructor's vtable slot, naming a class.
    vtable,
    /// The Q16.16 multiply helper, whose address the link step sets.
    fixed_mul,
    /// The Q16.16 divide helper.
    fixed_div,
};

/// An address slot naming something outside this fragment. Names
/// rather than addresses are what let a fragment be reused at a
/// different address on a later build.
pub const SymbolRef = struct {
    kind: RefKind,
    patch_offset: usize,
    /// Symbol named. Empty for `trampoline`, which names nothing.
    name: []const u8,
    /// Call-site span, so a missing callee still blames source.
    span: ast.Span,
};

/// A string load, rebased to its fragment. The pool is a link product,
/// so the reference travels as the string's bytes rather than a pool
/// index that a later build would number differently.
pub const StringRef = struct {
    patch_offset: usize,
    bytes: []const u8,
};

/// A symbol defined inside the fragment — the fragment's own label,
/// plus any lambda body emitted alongside it. Restoring these on
/// splice is what lets references from elsewhere resolve into it.
pub const Definition = struct {
    name: []const u8,
    offset: usize,
};

/// One symbol's relocatable code: its bytes plus every reference that
/// leaves them, all offsets relative to `bytes`.
///
/// Emission writes every symbol into one shared buffer, but nothing
/// inside a symbol's range names an address — intra-body jumps are
/// relocations over buffer offsets, and calls, closures, vtable slots,
/// and string loads all carry names or content. Rebasing those offsets
/// so the range starts at zero is what makes the range position-
/// independent, and so reusable at a different address on a later build.
pub const Fragment = struct {
    symbol: []const u8,
    module: u16,
    bank: ?u8,
    bytes: []const u8,
    relocs: []const Reloc,
    refs: []const SymbolRef,
    strings: []const StringRef,
    defines: []const Definition,
};

/// Slice `emitter`'s buffers into one fragment per recorded span,
/// partitioning every relocation, patch, and symbol definition by the
/// range it falls in. Everything returned is allocated through
/// `arena`, so the fragments outlive the emitter's buffers.
///
/// A reference outside every span belongs to a link product — the
/// string pool, a vtable, the trampoline body — which the link step
/// emits itself rather than replaying from cache, so it has no
/// fragment.
pub fn extract(arena: std.mem.Allocator, emitter: *const Emitter) ![]const Fragment {
    var out: std.ArrayList(Fragment) = .empty;
    for (emitter.fragment_spans.items) |s| {
        const buf: []const u8 = if (s.bank) |b|
            if (emitter.banks.getPtr(b)) |bl| bl.items else continue
        else
            emitter.code.items;
        if (s.end > buf.len or s.start > s.end) continue;

        try out.append(arena, .{
            .symbol = try arena.dupe(u8, s.symbol),
            .module = s.module,
            .bank = s.bank,
            .bytes = try arena.dupe(u8, buf[s.start..s.end]),
            .relocs = try collectRelocs(arena, emitter, s),
            .refs = try collectRefs(arena, emitter, s),
            .strings = try collectStrings(arena, emitter, s),
            .defines = try collectDefines(arena, emitter, s),
        });
    }
    return out.toOwnedSlice(arena);
}

fn collectRelocs(arena: std.mem.Allocator, emitter: *const Emitter, s: Span) ![]const Reloc {
    var out: std.ArrayList(Reloc) = .empty;
    for (emitter.relocations.items) |r| {
        if (!sameBank(r.bank, s.bank) or !within(r.patch_offset, s)) continue;
        try out.append(arena, .{
            .patch_offset = r.patch_offset - s.start,
            .target_offset = r.target_offset - s.start,
        });
    }
    return out.toOwnedSlice(arena);
}

fn collectRefs(arena: std.mem.Allocator, emitter: *const Emitter, s: Span) ![]const SymbolRef {
    var out: std.ArrayList(SymbolRef) = .empty;
    for (emitter.call_patches.items) |p| {
        if (!sameBank(p.bank, s.bank) or !within(p.code_offset, s)) continue;
        try out.append(arena, switch (p.target) {
            .fn_name => |n| .{
                .kind = .call,
                .patch_offset = p.code_offset - s.start,
                .name = try arena.dupe(u8, n),
                .span = p.span,
            },
            .trampoline => .{
                .kind = .trampoline,
                .patch_offset = p.code_offset - s.start,
                .name = "",
                .span = p.span,
            },
            .fixed_mul => .{
                .kind = .fixed_mul,
                .patch_offset = p.code_offset - s.start,
                .name = "",
                .span = p.span,
            },
            .fixed_div => .{
                .kind = .fixed_div,
                .patch_offset = p.code_offset - s.start,
                .name = "",
                .span = p.span,
            },
        });
    }
    for (emitter.lambda_patches.items) |p| {
        if (!sameBank(p.bank, s.bank) or !within(p.code_offset, s)) continue;
        try out.append(arena, .{
            .kind = .lambda,
            .patch_offset = p.code_offset - s.start,
            .name = try arena.dupe(u8, p.label),
            .span = .{ .start = 0, .end = 0 },
        });
    }
    for (emitter.vtable_patches.items) |p| {
        if (!sameBank(p.bank, s.bank) or !within(p.code_offset, s)) continue;
        try out.append(arena, .{
            .kind = .vtable,
            .patch_offset = p.code_offset - s.start,
            .name = try arena.dupe(u8, p.class_name),
            .span = .{ .start = 0, .end = 0 },
        });
    }
    return out.toOwnedSlice(arena);
}

fn collectStrings(arena: std.mem.Allocator, emitter: *const Emitter, s: Span) ![]const StringRef {
    var out: std.ArrayList(StringRef) = .empty;
    for (emitter.string_patches.items) |p| {
        if (!sameBank(p.bank, s.bank) or !within(p.code_offset, s)) continue;
        if (p.string_id >= emitter.strings.items.len) continue;
        try out.append(arena, .{
            .patch_offset = p.code_offset - s.start,
            .bytes = try arena.dupe(u8, emitter.strings.items[p.string_id].bytes),
        });
    }
    return out.toOwnedSlice(arena);
}

fn collectDefines(arena: std.mem.Allocator, emitter: *const Emitter, s: Span) ![]const Definition {
    var out: std.ArrayList(Definition) = .empty;
    var it = emitter.fn_addresses.iterator();
    while (it.next()) |e| {
        const ref = e.value_ptr.*;
        if (!sameBank(ref.bank, s.bank) or !within(ref.offset, s)) continue;
        try out.append(arena, .{
            .name = try arena.dupe(u8, e.key_ptr.*),
            .offset = ref.offset - s.start,
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

/// Append `f`'s bytes to the buffer it belongs in and re-record every
/// reference against its new position — the inverse of `extract`.
///
/// This is what a cache hit does instead of lowering a body: the
/// fragment's relocations, symbolic references, and string loads all
/// re-enter the emitter's normal patch lists, so the link step resolves
/// a spliced fragment exactly as it resolves a freshly emitted one.
pub fn splice(emitter: *Emitter, f: Fragment) !void {
    const saved_bank = emitter.current_bank;
    emitter.current_bank = f.bank;
    defer emitter.current_bank = saved_bank;

    const base = try emitter.currentOffset();
    for (f.bytes) |b| try emitter.emitByte(b);

    try spliceDefines(emitter, f, base);
    try spliceRelocs(emitter, f, base);
    try spliceRefs(emitter, f, base);
    try spliceStrings(emitter, f, base);

    try emitter.noteFragment(f.symbol, f.module, f.bank, base, base + f.bytes.len);
}

/// Re-register the symbols the fragment defines, so references from
/// elsewhere resolve into it.
fn spliceDefines(emitter: *Emitter, f: Fragment, base: usize) !void {
    for (f.defines) |d| {
        const name = try emitter.arena.dupe(u8, d.name);
        try emitter.fn_addresses.put(emitter.arena, name, .{
            .bank = f.bank,
            .offset = base + d.offset,
        });
    }
}

fn spliceRelocs(emitter: *Emitter, f: Fragment, base: usize) !void {
    for (f.relocs) |r| {
        try emitter.relocations.append(emitter.allocator, .{
            .bank = f.bank,
            .patch_offset = base + r.patch_offset,
            .target_offset = base + r.target_offset,
        });
    }
}

fn spliceRefs(emitter: *Emitter, f: Fragment, base: usize) !void {
    for (f.refs) |r| switch (r.kind) {
        .call, .trampoline, .fixed_mul, .fixed_div => try emitter.call_patches.append(emitter.allocator, .{
            .bank = f.bank,
            .code_offset = base + r.patch_offset,
            .target = switch (r.kind) {
                .trampoline => .trampoline,
                .fixed_mul => .fixed_mul,
                .fixed_div => .fixed_div,
                else => .{ .fn_name = try emitter.arena.dupe(u8, r.name) },
            },
            .span = r.span,
        }),
        .lambda => try emitter.lambda_patches.append(emitter.allocator, .{
            .bank = f.bank,
            .code_offset = base + r.patch_offset,
            .label = try emitter.arena.dupe(u8, r.name),
        }),
        .vtable => try emitter.vtable_patches.append(emitter.allocator, .{
            .bank = f.bank,
            .code_offset = base + r.patch_offset,
            .class_name = try emitter.arena.dupe(u8, r.name),
        }),
    };
}

/// Re-intern rather than carrying a pool index: the pool is a link
/// product, and this build numbers it for itself.
fn spliceStrings(emitter: *Emitter, f: Fragment, base: usize) !void {
    for (f.strings) |sr| {
        const id = try emitter.internString(sr.bytes);
        try emitter.string_patches.append(emitter.allocator, .{
            .bank = f.bank,
            .code_offset = base + sr.patch_offset,
            .string_id = id,
        });
    }
}
