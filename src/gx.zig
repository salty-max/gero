const std = @import("std");

// ---------- header constants (ISA §7.1) ----------

/// 4-byte ASCII magic at the top of every `.gx` archive.
pub const magic = [4]u8{ 'G', 'E', 'R', 'O' };

/// Format version stored in bytes 4-5 of the header — major in the
/// high byte, minor in the low. A loader rejects a higher major and
/// accepts a higher minor, so an additive change bumps the low byte.
///
/// `0x0004` added the chunked debug section (§7.3); `0x0003` the
/// `muls` opcode the debug overflow trap on `*` relies on.
pub const version: u16 = 0x0004;

/// Fixed header size in bytes — every archive starts with this many
/// bytes before the base image.
pub const header_size: usize = 16;

/// Per-bank disk size — 16 KiB, the size of the `0xC000..0xFEFF`
/// window in the address space. Each bank stored in the archive
/// consumes exactly this many bytes (zero-padded).
pub const bank_disk_size: usize = 0x4000;

/// Flag bit 0 — a bank pool follows the base image.
pub const flag_banked: u16 = 0x0001;
/// Flag bit 1 — a debug section follows the image and banks.
pub const flag_debug: u16 = 0x0002;
/// Bits any reader recognizes. Others must be `0`.
pub const flag_known_mask: u16 = flag_banked | flag_debug;

// ---------- writing ----------

/// Everything the container needs to lay out one archive. Both
/// front-ends fill this in; keeping the format in one place is what
/// stops the assembler and the compiler from stamping different
/// headers for the same ISA.
pub const Image = struct {
    /// Bytes loaded at `0x0000` at boot.
    base_image: []const u8,
    /// Address `ip` takes at boot.
    entry_point: u16,
    /// Bump-allocator base, or `0` for a program with no heap.
    heap_base: u16 = 0,
    /// How many of the **last** banks are battery-backed SRAM.
    sram_bank_count: u8 = 0,
    /// Bank contents indexed by bank number. A short or empty entry
    /// is zero-padded to the full window; the slice's length is the
    /// bank count.
    banks: []const []const u8 = &.{},
    /// Encoded debug section, or `null` for a release image.
    debug_section: ?[]const u8 = null,
};

/// Serialize `img` into a `.gx` archive. Caller owns the result.
pub fn build(allocator: std.mem.Allocator, img: Image) ![]u8 {
    const bank_count = img.banks.len;
    const banked_bytes = bank_count * bank_disk_size;
    const debug_bytes: usize = if (img.debug_section) |s| s.len else 0;

    const total = header_size + img.base_image.len + banked_bytes + debug_bytes;
    var out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);
    @memset(out, 0);

    var flags: u16 = 0;
    if (bank_count > 0) flags |= flag_banked;
    if (debug_bytes > 0) flags |= flag_debug;

    @memcpy(out[0..4], &magic);
    writeU16Le(out[4..6], version);
    writeU16Le(out[6..8], flags);
    writeU16Le(out[8..10], img.entry_point);
    // safety: the base image is capped at 64 KiB by the ISA's 16-bit
    // address space; banks live in their own segment.
    writeU16Le(out[10..12], @intCast(img.base_image.len));
    // safety: bank_count ≤ 256 by the u8 bank index.
    out[12] = @intCast(bank_count);
    out[13] = img.sram_bank_count;
    writeU16Le(out[14..16], img.heap_base);

    @memcpy(out[header_size..][0..img.base_image.len], img.base_image);

    var cursor: usize = header_size + img.base_image.len;
    for (img.banks) |bank| {
        const n = @min(bank.len, bank_disk_size);
        @memcpy(out[cursor..][0..n], bank[0..n]);
        cursor += bank_disk_size;
    }

    if (img.debug_section) |s| @memcpy(out[cursor..][0..s.len], s);
    return out;
}

/// Write `value` as 2 little-endian bytes into `dst`.
pub fn writeU16Le(dst: *[2]u8, value: u16) void {
    // safety: u16 → 2 bytes by definition; no truncation possible.
    dst[0] = @intCast(value & 0xFF);
    dst[1] = @intCast(value >> 8);
}

