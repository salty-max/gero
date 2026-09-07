//! The `gero.wasm` boundary — a C-ABI surface over the toolchain and
//! the VM, for hosts with no filesystem and no allocator.
//!
//! This module owns two conventions everything built on it depends on:
//! how memory crosses the boundary (§2.1), and how a result comes back
//! (§2.2). The exports that use them land separately; what is here is
//! the contract they are written against.
//!
//! Target is `wasm32-freestanding` rather than `wasm32-wasi`: the
//! consumer needs a narrow purpose-built surface, not a POSIX shim.
//! Print syscalls already route through `vm.host.out`, so a binding
//! captures them rather than needing stdout.

const std = @import("std");
const gero = @import("gero");
const files = @import("files.zig");

// ---------- memory (§2.1) ----------

/// Backing store for the module's arena. Freestanding wasm has no
/// allocator, so the module brings its own: one fixed region, carved
/// by a bump pointer, reset per operation.
///
/// Sized for the largest program the ISA can express — a 64 KiB image
/// plus its sources, diagnostics, and intermediate trees — with room
/// to spare. A host that wants a different ceiling passes one to
/// `gero_init`.
var arena_store: [max_arena_bytes]u8 = undefined;

/// Ceiling on the arena, and the default when `gero_init` is passed 0.
pub const max_arena_bytes: usize = 16 * 1024 * 1024;

/// Bytes of `arena_store` this session may use.
var arena_limit: usize = 0;
/// Bump cursor for operation scratch, growing up from `null_guard`.
///
/// Starts past offset 0 so that no live allocation ever has pointer
/// `0`: exports report failure by returning a null pointer, and an
/// offset-based scheme would otherwise make a perfectly good first
/// allocation indistinguishable from that failure.
var arena_used: usize = null_guard;

/// Bump cursor for host input, growing **down** from the arena's top.
///
/// Inputs and scratch share one region from opposite ends, because
/// they have different lifetimes and the same address space. Scratch
/// is reset at the start of every operation; input is not, because an
/// export's arguments are written *before* the call and must still be
/// there when it reads them. Resetting one region on entry would free
/// the other's contents — which is exactly the bug this shape exists
/// to prevent.
///
/// A host frees inputs with `gero_reset`, once it is done with them.
var input_top: usize = 0;

/// Bytes reserved at the arena's base so `0` is never a valid pointer.
const null_guard: usize = @alignOf(u64);
/// Set by `gero_init`; every other export refuses until it is.
var initialized: bool = false;

/// Status codes shared by every export. A host switches on these, so
/// their numeric values are part of the boundary and must not be
/// renumbered — see `docs/versioning.md`.
pub const Status = enum(u32) {
    /// The operation produced its payload with no fatal diagnostic.
    ok = 0,
    /// The operation ran and reported diagnostics; the payload is
    /// absent or partial. Not a failure of the module.
    diagnostics = 1,
    /// `gero_init` has not been called, or returned an error.
    not_initialized = 2,
    /// The arena cannot satisfy the request. Reported rather than
    /// trapped, so a host can raise its ceiling and retry instead of
    /// meeting a dead instance.
    out_of_memory = 3,
    /// A `lang` discriminant that names no front-end.
    bad_lang = 4,
    /// A pointer / length pair that does not lie inside the arena.
    bad_argument = 5,
};

/// Which front-end a source buffer belongs to. Passed as a `u32` so
/// one `Result` shape serves both languages.
pub const Lang = enum(u32) {
    gas = 0,
    gr = 1,

    fn from(value: u32) ?Lang {
        return switch (value) {
            0 => .gas,
            1 => .gr,
            else => null,
        };
    }
};

/// What every export returns: a pointer to one of these, in module
/// memory, valid until the next call.
///
/// Fixed layout, little-endian, five `u32` fields in this order — a
/// host decodes it with five reads at known offsets and no schema.
/// The payload stays raw bytes (a `.gx` image, or formatted text);
/// only the diagnostics are JSON, because that is the one part with a
/// shape worth sharing with the CLI.
pub const Result = extern struct {
    status: u32,
    /// `.gx` bytes or formatted UTF-8, or 0 when there is none.
    payload_ptr: u32,
    payload_len: u32,
    /// UTF-8 JSON: an array of the objects `gero check --format=json`
    /// emits. `0` when the operation reported none.
    diagnostics_ptr: u32,
    diagnostics_len: u32,

    /// Bytes a host reads to decode one. Part of the boundary.
    pub const encoded_size: usize = 20;
};

/// The single `Result` every export writes into and returns a pointer
/// to. One slot, so a host must read it before the next call — which
/// is the same rule the arena already imposes on payloads.
var result: Result = undefined;

// ---------- lifecycle ----------

