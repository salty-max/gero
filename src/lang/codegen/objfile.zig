const std = @import("std");
const object = @import("object.zig");

const Fragment = object.Fragment;

/// Identifies a fragment file and guards against feeding the cache
/// something else.
pub const magic = "GROB";

/// Bumped whenever the encoding below changes shape. A cache entry
/// written by a different version is discarded rather than decoded,
/// so an older build's fragments can never be spliced into a newer
/// compiler's image.
pub const format_version: u16 = 2;

/// A fragment file that could not be decoded. Every variant means the
/// same thing to a caller — treat the cache entry as a miss.
pub const DecodeError = error{
    /// Not a fragment file, or truncated before the header.
    BadMagic,
    /// Written by a different `format_version`.
    VersionMismatch,
    /// Ended mid-record.
    Truncated,
    /// A field held a value the format cannot represent.
    Malformed,
};

/// Serialize `fragments` into a self-describing byte buffer, allocated
/// through `allocator`.
pub fn encode(allocator: std.mem.Allocator, fragments: []const Fragment) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, magic);
    try putU16(allocator, &out, format_version);
    try putU32(allocator, &out, @intCast(fragments.len));

    for (fragments) |f| try encodeFragment(allocator, &out, f);
    return out.toOwnedSlice(allocator);
}

/// Append one fragment's record.
fn encodeFragment(allocator: std.mem.Allocator, out: *std.ArrayList(u8), f: Fragment) !void {
    try putBytes(allocator, out, f.symbol);
    try putU16(allocator, out, f.module);
    if (f.bank) |b| {
        try out.append(allocator, 1);
        try out.append(allocator, b);
    } else {
        try out.append(allocator, 0);
        try out.append(allocator, 0);
    }
    try putBytes(allocator, out, f.bytes);

    try putU32(allocator, out, @intCast(f.relocs.len));
    for (f.relocs) |r| {
        try putU32(allocator, out, @intCast(r.patch_offset));
        try putU32(allocator, out, @intCast(r.target_offset));
    }

    try putU32(allocator, out, @intCast(f.refs.len));
    for (f.refs) |r| {
        try out.append(allocator, @intFromEnum(r.kind));
        try putU32(allocator, out, @intCast(r.patch_offset));
        try putBytes(allocator, out, r.name);
        try putU32(allocator, out, r.span.start);
        try putU32(allocator, out, r.span.end);
    }

    try putU32(allocator, out, @intCast(f.strings.len));
    for (f.strings) |sr| {
        try putU32(allocator, out, @intCast(sr.patch_offset));
        try putBytes(allocator, out, sr.bytes);
    }

    try putU32(allocator, out, @intCast(f.defines.len));
    for (f.defines) |d| {
        try putBytes(allocator, out, d.name);
        try putU32(allocator, out, @intCast(d.offset));
    }

    try putU32(allocator, out, @intCast(f.lines.len));
    for (f.lines) |l| {
        try putU32(allocator, out, @intCast(l.start_offset));
        try putU32(allocator, out, @intCast(l.end_offset));
        try putU32(allocator, out, l.source_offset);
    }
}

/// Rebuild the fragments `encode` wrote. Everything returned is
/// allocated through `arena`, so it outlives `blob`.
pub fn decode(arena: std.mem.Allocator, blob: []const u8) (DecodeError || std.mem.Allocator.Error)![]const Fragment {
    var r: Reader = .{ .blob = blob };
    if (blob.len < magic.len or !std.mem.eql(u8, blob[0..magic.len], magic)) return error.BadMagic;
    r.pos = magic.len;
    if (try r.readU16() != format_version) return error.VersionMismatch;

    const count = try r.readU32();
    var out: std.ArrayList(Fragment) = .empty;
    var i: u32 = 0;
    while (i < count) : (i += 1) try out.append(arena, try decodeFragment(arena, &r));
    return out.toOwnedSlice(arena);
}

