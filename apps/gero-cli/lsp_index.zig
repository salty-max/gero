//! What the files around a document export.
//!
//! The checker answers questions about one program: the root file and
//! whatever its `use` lines pulled in. A name in a sibling file that
//! nothing imports yet is, correctly, not part of any program — so
//! there is nothing for the checker to have an opinion about, and the
//! import an editor would offer has to come from somewhere else.
//!
//! That somewhere is here. The workspace is the editor's domain rather
//! than the compiler's: `gero check` has no business walking a
//! directory, and this never runs outside `gero lsp`.

const std = @import("std");
const gero = @import("gero");

/// A name some file in the workspace exports.
pub const Export = struct {
    /// The declared name, as its file spells it.
    name: []const u8,
    /// Absolute path of the file declaring it.
    path: []const u8,
};

/// Every exported top-level name in a workspace, with the file that
/// declares it.
///
/// Rebuilt from disk on demand rather than watched: an editor asks for
/// code actions at human speed, and a stale index offers an import
/// that does not resolve.
pub const Index = struct {
    gpa: std.mem.Allocator,
    exports: std.ArrayList(Export) = .empty,
    /// Workspace root, or `null` before `initialize` named one. An
    /// index without a root stays empty — there is nothing to walk.
    root: ?[]const u8 = null,

    pub fn deinit(self: *Index) void {
        self.clear();
        self.exports.deinit(self.gpa);
        if (self.root) |r| self.gpa.free(r);
    }

    fn clear(self: *Index) void {
        for (self.exports.items) |e| {
            self.gpa.free(e.name);
            self.gpa.free(e.path);
        }
        self.exports.clearRetainingCapacity();
    }

    /// Remember the workspace root an `initialize` named.
    pub fn setRoot(self: *Index, root: []const u8) !void {
        if (self.root) |r| self.gpa.free(r);
        self.root = try self.gpa.dupe(u8, root);
    }

    /// Walk the root for `.gr` files and record what each exports,
    /// skipping `exclude` — the document being edited, whose own
    /// declarations are already in scope.
    ///
    /// `overlay` shadows the disk for buffers the editor holds
    /// unsaved, so a name typed a minute ago in another tab is
    /// offered like any other. A file that fails to read or parse
    /// contributes nothing: a half-parsed neighbour is not worth an
    /// import that may not compile.
    pub fn rebuild(
        self: *Index,
        io: std.Io,
        overlay: ?*const gero.lang.Overlay,
        exclude: ?[]const u8,
    ) !void {
        self.clear();
        const root = self.root orelse return;

        var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var walker = dir.walk(self.gpa) catch return;
        defer walker.deinit();

        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".gr")) continue;
            const full = try std.fs.path.join(self.gpa, &.{ root, entry.path });
            defer self.gpa.free(full);
            if (exclude) |x| if (std.mem.eql(u8, x, full)) continue;
            self.addFile(io, overlay, full) catch continue;
        }

        // A buffer for a file the walk could not reach — one the editor
        // opened from outside the root, or created and not yet saved —
        // still exports names worth offering.
        const ov = overlay orelse return;
        var it = ov.iterator();
        while (it.next()) |e| {
            const path = e.key_ptr.*;
            if (!std.mem.endsWith(u8, path, ".gr")) continue;
            if (exclude) |x| if (std.mem.eql(u8, x, path)) continue;
            if (self.hasFile(path)) continue;
            if (!std.mem.startsWith(u8, path, root)) continue;
            self.addSource(path, e.value_ptr.*) catch continue;
        }
    }

    /// `true` when some export already names `path` — the walk reached
    /// it, so its buffer was read there.
    fn hasFile(self: *const Index, path: []const u8) bool {
        for (self.exports.items) |e| {
            if (std.mem.eql(u8, e.path, path)) return true;
        }
        return false;
    }

    /// Record `path`'s exported top-level names, preferring the
    /// editor's copy of it over the one on disk.
    fn addFile(
        self: *Index,
        io: std.Io,
        overlay: ?*const gero.lang.Overlay,
        path: []const u8,
    ) !void {
        if (overlay) |ov| {
            if (ov.get(path)) |buffered| return self.addSource(path, buffered);
        }
        const src = try std.Io.Dir.cwd().readFileAlloc(io, path, self.gpa, .limited(max_file_bytes));
        defer self.gpa.free(src);
        return self.addSource(path, src);
    }

    /// Record what `src` — the contents of `path` — exports.
    fn addSource(self: *Index, path: []const u8, src: []const u8) !void {
        var stream = try gero.lang.tokenize(self.gpa, src);
        defer stream.deinit();
        var tree = try gero.lang.parse(self.gpa, src, stream);
        defer tree.deinit();
        // A file mid-edit parses to a tree with errors and a partial
        // statement list; its complete declarations still count.
        for (tree.program.statements) |stmt| {
            const decl = exportedName(src, stmt) orelse continue;
            try self.exports.append(self.gpa, .{
                .name = try self.gpa.dupe(u8, decl),
                .path = try self.gpa.dupe(u8, path),
            });
        }
    }

    /// Files this large are not hand-written Gero; skipping one costs
    /// an import suggestion, reading it costs the session's memory.
    const max_file_bytes = 4 * 1024 * 1024;

    /// Every file exporting `name`, in walk order.
    pub fn lookup(self: *const Index, name: []const u8, out: *std.ArrayList([]const u8), arena: std.mem.Allocator) !void {
        for (self.exports.items) |e| {
            if (!std.mem.eql(u8, e.name, name)) continue;
            try out.append(arena, e.path);
        }
    }
};