/// Prepare the module. `arena_bytes` of 0 takes the default; a larger
/// request is clamped to `max_arena_bytes`. Returns a `Status`.
///
/// Calling it again resets the session, which is how a host recovers
/// from `out_of_memory` after raising its ceiling.
export fn gero_init(arena_bytes: u32) u32 {
    arena_limit = if (arena_bytes == 0) max_arena_bytes else @min(@as(usize, arena_bytes), max_arena_bytes);
    arena_used = null_guard;
    input_top = arena_limit;
    file_used = 0;
    file_set = files.Set.init(fileAllocator());
    initialized = true;
    return @intFromEnum(Status.ok);
}

/// Drop everything: the last operation's scratch **and** the inputs a
/// host wrote for it. Exports reset only scratch on entry, so this is
/// how input memory is reclaimed.
export fn gero_reset() void {
    arena_used = null_guard;
    input_top = arena_limit;
}

/// Reserve `len` bytes and return a pointer a host can write into —
/// how source text gets *in*. Returns 0 when the region cannot satisfy
/// it, which a host must check.
///
/// Input survives an operation; only `gero_reset` reclaims it.
export fn gero_alloc(len: u32) u32 {
    if (!initialized) return 0;
    const bytes = allocInput(len) orelse return 0;
    return ptrOf(bytes);
}

/// Bytes handed out since the last reset — scratch plus input. For a
/// host sizing its ceiling, and for tests.
export fn gero_arena_used() u32 {
    // safety: bounded by `arena_limit`, itself capped at 16 MiB.
    return @intCast((arena_used - null_guard) + (arena_limit - input_top));
}

/// The arena's ceiling for this session.
export fn gero_arena_limit() u32 {
    // safety: capped at `max_arena_bytes`.
    return @intCast(arena_limit);
}

/// Size of the `Result` struct, so a host can assert its decoder
/// agrees with the module rather than hard-coding 20.
export fn gero_result_size() u32 {
    return @intCast(Result.encoded_size);
}

/// Where the arena begins in linear memory. Every pointer the module
/// hands out is an offset from here, so a host reads a payload at
/// `memory.buffer + gero_arena_base() + payload_ptr`.
export fn gero_arena_base() u32 {
    // safety: the arena is a static region, well inside a 32-bit space
    // on the target this module is built for.
    return @intCast(@intFromPtr(&arena_store));
}

// ---------- internals ----------

/// Carve `len` bytes off the arena, or `null` when it will not fit.
///
/// Returning `null` rather than trapping is the whole reason the
/// module brings its own allocator: a host that asks for more than it
/// reserved gets a status it can act on, not a wasm instance that has
/// to be thrown away.
fn alloc(len: usize) ?[]u8 {
    const aligned = std.mem.alignForward(usize, arena_used, @alignOf(u64));
    // The two cursors meet in the middle; exhaustion is when they cross.
    if (aligned + len > input_top) return null;
    arena_used = aligned + len;
    return arena_store[aligned .. aligned + len];
}

/// Carve `len` bytes off the input end, or `null` when it will not fit.
fn allocInput(len: usize) ?[]u8 {
    if (len > input_top) return null;
    const start = std.mem.alignBackward(usize, input_top - len, @alignOf(u64));
    if (start < arena_used) return null;
    input_top = start;
    return arena_store[start .. start + len];
}

