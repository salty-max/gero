/// Symbol table for the asm codegen — accumulates label
/// addresses, `const` values, struct-field offsets, and
/// `data8`/`data16` data-symbol addresses as the codegen pass
/// walks statements. The parser's `ConstantTable` (in `expr.zig`)
/// handles parse-time refs to constants and struct fields; this
/// table extends with the address-bearing entries codegen needs.
const std = @import("std");
const expr = @import("expr.zig");

/// What a name maps to.
pub const SymbolKind = enum {
    /// A label declaration — `name:`. Value is the byte address.
    label,
    /// A `data8` / `data16` directive's name. Value is the byte
    /// address where its bytes start.
    data,
    /// A `const NAME = <expr>` — value is the folded `u16`.
    const_value,
    /// A struct-field offset injected by `parseStructDecl`
    /// (e.g., `Player.hp = 0`).
    struct_field,
};

/// One entry in the table.
pub const Symbol = struct {
    kind: SymbolKind,
    value: u16,
    /// Bank slot the symbol was defined in. `null` = base image
    /// (the implicit no-bank section before any `bank N` directive).
    /// `Some(N)` = bank slot N (0-based, the value `mb` should hold
    /// for accesses into that bank).
    ///
    /// Populated for `.label` and `.data` kinds only; `.const_value`
    /// and `.struct_field` are compile-time constants with no
    /// bank-positioned address, so they leave this `null`.
    bank: ?u8 = null,
};

/// Name → Symbol lookup. Built incrementally by the codegen
/// pass; consumed during operand resolution + diagnostics
/// formatting (#37).
pub const SymbolTable = struct {
    entries: std.StringHashMap(Symbol),
    /// Synthetic keys (Name.field for struct offsets) we allocated
    /// ourselves and need to free on deinit.
    owned_keys: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    /// Build an empty table.
    pub fn init(allocator: std.mem.Allocator) SymbolTable {
        return .{
            .entries = std.StringHashMap(Symbol).init(allocator),
            .owned_keys = .empty,
            .allocator = allocator,
        };
    }

    /// Free owned keys + the backing map. Borrowed keys (slices
    /// into the fused source) aren't freed.
    pub fn deinit(self: *SymbolTable) void {
        for (self.owned_keys.items) |k| self.allocator.free(k);
        self.owned_keys.deinit(self.allocator);
        self.entries.deinit();
    }

    /// Register a symbol with a **borrowed** key. Returns
    /// `error.Duplicate` if a label or data symbol already exists
    /// at this name (E005-shape). Const + struct fields silently
    /// overwrite — the parser already validated their uniqueness.
    pub fn putBorrowed(self: *SymbolTable, name: []const u8, sym: Symbol) !void {
        if (sym.kind == .label or sym.kind == .data) {
            if (self.entries.get(name)) |existing| {
                if (existing.kind == .label or existing.kind == .data) {
                    return error.Duplicate;
                }
            }
        }
        try self.entries.put(name, sym);
    }

    /// Register a symbol with an **owned** key (allocator-allocated).
    /// Same duplicate rules as `putBorrowed`. On error, the caller
    /// is responsible for freeing the key.
    pub fn putOwned(self: *SymbolTable, name: []const u8, sym: Symbol) !void {
        if (sym.kind == .label or sym.kind == .data) {
            if (self.entries.get(name)) |existing| {
                if (existing.kind == .label or existing.kind == .data) {
                    return error.Duplicate;
                }
            }
        }
        try self.owned_keys.append(self.allocator, name);
        try self.entries.put(name, sym);
    }

    /// Lookup; `null` if not bound.
    pub fn get(self: SymbolTable, name: []const u8) ?Symbol {
        return self.entries.get(name);
    }

    /// Scan every known name for one that's "close" to `query`
    /// by Levenshtein distance. Returns the closest match within
    /// threshold (1 for short names, 2 for longer) or `null`. The
    /// returned slice borrows from the symbol table's keys —
    /// callers must treat it as valid only for the table's
    /// lifetime. Used to power "did you mean?" hints on E004.
    pub fn suggestSimilar(self: SymbolTable, query: []const u8) ?[]const u8 {
        if (query.len == 0) return null;
        const threshold: usize = if (query.len <= 4) 1 else 2;
        var best: ?[]const u8 = null;
        var best_dist: usize = std.math.maxInt(usize);
        var it = self.entries.keyIterator();
        while (it.next()) |k_ptr| {
            const k = k_ptr.*;
            // Length filter: anything farther in length than the
            // threshold can't possibly fit. Cheap pre-check before
            // the O(n*m) edit-distance walk.
            const dlen = if (k.len > query.len) k.len - query.len else query.len - k.len;
            if (dlen > threshold) continue;
            const d = levenshtein(query, k);
            if (d <= threshold and d < best_dist) {
                best_dist = d;
                best = k;
            }
        }
        return best;
    }

    /// Compact Levenshtein implementation backed by a small
    /// stack buffer. Used only for "did you mean?" suggestions on
    /// names of typical asm-symbol length, so the cap is fine.
    fn levenshtein(a: []const u8, b: []const u8) usize {
        const max_len: usize = 64;
        if (a.len > max_len or b.len > max_len) {
            // Beyond the buffer — return a value past every
            // sensible threshold so the candidate is skipped.
            return std.math.maxInt(usize);
        }
        var prev: [max_len + 1]usize = undefined;
        var curr: [max_len + 1]usize = undefined;
        for (0..b.len + 1) |j| prev[j] = j;
        for (1..a.len + 1) |i| {
            curr[0] = i;
            for (1..b.len + 1) |j| {
                const cost: usize = if (a[i - 1] == b[j - 1]) 0 else 1;
                curr[j] = @min(
                    @min(curr[j - 1] + 1, prev[j] + 1),
                    prev[j - 1] + cost,
                );
            }
            @memcpy(prev[0 .. b.len + 1], curr[0 .. b.len + 1]);
        }
        return prev[b.len];
    }

    /// Project this table down to a `ConstantTable` so the
    /// expression evaluator can use it. Keys + values are
    /// borrowed — the returned table's lifetime is bounded by
    /// `self`'s. Caller still owns / deinits the returned table.
    pub fn toConstantTable(self: SymbolTable) !expr.ConstantTable {
        var out = expr.ConstantTable.init(self.allocator);
        errdefer out.deinit();
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            try out.put(entry.key_ptr.*, entry.value_ptr.value);
        }
        return out;
    }
};
