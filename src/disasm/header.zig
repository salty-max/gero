/// Disassembler-side header decoder. Reads a `.gx` byte buffer,
/// validates the magic + version per ISA §7.1, slices the image
/// / banks / debug regions, and returns a `Header` value the rest
/// of the disasm can consume.
///
/// The VM has its own `parseGx` in `src/vm/loader.zig` doing the
/// same byte work — we just delegate to it and re-wrap the result
/// in a disasm-friendly shape. Keeping the function defined here
/// (rather than re-exporting raw `vm.parseGx`) preserves the
/// option to tighten the disasm checks in the future without
/// affecting the VM loader.
const std = @import("std");
const gero = @import("../gero.zig");

/// What flavor a symbol describes, per ISA §7.3.
pub const SymbolKind = enum(u8) {
    /// Code label — its bytes decode as instructions.
    label = 0,
    /// `data8` / `data16` block — its bytes are raw data, not
    /// code. The disasm switches to data-mode rendering when
    /// the cursor lands on one of these.
    data = 1,
    /// Anything past `1` is reserved — the disasm treats unknown
    /// kinds as `label` so the bytes still try to decode (fail-
    /// safe), but the field round-trips for forward compat.
    _,
};

/// One row of the debug-symbol table per ISA §7.3.
pub const Symbol = struct {
    address: u16,
    kind: SymbolKind,
    name: []const u8,
};

/// Parsed debug-symbol section — an `address → name` lookup for
/// the disasm printer. Borrows name bytes from the input blob.
pub const Symbols = struct {
    entries: []const Symbol,

    /// `null` when no symbol covers `addr`. Linear scan — the
    /// symbol count tops out at ~thousands per cart so binary
    /// search isn't worth the complexity for v0.1.
    pub fn lookup(self: Symbols, addr: u16) ?[]const u8 {
        for (self.entries) |e| if (e.address == addr) return e.name;
        return null;
    }

    /// Release the entries slice. The borrowed name bytes
    /// inside each entry are NOT freed — they remain valid as
    /// long as the caller's source buffer does.
    pub fn deinit(self: Symbols, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
    }
};

/// One file's worth of decoded header info + section slices, all
/// borrowed from the caller's `bytes` buffer.
pub const Header = struct {
    /// Cart version (`0x0001` for v0.1).
    version: u16,
    /// Bit-set per ISA §7.1 (bit 0 = banked, bit 1 = has-debug).
    flags: u16,
    /// `ip` value the VM seeds at boot.
    entry_point: u16,
    /// Bytes in the base image (excluding the 16-byte header,
    /// bank segments, and debug symbols).
    image_size: u16,
    /// Number of bank slots that follow the base image. Bank N is
    /// at archive offset `16 + image_size + N * 0x4000`.
    bank_count: u8,
    /// Number of trailing bank slots that are SRAM (battery-backed).
    sram_bank_count: u8,

    /// Slice of the base image bytes (length == `image_size`).
    image: []const u8,
    /// Concatenated bank bytes (length == `bank_count * 0x4000`).
    /// Empty when the cart is unbanked.
    banks: []const u8,
    /// Trailing debug-symbol bytes — opaque blob for v0.1.
    /// Empty when the cart has no debug symbols.
    debug: []const u8,

    /// `true` when the banked flag is set + at least one bank slot
    /// is declared.
    pub fn isBanked(self: Header) bool {
        return self.bank_count > 0;
    }

    /// `true` when the has-debug flag is set + the debug blob is
    /// non-empty.
    pub fn hasDebugSymbols(self: Header) bool {
        return self.debug.len > 0;
    }
};

/// Failure modes when reading a `.gx`. A superset of the VM's
/// `LoaderError` — the disasm exposes them as one unified set so
/// `gero disasm` can map them to E-codes downstream.
pub const DecodeError = gero.vm.LoaderError;

/// Failures specific to the optional debug-symbol section.
pub const SymbolsError = error{
    /// Section length doesn't fit the declared `symbol_count`.
    TruncatedSymbolSection,
    OutOfMemory,
};

/// Parse the debug-symbol blob attached to a `.gx` per ISA §7.3.
/// Returns an empty `Symbols` if the cart has no symbol section.
/// Caller owns the returned entries slice — release via
/// `Symbols.deinit`.
pub fn parseSymbols(allocator: std.mem.Allocator, debug_bytes: []const u8) SymbolsError!Symbols {
    if (debug_bytes.len == 0) return .{ .entries = &.{} };
    if (debug_bytes.len < 2) return error.TruncatedSymbolSection;

    // @as: widen each u8 byte to u16 so the OR / shift produces a u16 count.
    const count: u16 = @as(u16, debug_bytes[0]) | (@as(u16, debug_bytes[1]) << 8);
    var entries = try allocator.alloc(Symbol, count);
    errdefer allocator.free(entries);

    var cursor: usize = 2;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (cursor + 4 > debug_bytes.len) return error.TruncatedSymbolSection;
        // @as: widen each u8 byte to u16 for the LE u16 read.
        const addr: u16 = @as(u16, debug_bytes[cursor]) | (@as(u16, debug_bytes[cursor + 1]) << 8);
        const kind: SymbolKind = @enumFromInt(debug_bytes[cursor + 2]);
        const name_len: usize = debug_bytes[cursor + 3];
        cursor += 4;
        if (cursor + name_len > debug_bytes.len) return error.TruncatedSymbolSection;
        entries[i] = .{ .address = addr, .kind = kind, .name = debug_bytes[cursor..][0..name_len] };
        cursor += name_len;
    }
    return .{ .entries = entries };
}

/// Parse `bytes` as a `.gx` archive. Strict: rejects unknown
/// flag bits and any version != `0x0001`. The returned slices
/// borrow from the input buffer.
pub fn parse(bytes: []const u8) DecodeError!Header {
    const loaded = try gero.vm.parseGx(bytes);

    return .{
        .version = loaded.header.version,
        .flags = loaded.header.flags,
        .entry_point = loaded.header.entry_point,
        .image_size = loaded.header.image_size,
        .bank_count = loaded.header.bank_count,
        .sram_bank_count = loaded.header.sram_bank_count,
        .image = loaded.image,
        .banks = loaded.banks,
        .debug = loaded.debug,
    };
}
