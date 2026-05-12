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