/// Read 2 little-endian bytes as a u16.
pub fn readU16Le(src: []const u8) u16 {
    // @as: widen each byte to u16 so the shift and OR build the word.
    return @as(u16, src[0]) | (@as(u16, src[1]) << 8);
}

// ---------- debug section (ISA §7.3) ----------

/// A debug section is a sequence of chunks, each `[u8 kind]
/// [u32le payload_len][payload]`. A reader skips a kind it does not
/// know, so a later table can be added without another format break —
/// which is what makes this shape worth freezing.
pub const ChunkKind = enum(u8) {
    /// `address → name`, for disassembly labels and debugger lookup.
    symbols = 0x01,
    /// Source paths the line table indexes into.
    files = 0x02,
    /// `address range → (file, line, column)`.
    lines = 0x03,
    _,
};

/// Bytes of chunk framing ahead of each payload.
pub const chunk_header_size: usize = 5;

/// Builds a debug section chunk by chunk. Chunks are written in the
/// order added; a reader must not depend on that order.
pub const DebugBuilder = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    /// An empty builder allocating through `allocator`.
    pub fn init(allocator: std.mem.Allocator) DebugBuilder {
        return .{ .allocator = allocator };
    }

    /// Release the section bytes built so far.
    pub fn deinit(self: *DebugBuilder) void {
        self.bytes.deinit(self.allocator);
    }

    /// Append one chunk wrapping `payload`. An empty payload is
    /// skipped — a chunk carrying no rows is noise for every reader.
    pub fn addChunk(self: *DebugBuilder, kind: ChunkKind, payload: []const u8) !void {
        if (payload.len == 0) return;
        try self.bytes.append(self.allocator, @intFromEnum(kind));
        var len_bytes: [4]u8 = undefined;
        // safety: a payload is bounded by the 64 KiB image it describes.
        std.mem.writeInt(u32, &len_bytes, @intCast(payload.len), .little);
        try self.bytes.appendSlice(self.allocator, &len_bytes);
        try self.bytes.appendSlice(self.allocator, payload);
    }

    /// The section so far, or `null` when no chunk carried anything —
    /// which leaves the has-debug flag clear rather than attaching an
    /// empty section.
    pub fn section(self: *const DebugBuilder) ?[]const u8 {
        return if (self.bytes.items.len == 0) null else self.bytes.items;
    }
};

// ---------- reading ----------

/// Why a debug section could not be read.
pub const DebugError = error{
    /// A chunk header or payload runs past the end of the section.
    TruncatedChunk,
    /// A chunk's payload is too short for the rows it declares.
    TruncatedPayload,
};

/// One chunk as it appears in the section.
pub const Chunk = struct {
    kind: ChunkKind,
    payload: []const u8,
};

/// Walk a debug section's chunks in order.
pub const ChunkIter = struct {
    bytes: []const u8,
    cursor: usize = 0,

    /// The next chunk, or `null` at the end of the section.
    pub fn next(self: *ChunkIter) DebugError!?Chunk {
        if (self.cursor >= self.bytes.len) return null;
        if (self.cursor + chunk_header_size > self.bytes.len) return error.TruncatedChunk;
        const kind: ChunkKind = @enumFromInt(self.bytes[self.cursor]);
        const len = std.mem.readInt(u32, self.bytes[self.cursor + 1 ..][0..4], .little);
        const start = self.cursor + chunk_header_size;
        if (start + len > self.bytes.len) return error.TruncatedChunk;
        self.cursor = start + len;
        return .{ .kind = kind, .payload = self.bytes[start..][0..len] };
    }
};

/// The payload of the first chunk of `kind`, or `null` when the
/// section carries none.
pub fn findChunk(bytes: []const u8, kind: ChunkKind) DebugError!?[]const u8 {
    var it: ChunkIter = .{ .bytes = bytes };
    while (try it.next()) |c| {
        if (c.kind == kind) return c.payload;
    }
    return null;
}
