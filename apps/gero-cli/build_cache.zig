const std = @import("std");
const gero = @import("gero");

/// Directory name under the project's output root.
pub const dir_name = ".cache";

/// Identifies the index file.
const magic = "GRCI";

/// Bumped whenever the index encoding or the meaning of a hash
/// changes. A mismatch discards the cache rather than trusting it.
const format_version: u16 = 1;

/// What the last successful build recorded about one module.
pub const ModuleEntry = struct {
    /// Canonical path, which is how a module is matched across builds —
    /// file ids depend on walk order and are not stable.
    path: []const u8,
    content_hash: u64,
    interface_hash: u64,
    /// File id the module held when its code was lowered. Symbols of
    /// same-named defs are qualified `name$<id>` (§5), so a module whose
    /// id moved has differently-named code even when its text did not.
    file_id: u16,
};

/// One skipped module's variadic specialization request, stored by path
/// for the same reason module entries are.
pub const StoredArity = struct {
    module_path: []const u8,
    name: []const u8,
    arity: u32,
};

/// A previous build's record. Absent, unreadable, or written under
/// different settings all mean the same thing — build everything.
pub const Cache = struct {
    modules: []const ModuleEntry,
    arities: []const StoredArity,
    fragments: []const gero.lang.Fragment,

    /// The entry recorded for `path`, or `null` when this build reached
    /// a module the last one did not.
    pub fn find(self: Cache, path: []const u8) ?ModuleEntry {
        for (self.modules) |m| {
            if (std.mem.eql(u8, m.path, path)) return m;
        }
        return null;
    }
};

/// What this build must do, given what the cache holds.
pub const Plan = struct {
    /// Modules whose bodies this build may skip, by current file id.
    skip: []const bool,
    /// Fragments belonging to skipped modules, safe to splice.
    fragments: []const gero.lang.Fragment,
    /// Variadic requests the skipped modules made last time.
    arities: []const gero.lang.ArityRequest,
};

/// Read the cache under `cache_dir`. Returns `null` for any reason the
/// cache cannot be trusted: missing, unreadable, a different format, or
/// written for a different entry point or optimize mode. A caller
/// treats every one of those the same way — build everything.
pub fn load(
    io: std.Io,
    arena: std.mem.Allocator,
    cache_dir: []const u8,
    entry: []const u8,
    optimize: []const u8,
) ?Cache {
    const index_path = std.fs.path.join(arena, &.{ cache_dir, "index.bin" }) catch return null;
    const frag_path = std.fs.path.join(arena, &.{ cache_dir, "fragments.bin" }) catch return null;

    const index_blob = std.Io.Dir.cwd().readFileAlloc(io, index_path, arena, .unlimited) catch return null;
    const frag_blob = std.Io.Dir.cwd().readFileAlloc(io, frag_path, arena, .unlimited) catch return null;

    var r: Reader = .{ .blob = index_blob };
    if (index_blob.len < magic.len or !std.mem.eql(u8, index_blob[0..magic.len], magic)) return null;
    r.pos = magic.len;
    if ((r.readU16() catch return null) != format_version) return null;
    // A different entry point or optimize mode lowers different code
    // from the same sources, so the fragments do not apply.
    if (!std.mem.eql(u8, r.readBytes(arena) catch return null, entry)) return null;
    if (!std.mem.eql(u8, r.readBytes(arena) catch return null, optimize)) return null;

    const module_count = r.readU32() catch return null;
    const modules = arena.alloc(ModuleEntry, module_count) catch return null;
    for (modules) |*m| m.* = .{
        .path = r.readBytes(arena) catch return null,
        .content_hash = r.readU64() catch return null,
        .interface_hash = r.readU64() catch return null,
        .file_id = r.readU16() catch return null,
    };

    const arity_count = r.readU32() catch return null;
    const arities = arena.alloc(StoredArity, arity_count) catch return null;
    for (arities) |*a| a.* = .{
        .module_path = r.readBytes(arena) catch return null,
        .name = r.readBytes(arena) catch return null,
        .arity = r.readU32() catch return null,
    };

    const fragments = gero.lang.decodeFragments(arena, frag_blob) catch return null;
    return .{ .modules = modules, .arities = arities, .fragments = fragments };
}