/// An allocator over the arena, for the library entry points.
const Arena = struct {
    fn allocFn(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const a = @max(alignment.toByteUnits(), @alignOf(u64));
        const aligned = std.mem.alignForward(usize, arena_used, a);
        if (aligned + len > input_top) return null;
        arena_used = aligned + len;
        return arena_store[aligned..].ptr;
    }

    fn resizeFn(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remapFn(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    /// A bump arena frees only in bulk, via `gero_reset`.
    fn freeFn(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };
};

/// Allocator handing out arena memory. Every export uses this, so an
/// operation's whole working set dies at the next reset.
pub fn allocator() std.mem.Allocator {
    return .{ .ptr = undefined, .vtable = &Arena.vtable };
}

/// A pointer, as the boundary defines one: a byte offset from the
/// arena's base, not an absolute address. Only ever called on arena
/// memory — a slice from anywhere else is a programming error, and
/// `finish` is documented accordingly.
///
/// A host resolves it as `memory.buffer + gero_arena_base() + ptr`.
/// That indirection buys uniformity — an offset means the same thing
/// on wasm32, where a pointer is already a 32-bit linear-memory
/// offset, and on the 64-bit host these tests run on. Narrowing a real
/// address to `u32` would work only on the former.
fn ptrOf(bytes: []const u8) u32 {
    // safety: `arena_store` is a static 16 MiB region, so an offset
    // into it fits a u32 with room to spare.
    return @intCast(@intFromPtr(bytes.ptr) - @intFromPtr(&arena_store));
}

/// True when `(ptr, len)` names a region inside the arena. Guards the
/// exports against a host passing a stale or invented pointer.
pub fn inArena(ptr: u32, len: u32) bool {
    if (ptr < null_guard) return false;
    return @as(usize, ptr) + @as(usize, len) <= arena_limit;
}

/// Whether an operation's scratch reset would invalidate `(ptr, len)`.
/// Input lives above the scratch cursor, so it survives; anything
/// below does not.
pub fn isInput(ptr: u32, len: u32) bool {
    return inArena(ptr, len) and ptr >= input_top;
}

/// Borrow `(ptr, len)` as a slice, or `null` when it is out of bounds.
pub fn slice(ptr: u32, len: u32) ?[]const u8 {
    if (!inArena(ptr, len)) return null;
    return arena_store[ptr .. ptr + len];
}

/// Whether the module is ready to serve an operation.
pub fn ready() bool {
    return initialized;
}

/// Fill `result` with a failure carrying no payload, and return it.
pub fn fail(status: Status) *const Result {
    result = .{
        .status = @intFromEnum(status),
        .payload_ptr = 0,
        .payload_len = 0,
        .diagnostics_ptr = 0,
        .diagnostics_len = 0,
    };
    return &result;
}

/// Fill `result` with `payload` and `diagnostics`, either of which may
/// be empty. Both must be arena memory — they are handed to the host
/// as offsets into it. The status is `ok` when nothing was reported and
/// `diagnostics` when something was — a host branches on that rather
/// than on whether the payload happens to be empty.
pub fn finish(payload: ?[]const u8, diagnostics: ?[]const u8, count: usize) *const Result {
    // `count` is passed rather than inferred: an empty JSON array is
    // still two bytes, so length says nothing about what was reported.
    const has_diags = count > 0;
    result = .{
        .status = @intFromEnum(if (has_diags) Status.diagnostics else Status.ok),
        .payload_ptr = if (payload) |p| ptrOf(p) else 0,
        .payload_len = if (payload) |p| @intCast(p.len) else 0,
        .diagnostics_ptr = if (diagnostics) |d| ptrOf(d) else 0,
        .diagnostics_len = if (diagnostics) |d| @intCast(d.len) else 0,
    };
    return &result;
}

/// Begin an operation: reject an uninitialized module, then drop the
/// previous operation's working set.
///
/// Every export calls this first, which is what makes "valid until the
/// next call" true of both the payload and the diagnostics.
pub fn begin() ?Status {
    if (!initialized) return .not_initialized;
    arena_used = null_guard;
    return null;
}

// ---------- diagnostics (§5) ----------

/// Encode gero-lang diagnostics as the JSON array a host renders in
/// its gutter.
///
/// The objects come from `gero.diagnostics_json`, the same writer
/// `gero check --format=json` uses — so an error's wording, code, and
/// span are identical in a terminal and in a browser. That is a
/// deliberate single source of truth (§5), not a coincidence to be
/// re-verified.
pub fn encodeLangDiagnostics(
    arena: std.mem.Allocator,
    file: gero.lang.render.FileDiagnostics,
) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try jw.beginArray();
    for (file.diagnostics) |d| try gero.diagnostics_json.writeLang(&jw, file, d);
    try jw.endArray();
    return out.written();
}

/// Encode asm diagnostics as the same JSON array.
pub fn encodeAsmDiagnostics(
    arena: std.mem.Allocator,
    source_map: gero.asm_.SourceMap,
    diagnostics: []const gero.asm_.Diagnostic,
) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try jw.beginArray();
    for (diagnostics) |d| try gero.diagnostics_json.writeAsm(&jw, source_map, d);
    try jw.endArray();
    return out.written();
}

// ---------- the virtual file set (§4.2) ----------

/// The session's source buffers. Outlives an operation's arena, so it
/// carries its own storage — see `file_store`.
var file_set: files.Set = undefined;
var file_store: [max_file_bytes]u8 = undefined;
var file_used: usize = 0;

/// Ceiling on the file set's own storage. Separate from the operation
/// arena because buffers survive `gero_reset`, and an operation must
/// not be able to evict the sources it is compiling.
pub const max_file_bytes: usize = 4 * 1024 * 1024;

fn fileAllocFn(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    const a = @max(alignment.toByteUnits(), @alignOf(u64));
    const aligned = std.mem.alignForward(usize, file_used, a);
    if (aligned + len > max_file_bytes) return null;
    file_used = aligned + len;
    return file_store[aligned..].ptr;
}