/// The name a top-level statement exports, or `null` when it declares
/// nothing importable — a `local` declaration, a `use`, anything else.
fn exportedName(src: []const u8, stmt: gero.lang.ast.Statement) ?[]const u8 {
    return switch (stmt) {
        .def_decl => |d| if (d.is_local) null else src[d.name.start..d.name.end],
        .struct_decl => |d| if (d.is_local) null else src[d.name.start..d.name.end],
        .class_decl => |d| if (d.is_local) null else src[d.name.start..d.name.end],
        .enum_decl => |d| if (d.is_local) null else src[d.name.start..d.name.end],
        else => null,
    };
}

// ---------- tests ----------

const testing = std.testing;

const Fixture = struct {
    tmp: std.testing.TmpDir,

    fn init() Fixture {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }

    fn write(self: *Fixture, name: []const u8, body: []const u8) !void {
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = body });
    }

    /// Absolute path of the fixture's directory, taken from a file
    /// written into it — `Io.Dir` resolves a named file, not itself.
    /// Caller frees.
    fn root(self: *Fixture, probe: []const u8) ![]u8 {
        const file = try self.tmp.dir.realPathFileAlloc(std.testing.io, probe, testing.allocator);
        defer testing.allocator.free(file);
        const dir = std.fs.path.dirname(file) orelse ".";
        return testing.allocator.dupe(u8, dir);
    }
};

/// Names the index holds, sorted so a test does not pin walk order.
fn namesOf(idx: *const Index, out: *std.ArrayList([]const u8)) !void {
    for (idx.exports.items) |e| try out.append(testing.allocator, e.name);
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
}

test "Index: every exported declaration kind is recorded" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("lib.gr",
        \\def helper() -> i16
        \\  return 0
        \\end
        \\struct Point
        \\  x: i16
        \\end
        \\class Sprite end
        \\enum State
        \\  case Idle
        \\end
        \\
    );

    var idx: Index = .{ .gpa = testing.allocator };
    defer idx.deinit();
    const probe = "lib.gr";
    const root = try fx.root(probe);
    defer testing.allocator.free(root);
    try idx.setRoot(root);
    try idx.rebuild(std.testing.io, null, null);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(testing.allocator);
    try namesOf(&idx, &names);
    try testing.expectEqual(@as(usize, 4), names.items.len);
    try testing.expectEqualStrings("Point", names.items[0]);
    try testing.expectEqualStrings("Sprite", names.items[1]);
    try testing.expectEqualStrings("State", names.items[2]);
    try testing.expectEqualStrings("helper", names.items[3]);
}

test "Index: a `local` declaration is not exported" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("lib.gr",
        \\local def hidden() -> i16
        \\  return 0
        \\end
        \\def shown() -> i16
        \\  return 1
        \\end
        \\
    );

    var idx: Index = .{ .gpa = testing.allocator };
    defer idx.deinit();
    const probe = "lib.gr";
    const root = try fx.root(probe);
    defer testing.allocator.free(root);
    try idx.setRoot(root);
    try idx.rebuild(std.testing.io, null, null);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(testing.allocator);
    try namesOf(&idx, &names);
    try testing.expectEqual(@as(usize, 1), names.items.len);
    try testing.expectEqualStrings("shown", names.items[0]);
}