/// `true` when every module this build reached is byte-for-byte what
/// the cache recorded, and the module set itself is unchanged. Nothing
/// downstream of reading the files can differ, so the previous output
/// is still the right answer.
pub fn contentUnchanged(cache: Cache, fused: *const gero.lang.FusedSource) bool {
    const files = fused.source_map.files.items;
    if (cache.modules.len != files.len) return false;
    for (files, 0..) |f, i| {
        const prev = cache.find(f.path) orelse return false;
        // safety: file count is bounded by the include walk; fits u16.
        const id: u16 = @intCast(i);
        if (prev.file_id != id) return false;
        if (prev.content_hash != gero.lang.moduleContentHash(&fused.source_map, id)) return false;
    }
    return true;
}

/// Decide which modules this build can skip. A module is skipped when
/// its own text is unchanged and nothing it imports changed its
/// interface — `dirtySet` closes that relation over the import graph.
pub fn plan(
    arena: std.mem.Allocator,
    cache: ?Cache,
    fused: *const gero.lang.FusedSource,
    statements_of: []const []const gero.lang.ast.Statement,
) !Plan {
    const count = fused.source_map.files.items.len;
    const c = cache orelse return .{
        .skip = try allFalse(arena, count),
        .fragments = &.{},
        .arities = &.{},
    };

    const changed = try classify(arena, c, fused, statements_of);
    const dirty = try gero.lang.dirtyModules(arena, count, fused.imports, changed.interface);
    for (dirty, changed.content) |*d, own| {
        if (own) d.* = true;
    }

    var fragments: std.ArrayList(gero.lang.Fragment) = .empty;
    for (c.fragments) |f| {
        const id = currentIdOf(c, fused, f.module) orelse continue;
        if (dirty[id]) continue;
        try fragments.append(arena, f);
    }

    var arities: std.ArrayList(gero.lang.ArityRequest) = .empty;
    for (c.arities) |a| {
        const id = fused.source_map.findFileId(a.module_path) orelse continue;
        if (dirty[id]) continue;
        try arities.append(arena, .{ .module = id, .name = a.name, .arity = a.arity });
    }

    const skip = try arena.alloc(bool, count);
    for (skip, dirty) |*s, d| s.* = !d;

    return .{
        .skip = skip,
        .fragments = fragments.items,
        .arities = arities.items,
    };
}

/// Which modules moved, split by what a dependent cares about. A
/// module's own text moving means it must be rebuilt; its *interface*
/// moving is what reaches its dependents.
const Changed = struct {
    content: []const bool,
    interface: []const bool,
};

fn classify(
    arena: std.mem.Allocator,
    cache: Cache,
    fused: *const gero.lang.FusedSource,
    statements_of: []const []const gero.lang.ast.Statement,
) !Changed {
    const files = fused.source_map.files.items;
    const content = try arena.alloc(bool, files.len);
    const interface = try arena.alloc(bool, files.len);
    for (files, 0..) |f, i| {
        const prev = cache.find(f.path);
        // safety: file count is bounded by the include walk; fits u16.
        const id: u16 = @intCast(i);
        const iface = if (i < statements_of.len)
            gero.lang.moduleInterfaceHash(fused.source, statements_of[i])
        else
            0;
        // An id shift renames this module's qualified symbols, so its
        // cached code no longer answers to the labels this build emits.
        content[i] = prev == null or
            prev.?.content_hash != gero.lang.moduleContentHash(&fused.source_map, id) or
            prev.?.file_id != id;
        interface[i] = prev == null or prev.?.interface_hash != iface;
    }
    return .{ .content = content, .interface = interface };
}