const file_vtable: std.mem.Allocator.VTable = .{
    .alloc = fileAllocFn,
    .resize = Arena.resizeFn,
    .remap = Arena.remapFn,
    .free = Arena.freeFn,
};

/// Allocator backing the file set. Bump-only like the operation arena;
/// `gero_files_clear` is the reset.
fn fileAllocator() std.mem.Allocator {
    return .{ .ptr = undefined, .vtable = &file_vtable };
}

/// Add a buffer to the set, or replace one of the same name.
/// `name` and `contents` are `(ptr, len)` into the operation arena.
export fn gero_file_put(name_ptr: u32, name_len: u32, src_ptr: u32, src_len: u32) u32 {
    if (!ready()) return @intFromEnum(Status.not_initialized);
    const name = slice(name_ptr, name_len) orelse return @intFromEnum(Status.bad_argument);
    const contents = slice(src_ptr, src_len) orelse return @intFromEnum(Status.bad_argument);
    file_set.put(name, contents) catch return @intFromEnum(Status.out_of_memory);
    return @intFromEnum(Status.ok);
}

/// Drop a buffer. Removing one that is not present is not an error.
export fn gero_file_remove(name_ptr: u32, name_len: u32) u32 {
    if (!ready()) return @intFromEnum(Status.not_initialized);
    const name = slice(name_ptr, name_len) orelse return @intFromEnum(Status.bad_argument);
    file_set.remove(name);
    return @intFromEnum(Status.ok);
}

/// Empty the set and reclaim its storage.
export fn gero_files_clear() void {
    file_set.clear();
    file_used = 0;
}

/// How many buffers the set holds.
export fn gero_file_count() u32 {
    // safety: bounded by the file store's capacity.
    return @intCast(file_set.count());
}

// ---------- identity ----------

/// The gero version this module was built from, as `(ptr, len)` in the
/// `Result`'s payload. The worker's `ready` event carries it (§3.2) so
/// a host can show which toolchain produced the images it is running.
export fn gero_version() *const Result {
    if (begin()) |status| return fail(status);
    const arena = allocator();
    const copy = arena.dupe(u8, gero.VERSION) catch return fail(.out_of_memory);
    return finish(copy, null, 0);
}

// ---------- tests ----------

const testing = std.testing;

test "gero_init: the arena is unusable until it is called" {
    initialized = false;
    // A host that skips init must get a status, not a trap or a wild
    // pointer — the same reason `alloc` reports rather than traps.
    try testing.expectEqual(@as(u32, 0), gero_alloc(16));
    try testing.expectEqual(@intFromEnum(Status.not_initialized), gero_version().status);
}

test "gero_init: a request past the ceiling is clamped" {
    _ = gero_init(std.math.maxInt(u32));
    try testing.expectEqual(max_arena_bytes, arena_limit);
    _ = gero_init(0);
    try testing.expectEqual(max_arena_bytes, arena_limit);
}

test "alloc: reports exhaustion rather than trapping" {
    _ = gero_init(4096);
    // Reporting is the whole reason the module carries its own
    // allocator: a host can raise its ceiling and retry instead of
    // meeting an instance that has to be thrown away.
    try testing.expectEqual(@as(u32, 0), gero_alloc(1 << 20));
    // Still usable afterwards.
    try testing.expect(gero_alloc(128) != 0);
}

test "gero_reset: hands the same memory back out" {
    _ = gero_init(0);
    const first = gero_alloc(64);
    try testing.expect(first != 0);
    gero_reset();
    try testing.expectEqual(@as(u32, 0), gero_arena_used());
    try testing.expectEqual(first, gero_alloc(64));
}

test "alloc: no live allocation has pointer 0" {
    _ = gero_init(0);
    // Exports signal failure with a null pointer, so a valid first
    // allocation must not land on offset 0 and look like one.
    try testing.expect(gero_alloc(1) != 0);
}

test "Result: the encoded size a host decodes against" {
    // A host reads five u32s at fixed offsets. If this changes, every
    // decoder breaks, so it is pinned here as well as exported.
    try testing.expectEqual(@as(usize, 20), Result.encoded_size);
    try testing.expectEqual(@sizeOf(Result), Result.encoded_size);
    try testing.expectEqual(@as(u32, 20), gero_result_size());
}

test "finish: an empty diagnostics array does not read as diagnostics" {
    _ = gero_init(0);
    const arena = allocator();
    // `[]` is what an operation with nothing to report produces, and it
    // must not flip the status — a host branches on the status, not on
    // whether the array happens to be empty.
    const r = finish(try arena.dupe(u8, "payload"), try arena.dupe(u8, "[]"), 0);
    try testing.expectEqual(@intFromEnum(Status.ok), r.status);
    try testing.expectEqual(@as(u32, 7), r.payload_len);
}

