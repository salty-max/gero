/// Scope + symbol-table tracking for the gero-lang typechecker.
/// Each `Scope` is a flat name → `SymbolInfo` map with an optional
/// parent pointer; `lookup` walks the chain. New blocks (function
/// body, class body, `do` block, etc.) push a fresh child scope; the
/// caller releases it when the block ends.
///
/// Naming convention: identifiers are interned by raw byte slice
/// (sliced from the source buffer the parser was handed). The string
/// hash-map's keys reference into that buffer — callers must not
/// release the source until the scope tree is torn down.
const std = @import("std");
const ast = @import("ast.zig");
const types = @import("types.zig");

/// What kind of declaration introduced this name. Drives diagnostics
/// (`expected variable, got class`) and access rules (`@private`
/// fields only callable from the class body).
pub const SymbolKind = enum {
    /// `let name = …` binding.
    let_binding,
    /// `const NAME = …` binding.
    const_binding,
    /// Function parameter.
    param,
    /// Top-level or method `def name(…) … end`.
    function,
    /// `class Name … end`.
    class,
    /// `struct Name … end`.
    struct_,
    /// `enum Name … end`.
    enum_,
    /// `use module` import — alias name in scope.
    module_alias,
    /// `use sym from module` import — the imported symbol.
    imported,
};

/// What the typechecker remembers about a name. The `ty` field is
/// `null` until the resolution / inference slice fills it in; the
/// scaffolding slice records declarations with `ty = null` and later
/// passes paint in the resolved types.
pub const SymbolInfo = struct {
    kind: SymbolKind,
    /// Resolved type. `null` when the kind has no associated type
    /// (e.g. a class declaration carries methods + fields but not a
    /// single "type"; refer via `Named`).
    ty: ?*const types.Type = null,
    /// Source span of the declaration site — used by diagnostics to
    /// point at "originally declared here" notes.
    decl_span: ast.Span,
    /// For `let_binding`: `true` if a closure captures-and-mutates
    /// this binding. Populated by the closure-analysis slice; the
    /// scaffolding leaves it `false`.
    captured_mutable: bool = false,
};

/// One lexical scope. Owns its own hash-map and points up to the
/// enclosing scope (or `null` at the module root).
pub const Scope = struct {
    parent: ?*Scope,
    allocator: std.mem.Allocator,
    entries: std.StringHashMapUnmanaged(SymbolInfo) = .{},

    /// Build a fresh scope. Pass `parent = null` for the module
    /// root; pass an existing scope to nest a child.
    pub fn init(allocator: std.mem.Allocator, parent: ?*Scope) Scope {
        return .{ .parent = parent, .allocator = allocator };
    }

    /// Release the scope's hash-map. Keys reference the source
    /// buffer, so nothing else needs freeing.
    pub fn deinit(self: *Scope) void {
        self.entries.deinit(self.allocator);
    }

    /// Insert `name → info`. Returns `error.AlreadyDefined` if the
    /// name already exists in **this** scope (shadowing across
    /// scopes is allowed).
    pub fn define(self: *Scope, name: []const u8, info: SymbolInfo) !void {
        const gop = try self.entries.getOrPut(self.allocator, name);
        if (gop.found_existing) return error.AlreadyDefined;
        gop.value_ptr.* = info;
    }

    /// Walk this scope and every ancestor, returning the first
    /// match for `name`. `null` when no enclosing scope holds it.
    pub fn lookup(self: *const Scope, name: []const u8) ?SymbolInfo {
        if (self.entries.get(name)) |info| return info;
        if (self.parent) |p| return p.lookup(name);
        return null;
    }

    /// Look up `name` strictly in this scope — does not walk parents.
    /// Useful for "is the name already defined locally" checks.
    pub fn lookupLocal(self: *const Scope, name: []const u8) ?SymbolInfo {
        return self.entries.get(name);
    }

    /// Patch an existing entry's `ty`. Used by inference once the
    /// type is known. Errors on a missing key — call only after a
    /// successful `define`.
    pub fn setType(self: *Scope, name: []const u8, ty: *const types.Type) !void {
        const entry = self.entries.getPtr(name) orelse return error.NotFound;
        entry.ty = ty;
    }
};

// `ScopeError` is captured implicitly via Zig's inferred error sets
// on `Scope.define` / `Scope.setType`. Callers catch the variants
// they care about with `error.AlreadyDefined` / `error.NotFound` /
// `error.OutOfMemory` directly.