/// Write this build's record, replacing whatever was there. A failure
/// to write is not a build failure — the next build just rebuilds more
/// than it needed to — so the caller is free to ignore the error.
pub fn store(
    io: std.Io,
    arena: std.mem.Allocator,
    cache_dir: []const u8,
    entry: []const u8,
    optimize: []const u8,
    fused: *const gero.lang.FusedSource,
    statements_of: []const []const gero.lang.ast.Statement,
    requests: []const gero.lang.ArityRequest,
    fragments: []const gero.lang.Fragment,
) !void {
    try std.Io.Dir.cwd().createDirPath(io, cache_dir);

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, magic);
    try putU16(arena, &out, format_version);
    try putBytes(arena, &out, entry);
    try putBytes(arena, &out, optimize);

    const files = fused.source_map.files.items;
    try putU32(arena, &out, @intCast(files.len));
    for (files, 0..) |f, i| {
        try putBytes(arena, &out, f.path);
        // safety: file count is bounded by the include walk; fits u16.
        try putU64(arena, &out, gero.lang.moduleContentHash(&fused.source_map, @intCast(i)));
        try putU64(arena, &out, if (i < statements_of.len)
            gero.lang.moduleInterfaceHash(fused.source, statements_of[i])
        else
            0);
        // safety: file count is bounded by the include walk; fits u16.
        try putU16(arena, &out, @intCast(i));
    }

    try putU32(arena, &out, @intCast(requests.len));
    for (requests) |r| {
        try putBytes(arena, &out, if (r.module < files.len) files[r.module].path else "");
        try putBytes(arena, &out, r.name);
        try putU32(arena, &out, r.arity);
    }

    const index_path = try std.fs.path.join(arena, &.{ cache_dir, "index.bin" });
    const frag_path = try std.fs.path.join(arena, &.{ cache_dir, "fragments.bin" });
    const frag_blob = try gero.lang.encodeFragments(arena, fragments);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = out.items });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = frag_path, .data = frag_blob });
}

/// Map a cached fragment's module id onto this build's file ids. Walk
/// order decides ids, so they are matched through the path the cache
/// recorded rather than carried across.
fn currentIdOf(c: Cache, fused: *const gero.lang.FusedSource, cached_id: u16) ?u16 {
    if (cached_id >= c.modules.len) return null;
    return fused.source_map.findFileId(c.modules[cached_id].path);
}

fn allFalse(arena: std.mem.Allocator, n: usize) ![]bool {
    const out = try arena.alloc(bool, n);
    for (out) |*b| b.* = false;
    return out;
}

const Reader = struct {
    blob: []const u8,
    pos: usize = 0,

    fn readByte(self: *Reader) error{Truncated}!u8 {
        if (self.pos >= self.blob.len) return error.Truncated;
        defer self.pos += 1;
        return self.blob[self.pos];
    }

    fn readU16(self: *Reader) error{Truncated}!u16 {
        const lo: u16 = try self.readByte();
        const hi: u16 = try self.readByte();
        return lo | (hi << 8);
    }

    fn readU32(self: *Reader) error{Truncated}!u32 {
        const a: u32 = try self.readU16();
        const b: u32 = try self.readU16();
        return a | (b << 16);
    }

    fn readU64(self: *Reader) error{Truncated}!u64 {
        const a: u64 = try self.readU32();
        const b: u64 = try self.readU32();
        return a | (b << 32);
    }

    fn readBytes(self: *Reader, arena: std.mem.Allocator) ![]const u8 {
        const len = try self.readU32();
        if (self.pos + len > self.blob.len) return error.Truncated;
        defer self.pos += len;
        return arena.dupe(u8, self.blob[self.pos..][0..len]);
    }
};

fn putU16(arena: std.mem.Allocator, out: *std.ArrayList(u8), value: u16) !void {
    // safety: u16 → 2 bytes by definition; both casts are byte-masks.
    try out.append(arena, @intCast(value & 0xFF));
    try out.append(arena, @intCast(value >> 8));
}