test "finish: reported diagnostics set the status" {
    _ = gero_init(0);
    const arena = allocator();
    const r = finish(null, try arena.dupe(u8, "[{\"code\":\"E001\"}]"), 1);
    try testing.expectEqual(@intFromEnum(Status.diagnostics), r.status);
    try testing.expectEqual(@as(u32, 0), r.payload_ptr);
    try testing.expect(r.diagnostics_len > 0);
}

test "slice: a pointer outside the arena is refused" {
    _ = gero_init(0);
    const p = gero_alloc(32);
    try testing.expect(slice(p, 32) != null);
    // A stale or invented pointer must not be dereferenced.
    try testing.expect(slice(0, 1) == null);
    try testing.expect(slice(p, max_arena_bytes) == null);
}

test "encodeLangDiagnostics: emits the shape a host decodes" {
    _ = gero_init(0);
    const arena = allocator();
    const src = "def main()\n  print undefined_thing()\nend\n";

    const stream = try gero.lang.tokenize(arena, src);
    var tree = try gero.lang.parse(arena, src, stream);
    const checked = try gero.lang.typecheck(arena, src, &tree.program);
    try testing.expect(checked.diagnostics.len > 0);

    const json = try encodeLangDiagnostics(arena, .{
        .path = "main.gr",
        .source = src,
        .diagnostics = checked.diagnostics,
    });

    // Runs the real pipeline through the module's own arena — which is
    // what proves the allocator is usable by the library, not just by
    // these tests.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const first = parsed.value.array.items[0].object;
    try testing.expectEqualStrings("E_UNDEFINED_SYMBOL", first.get("code").?.string);
    try testing.expectEqualStrings("main.gr", first.get("file").?.string);
}

// ---------- toolchain exports (§2.2) ----------

/// Compile the named entry file to a `.gx`, resolving `use` against
/// the virtual file set.
export fn gero_compile(name_ptr: u32, name_len: u32) *const Result {
    if (begin()) |status| return fail(status);
    const name = slice(name_ptr, name_len) orelse return fail(.bad_argument);
    return buildGr(name, .image);
}

/// Assemble the named entry file to a `.gx`, resolving `include`
/// against the virtual file set.
export fn gero_assemble(name_ptr: u32, name_len: u32) *const Result {
    if (begin()) |status| return fail(status);
    const name = slice(name_ptr, name_len) orelse return fail(.bad_argument);
    return buildGas(name, .image);
}

/// Diagnostics for the named entry file, with no image — the editor's
/// fast path.
export fn gero_check(name_ptr: u32, name_len: u32, lang: u32) *const Result {
    if (begin()) |status| return fail(status);
    const name = slice(name_ptr, name_len) orelse return fail(.bad_argument);
    return switch (Lang.from(lang) orelse return fail(.bad_lang)) {
        .gr => buildGr(name, .diagnostics_only),
        .gas => buildGas(name, .diagnostics_only),
    };
}

/// Canonical formatting of a single buffer. Formatting is per-buffer
/// rather than per-graph: an editor formats the file in front of it,
/// and a `use` target's own formatting is its own business.
export fn gero_format(src_ptr: u32, src_len: u32, lang: u32) *const Result {
    if (begin()) |status| return fail(status);
    const src = slice(src_ptr, src_len) orelse return fail(.bad_argument);
    const which = Lang.from(lang) orelse return fail(.bad_lang);
    const arena = allocator();

    const formatted = switch (which) {
        .gr => formatGr(arena, src),
        .gas => formatGas(arena, src),
    } catch return fail(.out_of_memory);

    // A buffer that does not parse formats to nothing rather than to a
    // rewrite from a partial tree — the same rule the language server
    // follows, for the same reason.
    return finish(formatted, null, 0);
}

/// Disassemble a `.gx` into annotated assembly. `bank` selects a bank
/// window, or `no_bank` for the base image.
export fn gero_disasm(gx_ptr: u32, gx_len: u32, bank: u32) *const Result {
    if (begin()) |status| return fail(status);
    const image = slice(gx_ptr, gx_len) orelse return fail(.bad_argument);
    const arena = allocator();

    const header = gero.disasm.parseHeader(image) catch return fail(.bad_argument);
    const region = if (bank == no_bank) header.image else blk: {
        if (bank >= header.bank_count) return fail(.bad_argument);
        const window = gero.gx.bank_disk_size;
        const start = @as(usize, bank) * window;
        break :blk header.banks[start .. start + window];
    };

    var out = std.Io.Writer.Allocating.init(arena);
    gero.disasm.writeBytes(arena, &out.writer, region) catch return fail(.out_of_memory);
    return finish(out.written(), null, 0);
}