/// Read one fragment's record.
fn decodeFragment(arena: std.mem.Allocator, r: *Reader) (DecodeError || std.mem.Allocator.Error)!Fragment {
    const symbol = try r.readBytes(arena);
    const module = try r.readU16();
    const has_bank = try r.readByte();
    const bank_value = try r.readByte();
    return .{
        .symbol = symbol,
        .module = module,
        .bank = if (has_bank == 1) bank_value else null,
        .bytes = try r.readBytes(arena),
        .relocs = try decodeRelocs(arena, r),
        .refs = try decodeRefs(arena, r),
        .strings = try decodeStrings(arena, r),
        .defines = try decodeDefines(arena, r),
        .lines = try decodeLines(arena, r),
    };
}

fn decodeLines(arena: std.mem.Allocator, r: *Reader) (DecodeError || std.mem.Allocator.Error)![]const object.LineSpan {
    const out = try arena.alloc(object.LineSpan, try r.readU32());
    for (out) |*l| l.* = .{
        .start_offset = try r.readU32(),
        .end_offset = try r.readU32(),
        .source_offset = try r.readU32(),
    };
    return out;
}

fn decodeRelocs(arena: std.mem.Allocator, r: *Reader) (DecodeError || std.mem.Allocator.Error)![]const object.Reloc {
    const out = try arena.alloc(object.Reloc, try r.readU32());
    for (out) |*rel| rel.* = .{
        .patch_offset = try r.readU32(),
        .target_offset = try r.readU32(),
    };
    return out;
}

fn decodeRefs(arena: std.mem.Allocator, r: *Reader) (DecodeError || std.mem.Allocator.Error)![]const object.SymbolRef {
    const out = try arena.alloc(object.SymbolRef, try r.readU32());
    for (out) |*ref| {
        const tag = try r.readByte();
        if (tag > @intFromEnum(object.RefKind.vtable)) return error.Malformed;
        ref.* = .{
            // safety: bounded against the enum's last tag above.
            .kind = @enumFromInt(tag),
            .patch_offset = try r.readU32(),
            .name = try r.readBytes(arena),
            .span = .{ .start = try r.readU32(), .end = try r.readU32() },
        };
    }
    return out;
}

fn decodeStrings(arena: std.mem.Allocator, r: *Reader) (DecodeError || std.mem.Allocator.Error)![]const object.StringRef {
    const out = try arena.alloc(object.StringRef, try r.readU32());
    for (out) |*sr| sr.* = .{
        .patch_offset = try r.readU32(),
        .bytes = try r.readBytes(arena),
    };
    return out;
}

fn decodeDefines(arena: std.mem.Allocator, r: *Reader) (DecodeError || std.mem.Allocator.Error)![]const object.Definition {
    const out = try arena.alloc(object.Definition, try r.readU32());
    for (out) |*d| d.* = .{
        .name = try r.readBytes(arena),
        .offset = try r.readU32(),
    };
    return out;
}

/// Cursor over an encoded blob. Every read is bounds-checked, so a
/// truncated or corrupt file fails rather than reading past the end.
const Reader = struct {
    blob: []const u8,
    pos: usize = 0,

    fn readByte(self: *Reader) DecodeError!u8 {
        if (self.pos >= self.blob.len) return error.Truncated;
        defer self.pos += 1;
        return self.blob[self.pos];
    }

    fn readU16(self: *Reader) DecodeError!u16 {
        const lo: u16 = try self.readByte();
        const hi: u16 = try self.readByte();
        return lo | (hi << 8);
    }

    fn readU32(self: *Reader) DecodeError!u32 {
        const a: u32 = try self.readU16();
        const b: u32 = try self.readU16();
        return a | (b << 16);
    }

    fn readBytes(self: *Reader, arena: std.mem.Allocator) (DecodeError || std.mem.Allocator.Error)![]const u8 {
        const len = try self.readU32();
        if (self.pos + len > self.blob.len) return error.Truncated;
        defer self.pos += len;
        return arena.dupe(u8, self.blob[self.pos..][0..len]);
    }
};

fn putU16(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u16) !void {
    // safety: u16 → 2 bytes by definition; both casts are byte-masks.
    try out.append(allocator, @intCast(value & 0xFF));
    try out.append(allocator, @intCast(value >> 8));
}

fn putU32(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    // safety: u32 → two u16 halves; the mask and shift both fit.
    try putU16(allocator, out, @intCast(value & 0xFFFF));
    try putU16(allocator, out, @intCast(value >> 16));
}

fn putBytes(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    try putU32(allocator, out, @intCast(value.len));
    try out.appendSlice(allocator, value);
}