fn putU32(arena: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    // safety: u32 → two u16 halves; the mask and shift both fit.
    try putU16(arena, out, @intCast(value & 0xFFFF));
    try putU16(arena, out, @intCast(value >> 16));
}

fn putU64(arena: std.mem.Allocator, out: *std.ArrayList(u8), value: u64) !void {
    // safety: u64 → two u32 halves; the mask and shift both fit.
    try putU32(arena, out, @intCast(value & 0xFFFFFFFF));
    try putU32(arena, out, @intCast(value >> 32));
}

fn putBytes(arena: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    try putU32(arena, out, @intCast(value.len));
    try out.appendSlice(arena, value);
}

// ---------- tests ----------

const testing = std.testing;

/// A two-module project on disk: `main.gr` importing `src/util.gr`.
const Project = struct {
    tmp: std.testing.TmpDir,

    fn init() Project {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    fn deinit(self: *Project) void {
        self.tmp.cleanup();
    }

    fn write(self: *Project, name: []const u8, body: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = body });
    }

    /// Resolve, parse, and plan against `cache`.
    fn planWith(
        self: *Project,
        arena: std.mem.Allocator,
        cache: ?Cache,
        fused: *gero.lang.FusedSource,
    ) !Plan {
        _ = self;
        var stream = try gero.lang.tokenize(arena, fused.source);
        defer stream.deinit();
        var tree = try gero.lang.parseAllModules(arena, fused.source, stream, &fused.source_map);
        defer tree.deinit();

        var statements_of: std.ArrayList([]const gero.lang.ast.Statement) = .empty;
        for (fused.source_map.files.items, 0..) |_, i| {
            var found: []const gero.lang.ast.Statement = &.{};
            for (tree.modules) |m| {
                if (m.file_id == i) found = m.tree.program.statements;
            }
            try statements_of.append(arena, found);
        }
        return plan(arena, cache, fused, statements_of.items);
    }

    fn resolve(self: *Project, arena: std.mem.Allocator) !gero.lang.FusedSource {
        const path = try self.tmp.dir.realPathFileAlloc(testing.io, "main.gr", arena);
        return gero.lang.resolveUseImports(testing.io, arena, path);
    }

    fn idOf(fused: gero.lang.FusedSource, basename: []const u8) usize {
        for (fused.source_map.files.items, 0..) |f, i| {
            if (std.mem.endsWith(u8, f.path, basename)) return i;
        }
        return 0;
    }
};

/// Build a cache record describing the project as it stands.
fn recordOf(arena: std.mem.Allocator, fused: *gero.lang.FusedSource) !Cache {
    var stream = try gero.lang.tokenize(arena, fused.source);
    defer stream.deinit();
    var tree = try gero.lang.parseAllModules(arena, fused.source, stream, &fused.source_map);
    defer tree.deinit();

    const files = fused.source_map.files.items;
    const modules = try arena.alloc(ModuleEntry, files.len);
    for (files, 0..) |f, i| {
        var statements: []const gero.lang.ast.Statement = &.{};
        for (tree.modules) |m| {
            if (m.file_id == i) statements = m.tree.program.statements;
        }
        modules[i] = .{
            .path = try arena.dupe(u8, f.path),
            // safety: file count is bounded by the include walk; fits u16.
            .content_hash = gero.lang.moduleContentHash(&fused.source_map, @intCast(i)),
            .interface_hash = gero.lang.moduleInterfaceHash(fused.source, statements),
            // safety: file count is bounded by the include walk; fits u16.
            .file_id = @intCast(i),
        };
    }
    return .{ .modules = modules, .arities = &.{}, .fragments = &.{} };
}

const main_src =
    \\use "./util"
    \\def main()
    \\  print double(21)
    \\end
    \\
;

const util_src =
    \\def double(n: i16) -> i16
    \\  return n * 2
    \\end
    \\
;