/// `bank` value selecting the base image rather than a bank window.
pub const no_bank: u32 = 0xFFFF_FFFF;

// ---------- pipelines ----------

/// Whether an operation wants the image, or only what is wrong.
const Want = enum { image, diagnostics_only };

/// Resolve, parse, type-check, and optionally lower a `.gr` entry.
///
/// Every phase reads from the virtual file set, never from a
/// filesystem — the resolver's `virtual` source makes a name the set
/// does not hold a not-found diagnostic rather than a read.
fn buildGr(name: []const u8, want: Want) *const Result {
    const arena = allocator();

    var fused = gero.lang.resolveUseImportsVirtual(arena, name, &file_set.map) catch
        return fail(.out_of_memory);
    if (fused.hasErrors()) return includeDiagnostics(arena, fused);

    const stream = gero.lang.tokenize(arena, fused.source) catch return fail(.out_of_memory);
    var tree = gero.lang.parseAllModules(arena, fused.source, stream, &fused.source_map) catch
        return fail(.out_of_memory);
    if (tree.errors.len > 0) return langDiagnostics(arena, fused, tree.errors);

    var checked = gero.lang.typecheckGraph(arena, fused.source, &tree.program, &fused.import_aliases, .{
        .source_map = &fused.source_map,
        .imports = fused.imports,
    }) catch return fail(.out_of_memory);
    checked.program = &tree.program;
    if (checked.hasErrors() or want == .diagnostics_only) {
        return reportLang(arena, fused, checked.diagnostics);
    }

    const compiled = gero.lang.compile(arena, fused.source, &checked, .{
        .import_aliases = &fused.import_aliases,
        .graph = .{ .source_map = &fused.source_map, .imports = fused.imports },
    }) catch return fail(.out_of_memory);
    if (compiled.hasErrors()) return reportLang(arena, fused, compiled.diagnostics);
    return finish(compiled.image, null, 0);
}

/// Resolve, parse, and optionally assemble a `.gas` entry.
fn buildGas(name: []const u8, want: Want) *const Result {
    const arena = allocator();

    const fused = gero.asm_.resolveIncludesVirtual(arena, name, &file_set.map) catch
        return fail(.out_of_memory);
    if (fused.errors.len > 0) return reportAsm(arena, fused.source_map, fused.errors);

    const pt = gero.asm_.parse(arena, fused.source) catch return fail(.out_of_memory);
    // Both passes run and both error sets are reported: an unknown
    // mnemonic parses cleanly and only fails at opcode resolution, so
    // stopping at the parse would hide it.
    const cg = gero.asm_.assemble(arena, fused.source, pt, .{ .source_map = &fused.source_map }) catch
        return fail(.out_of_memory);

    if (pt.errors.len > 0 or cg.errors.len > 0) {
        var all: std.ArrayList(gero.asm_.Diagnostic) = .empty;
        all.appendSlice(arena, pt.errors) catch return fail(.out_of_memory);
        all.appendSlice(arena, cg.errors) catch return fail(.out_of_memory);
        return reportAsm(arena, fused.source_map, all.items);
    }
    if (want == .diagnostics_only) return finish(null, null, 0);
    return finish(cg.image, null, 0);
}

fn formatGr(arena: std.mem.Allocator, src: []const u8) !?[]const u8 {
    const stream = gero.lang.tokenize(arena, src) catch return null;
    var tree = gero.lang.parse(arena, src, stream) catch return null;
    if (tree.errors.len > 0) return null;
    var out = std.Io.Writer.Allocating.init(arena);
    gero.lang.print(&out.writer, &tree.program, src, tree.comments) catch return null;
    return out.written();
}

fn formatGas(arena: std.mem.Allocator, src: []const u8) !?[]const u8 {
    const pt = gero.asm_.parse(arena, src) catch return null;
    if (pt.errors.len > 0) return null;
    var out = std.Io.Writer.Allocating.init(arena);
    gero.asm_.printProgram(&out.writer, &pt.program, src, gero.asm_.default_print_options) catch return null;
    return out.written();
}

// ---------- reporting ----------

/// Report lang diagnostics, attributed to the files they came from.
fn reportLang(
    arena: std.mem.Allocator,
    fused: gero.lang.FusedSource,
    diagnostics: []const gero.lang.Diagnostic,
) *const Result {
    if (diagnostics.len == 0) return finish(null, null, 0);
    const json = encodeLangDiagnostics(arena, .{
        .path = entryPath(fused),
        .source = fused.source,
        .diagnostics = diagnostics,
    }) catch return fail(.out_of_memory);
    return finish(null, json, diagnostics.len);
}