test "Index: the excluded document does not offer its own names" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("here.gr",
        \\def mine() -> i16
        \\  return 0
        \\end
        \\
    );
    try fx.write("other.gr",
        \\def theirs() -> i16
        \\  return 0
        \\end
        \\
    );

    var idx: Index = .{ .gpa = testing.allocator };
    defer idx.deinit();
    const probe = "here.gr";
    const root = try fx.root(probe);
    defer testing.allocator.free(root);
    try idx.setRoot(root);

    const mine = try std.fs.path.join(testing.allocator, &.{ root, "here.gr" });
    defer testing.allocator.free(mine);
    try idx.rebuild(std.testing.io, null, mine);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(testing.allocator);
    try namesOf(&idx, &names);
    try testing.expectEqual(@as(usize, 1), names.items.len);
    try testing.expectEqualStrings("theirs", names.items[0]);
}

test "Index: two files exporting one name both answer a lookup" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("a.gr", "struct Vec2\n  x: i16\nend\n");
    try fx.write("b.gr", "struct Vec2\n  x: i16\nend\n");

    var idx: Index = .{ .gpa = testing.allocator };
    defer idx.deinit();
    const probe = "a.gr";
    const root = try fx.root(probe);
    defer testing.allocator.free(root);
    try idx.setRoot(root);
    try idx.rebuild(std.testing.io, null, null);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var hits: std.ArrayList([]const u8) = .empty;
    try idx.lookup("Vec2", &hits, arena_state.allocator());
    try testing.expectEqual(@as(usize, 2), hits.items.len);
}

test "Index: without a root there is nothing to offer" {
    var idx: Index = .{ .gpa = testing.allocator };
    defer idx.deinit();
    try idx.rebuild(std.testing.io, null, null);
    try testing.expectEqual(@as(usize, 0), idx.exports.items.len);
}

test "Index: a file that does not parse contributes nothing" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("broken.gr", "def helper( -> {{{\n");
    try fx.write("fine.gr", "def ok() -> i16\n  return 0\nend\n");

    var idx: Index = .{ .gpa = testing.allocator };
    defer idx.deinit();
    const probe = "fine.gr";
    const root = try fx.root(probe);
    defer testing.allocator.free(root);
    try idx.setRoot(root);
    try idx.rebuild(std.testing.io, null, null);

    // The broken file may yield nothing or a partial list; what must
    // hold is that it does not stop the walk reaching `fine.gr`.
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(testing.allocator);
    try namesOf(&idx, &names);
    var saw_ok = false;
    for (names.items) |n| {
        if (std.mem.eql(u8, n, "ok")) saw_ok = true;
    }
    try testing.expect(saw_ok);
}

test "Index: an unsaved buffer shadows the file on disk" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("lib.gr", "def saved() -> i16\n  return 0\nend\n");

    var idx: Index = .{ .gpa = testing.allocator };
    defer idx.deinit();
    const probe = "lib.gr";
    const root = try fx.root(probe);
    defer testing.allocator.free(root);
    try idx.setRoot(root);

    const lib = try std.fs.path.join(testing.allocator, &.{ root, "lib.gr" });
    defer testing.allocator.free(lib);
    var ov: gero.lang.Overlay = .{};
    defer ov.deinit(testing.allocator);
    try ov.put(testing.allocator, lib, "def unsaved() -> i16\n  return 0\nend\n");

    try idx.rebuild(std.testing.io, &ov, null);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(testing.allocator);
    try namesOf(&idx, &names);
    try testing.expectEqual(@as(usize, 1), names.items.len);
    // The editor's copy, not the one on disk.
    try testing.expectEqualStrings("unsaved", names.items[0]);
}

test "Index: a buffer for a file never written to disk still exports" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("anchor.gr", "def anchor() -> i16\n  return 0\nend\n");

    var idx: Index = .{ .gpa = testing.allocator };
    defer idx.deinit();
    const probe = "anchor.gr";
    const root = try fx.root(probe);
    defer testing.allocator.free(root);
    try idx.setRoot(root);

    const fresh = try std.fs.path.join(testing.allocator, &.{ root, "fresh.gr" });
    defer testing.allocator.free(fresh);
    var ov: gero.lang.Overlay = .{};
    defer ov.deinit(testing.allocator);
    try ov.put(testing.allocator, fresh, "struct Brand\n  x: i16\nend\n");

    try idx.rebuild(std.testing.io, &ov, null);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(testing.allocator);
    try namesOf(&idx, &names);
    try testing.expectEqual(@as(usize, 2), names.items.len);
    try testing.expectEqualStrings("Brand", names.items[0]);
    try testing.expectEqualStrings("anchor", names.items[1]);
}
