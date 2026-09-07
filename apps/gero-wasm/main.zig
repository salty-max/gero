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
/// Bump cursor into `arena_store`.
///
/// Starts past offset 0 so that no live allocation ever has pointer
/// `0`: exports report failure by returning a null pointer, and an
/// offset-based scheme would otherwise make a perfectly good first
/// allocation indistinguishable from that failure.
var arena_used: usize = null_guard;

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
    initialized = true;
    return @intFromEnum(Status.ok);
}

/// Drop everything allocated since the last reset. A host calls this
/// between operations; the exports call it on entry themselves, so it
/// exists for hosts that want to reclaim memory while idle.
export fn gero_reset() void {
    arena_used = null_guard;
}

/// Reserve `len` bytes and return a pointer a host can write into —
/// how source text gets *in*. Returns 0 when the arena cannot satisfy
/// it, which a host must check.
export fn gero_alloc(len: u32) u32 {
    if (!initialized) return 0;
    const bytes = alloc(len) orelse return 0;
    return ptrOf(bytes);
}

/// Bytes the arena has handed out since the last reset. For a host
/// sizing its ceiling, and for tests.
export fn gero_arena_used() u32 {
    // safety: bounded by `arena_limit`, itself capped at 16 MiB.
    return @intCast(arena_used - null_guard);
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
    if (aligned + len > arena_limit) return null;
    arena_used = aligned + len;
    return arena_store[aligned .. aligned + len];
}

/// An allocator over the arena, for the library entry points.
const Arena = struct {
    fn allocFn(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const a = @max(alignment.toByteUnits(), @alignOf(u64));
        const aligned = std.mem.alignForward(usize, arena_used, a);
        if (aligned + len > arena_limit) return null;
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