fn langDiagnostics(
    arena: std.mem.Allocator,
    fused: gero.lang.FusedSource,
    errors: anytype,
) *const Result {
    var out: std.ArrayList(gero.lang.Diagnostic) = .empty;
    for (errors) |e| {
        out.append(arena, .{
            .severity = .fatal,
            .code = e.expected orelse "E_SYNTAX_GENERIC",
            .message = e.message,
            // safety: a fused-buffer index, bounded well under 4 GiB.
            .span = .{ .start = @intCast(e.index), .end = @intCast(e.index) },
        }) catch return fail(.out_of_memory);
    }
    return reportLang(arena, fused, out.items);
}

/// Report `use`-resolution failures — a missing or cyclic target.
fn includeDiagnostics(arena: std.mem.Allocator, fused: gero.lang.FusedSource) *const Result {
    var out: std.ArrayList(gero.lang.Diagnostic) = .empty;
    for (fused.errors) |e| {
        out.append(arena, .{
            .severity = .fatal,
            .code = switch (e.kind) {
                .cycle => "E_USE_CYCLE",
                .depth_exceeded => "E_USE_DEPTH",
                .not_found => "E_USE_NOT_FOUND",
                .duplicate_alias => "E_USE_DUPLICATE_ALIAS",
            },
            .message = switch (e.kind) {
                .cycle => "`use` cycle detected",
                .depth_exceeded => "`use` depth exceeds 32 — likely runaway recursion",
                .not_found => "`use` target is not in the file set",
                .duplicate_alias => "import alias is bound to two different targets",
            },
            .span = .{ .start = e.site_offset, .end = e.site_offset },
        }) catch return fail(.out_of_memory);
    }
    return reportLang(arena, fused, out.items);
}

fn reportAsm(
    arena: std.mem.Allocator,
    source_map: gero.asm_.SourceMap,
    diagnostics: []const gero.asm_.Diagnostic,
) *const Result {
    if (diagnostics.len == 0) return finish(null, null, 0);
    const json = encodeAsmDiagnostics(arena, source_map, diagnostics) catch
        return fail(.out_of_memory);
    return finish(null, json, diagnostics.len);
}

/// Name of the file resolution started from, for diagnostics that
/// carry no file of their own.
fn entryPath(fused: gero.lang.FusedSource) []const u8 {
    if (fused.entry_module < fused.source_map.files.items.len) {
        return fused.source_map.files.items[fused.entry_module].path;
    }
    return "";
}

/// The debug tables from a `.gx`, as JSON: the symbols that drive a
/// disassembly's label column, and the line rows that drive
/// source-level stepping and click-to-breakpoint (§6).
///
/// Separate from the build result rather than a sixth `Result` field:
/// the tables live in the image the build already returned, a host
/// wants them once per build rather than on every operation, and a
/// release image carries neither.
export fn gero_debug_info(gx_ptr: u32, gx_len: u32) *const Result {
    if (begin()) |status| return fail(status);
    const image = slice(gx_ptr, gx_len) orelse return fail(.bad_argument);
    const arena = allocator();

    const header = gero.disasm.parseHeader(image) catch return fail(.bad_argument);
    var out = std.Io.Writer.Allocating.init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };

    writeDebugJson(arena, &jw, header.debug) catch return fail(.out_of_memory);
    return finish(out.written(), null, 0);
}

fn writeDebugJson(
    arena: std.mem.Allocator,
    jw: *std.json.Stringify,
    debug: []const u8,
) !void {
    try jw.beginObject();

    try jw.objectField("symbols");
    try jw.beginArray();
    if (debug.len > 0) {
        const syms = gero.disasm.parseSymbols(arena, debug) catch gero.disasm.Symbols{ .entries = &.{} };
        for (syms.entries) |sym| {
            try jw.beginObject();
            try jw.objectField("address");
            try jw.write(sym.address);
            try jw.objectField("kind");
            try jw.write(switch (sym.kind) {
                .label => "label",
                .data => "data",
                else => "unknown",
            });
            try jw.objectField("name");
            try jw.write(sym.name);
            try jw.endObject();
        }
    }
    try jw.endArray();

    try jw.objectField("files");
    try jw.beginArray();
    const files_chunk = if (debug.len > 0) (gero.gx.findChunk(debug, .files) catch null) else null;
    const paths: []const []const u8 = if (files_chunk) |p|
        gero.gx.decodeFiles(arena, p) catch &.{}
    else
        &.{};
    for (paths) |path| try jw.write(path);
    try jw.endArray();

    try jw.objectField("lines");
    try jw.beginArray();
    const lines_chunk = if (debug.len > 0) (gero.gx.findChunk(debug, .lines) catch null) else null;
    if (lines_chunk) |p| {
        const rows = gero.gx.decodeLines(arena, p) catch &.{};
        for (rows) |row| {
            try jw.beginObject();
            try jw.objectField("start");
            try jw.write(row.start_addr);
            try jw.objectField("end");
            try jw.write(row.end_addr);
            try jw.objectField("file");
            try jw.write(row.file);
            try jw.objectField("line");
            try jw.write(row.line);
            try jw.objectField("column");
            try jw.write(row.column);
            try jw.endObject();
        }
    }
    try jw.endArray();

    try jw.endObject();
}

