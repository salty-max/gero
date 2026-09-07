//! The virtual file set (`docs/gero-lab.md` §4.2).
//!
//! A session holds a named set of source buffers rather than one
//! string, and `include` / `use` resolve against that set — so a
//! multi-file program works in a browser exactly as it does on disk.
//!
//! The set is authoritative: a name it does not hold is a diagnostic,
//! never a read and never a fetch. That is what §4.2 means by
//! resolution being closed.

const std = @import("std");
const gero = @import("gero");

/// Buffers keyed by name, e.g. `main.gr` or `src/lib.gr`.
///
/// Names are the canonical form — the resolver folds `.` and `..` out
/// of a `use` target before looking one up, so `use "./lib"` from
/// `main.gr` finds `lib.gr`.
pub const Set = struct {
    /// Owns both keys and values: a host writes source into the arena
    /// and the set copies it, so a later `gero_reset` cannot pull a
    /// buffer out from under the resolver.
    map: gero.lang.Overlay = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Set {
        return .{ .allocator = allocator };
    }

    /// Add `name`, or replace it if already present.
    pub fn put(self: *Set, name: []const u8, contents: []const u8) !void {
        const owned_contents = try self.allocator.dupe(u8, contents);
        const gop = try self.map.getOrPut(self.allocator, name);
        if (!gop.found_existing) gop.key_ptr.* = try self.allocator.dupe(u8, name);
        gop.value_ptr.* = owned_contents;
    }

    /// Remove `name`. Removing one that is not present is not an error
    /// — a host clearing a closed tab should not have to check first.
    pub fn remove(self: *Set, name: []const u8) void {
        _ = self.map.remove(name);
    }

    pub fn count(self: *const Set) usize {
        return self.map.count();
    }

    pub fn contains(self: *const Set, name: []const u8) bool {
        return self.map.contains(name);
    }

    pub fn clear(self: *Set) void {
        self.map.clearRetainingCapacity();
    }
};