test "plan: an unchanged project skips every module" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var p = Project.init();
    defer p.deinit();
    try p.write("util.gr", util_src);
    try p.write("main.gr", main_src);

    var fused = try p.resolve(arena);
    defer fused.deinit();
    const cache = try recordOf(arena, &fused);

    const result = try p.planWith(arena, cache, &fused);
    for (result.skip) |s| try testing.expect(s);
    try testing.expect(contentUnchanged(cache, &fused));
}

test "plan: editing a dependency's body leaves its dependent skipped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var p = Project.init();
    defer p.deinit();
    try p.write("util.gr", util_src);
    try p.write("main.gr", main_src);

    var before = try p.resolve(arena);
    const cache = try recordOf(arena, &before);
    before.deinit();

    // Same signature, different body — the interface hash cannot move,
    // so nothing that imports it needs redoing.
    try p.write("util.gr", "def double(n: i16) -> i16\n  let t = n\n  return t + t\nend\n");
    var after = try p.resolve(arena);
    defer after.deinit();

    const result = try p.planWith(arena, cache, &after);
    try testing.expect(!result.skip[Project.idOf(after, "util.gr")]);
    try testing.expect(result.skip[Project.idOf(after, "main.gr")]);
}

test "plan: changing a dependency's signature rebuilds its dependent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var p = Project.init();
    defer p.deinit();
    try p.write("util.gr", util_src);
    try p.write("main.gr", main_src);

    var before = try p.resolve(arena);
    const cache = try recordOf(arena, &before);
    before.deinit();

    try p.write("util.gr", "def double(n: i16, extra: i16) -> i16\n  return n * 2 + extra\nend\n");
    var after = try p.resolve(arena);
    defer after.deinit();

    const result = try p.planWith(arena, cache, &after);
    try testing.expect(!result.skip[Project.idOf(after, "util.gr")]);
    try testing.expect(!result.skip[Project.idOf(after, "main.gr")]);
}

test "plan: editing a dependent leaves its dependency skipped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var p = Project.init();
    defer p.deinit();
    try p.write("util.gr", util_src);
    try p.write("main.gr", main_src);

    var before = try p.resolve(arena);
    const cache = try recordOf(arena, &before);
    before.deinit();

    try p.write("main.gr", "use \"./util\"\ndef main()\n  print double(20)\nend\n");
    var after = try p.resolve(arena);
    defer after.deinit();

    const result = try p.planWith(arena, cache, &after);
    try testing.expect(!result.skip[Project.idOf(after, "main.gr")]);
    try testing.expect(result.skip[Project.idOf(after, "util.gr")]);
}

test "plan: no cache builds everything" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var p = Project.init();
    defer p.deinit();
    try p.write("util.gr", util_src);
    try p.write("main.gr", main_src);

    var fused = try p.resolve(arena);
    defer fused.deinit();

    const result = try p.planWith(arena, null, &fused);
    for (result.skip) |s| try testing.expect(!s);
}

test "plan: a module whose file id shifted is rebuilt" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var p = Project.init();
    defer p.deinit();
    try p.write("util.gr", util_src);
    try p.write("main.gr", main_src);

    var before = try p.resolve(arena);
    var cache = try recordOf(arena, &before);
    const util_before = Project.idOf(before, "util.gr");
    before.deinit();

    // Same text, different id. Qualified symbols embed the id, so the
    // cached code answers to labels this build no longer emits — a
    // module in that position has to be lowered again.
    const shifted = try arena.alloc(ModuleEntry, cache.modules.len);
    for (cache.modules, shifted) |src_m, *dst_m| {
        dst_m.* = src_m;
        if (std.mem.endsWith(u8, src_m.path, "util.gr")) dst_m.file_id = src_m.file_id +% 7;
    }
    cache.modules = shifted;

    var after = try p.resolve(arena);
    defer after.deinit();
    try testing.expectEqual(util_before, Project.idOf(after, "util.gr"));

    const result = try p.planWith(arena, cache, &after);
    try testing.expect(!result.skip[Project.idOf(after, "util.gr")]);
    try testing.expect(!contentUnchanged(cache, &after));
}