test "input survives an operation's scratch reset" {
    _ = gero_init(0);
    // The bug this shape prevents: an export resets scratch on entry,
    // and if input shared that region it would free its own arguments
    // before reading them. Input grows from the opposite end.
    const p = gero_alloc(16);
    try testing.expect(isInput(p, 16));
    _ = begin();
    try testing.expect(isInput(p, 16));
    try testing.expect(slice(p, 16) != null);
}

test "gero_reset: reclaims input as well as scratch" {
    _ = gero_init(0);
    const first = gero_alloc(64);
    _ = alloc(64);
    try testing.expect(gero_arena_used() > 64);
    gero_reset();
    try testing.expectEqual(@as(u32, 0), gero_arena_used());
    // The same input address comes back, so nothing leaked.
    try testing.expectEqual(first, gero_alloc(64));
}

test "the two cursors cannot cross" {
    _ = gero_init(4096);
    // Scratch and input share one region from opposite ends, so
    // exhaustion is when they meet — not when either alone runs out.
    try testing.expect(gero_alloc(3000) != 0);
    try testing.expect(alloc(3000) == null);
    try testing.expect(gero_alloc(3000) == 0);
}

test "gero_file_put: replacing a buffer keeps the set's size" {
    _ = gero_init(0);
    try file_set.put("main.gr", "def main()\nend\n");
    try file_set.put("main.gr", "def main()\n  print 1\nend\n");
    try testing.expectEqual(@as(usize, 1), file_set.count());
    try testing.expect(std.mem.indexOf(u8, file_set.map.get("main.gr").?, "print") != null);
}

test "buildGr: a use target outside the set is a diagnostic, not a read" {
    _ = gero_init(0);
    // Resolution is closed (§4.2): the set is the whole filesystem, so
    // a name it does not hold cannot fall through to a disk or a fetch.
    try file_set.put("main.gr", "use \"./nope\"\ndef main()\n  print 1\nend\n");
    const r = buildGr("main.gr", .image);
    try testing.expectEqual(@intFromEnum(Status.diagnostics), r.status);
    const json = arena_store[r.diagnostics_ptr..][0..r.diagnostics_len];
    try testing.expect(std.mem.indexOf(u8, json, "E_USE_NOT_FOUND") != null);
}

test "buildGr: a multi-file program compiles from the set alone" {
    _ = gero_init(0);
    try file_set.put("lib.gr", "def double(n: i16) -> i16\n  return n * 2\nend\n");
    try file_set.put("main.gr", "use \"./lib\"\ndef main()\n  print double(21)\nend\n");
    const r = buildGr("main.gr", .image);
    try testing.expectEqual(@intFromEnum(Status.ok), r.status);
    try testing.expect(r.payload_len > 0);
    try testing.expectEqualStrings("GERO", arena_store[r.payload_ptr..][0..4]);
}

test "buildGas: an include target resolves from the set" {
    _ = gero_init(0);
    try file_set.put("helper.gas", "double:\n  add r1, r1\n  ret\n");
    try file_set.put("m.gas", "include \"helper.gas\"\nmain:\n  call @double\n  hlt\n");
    const r = buildGas("m.gas", .image);
    try testing.expectEqual(@intFromEnum(Status.ok), r.status);
    try testing.expectEqualStrings("GERO", arena_store[r.payload_ptr..][0..4]);
}

test "buildGas: parse and resolution errors are reported together" {
    _ = gero_init(0);
    // An unknown mnemonic parses cleanly and only fails at opcode
    // resolution, so reporting just the parse would hide it.
    try file_set.put("m.gas", "start:\n  mov r0, 1\n  bogus r1\n  hlt\n");
    const r = buildGas("m.gas", .diagnostics_only);
    try testing.expectEqual(@intFromEnum(Status.diagnostics), r.status);
    const json = arena_store[r.diagnostics_ptr..][0..r.diagnostics_len];
    try testing.expect(std.mem.indexOf(u8, json, "E001") != null);
}

test "check: a clean program reports nothing and returns no image" {
    _ = gero_init(0);
    try file_set.put("main.gr", "def main()\n  print 1\nend\n");
    const r = buildGr("main.gr", .diagnostics_only);
    try testing.expectEqual(@intFromEnum(Status.ok), r.status);
    try testing.expectEqual(@as(u32, 0), r.payload_len);
}
