//! Session state for `gero.wasm`: the arena a host writes through, and
//! the virtual file set an operation resolves against.
//!
//! A wasm module is a state machine by nature — a host calls exports in
//! order and each one sees what the last left behind. This file is
//! where that state lives, so the rest of the module can be read as
//! ordinary functions over it.
//!
//! The two memory regions have different lifetimes and that difference
//! is the whole design; `docs/gero-lab.md` §2.1 explains why.

const std = @import("std");
const abi = @import("abi.zig");
const files = @import("files.zig");

const Status = abi.Status;
const Result = abi.Result;

// ---------- memory (§2.1) ----------

/// Backing store for the module's arena. Freestanding wasm has no
/// allocator, so the module brings its own: one fixed region, carved
/// by a bump pointer, reset per operation.
///
/// Sized for the largest program the ISA can express — a 64 KiB image
/// plus its sources, diagnostics, and intermediate trees — with room
/// to spare. A host that wants a different ceiling passes one to
/// `gero_init`.
// `align(16)` so aligning an *offset* into the store also aligns the
// resulting address: the allocator hands out `base + offset`, and an
// unaligned base would make every alignment guarantee a lie.
var arena_store: [max_arena_bytes]u8 align(16) = undefined;

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

/// The single `Result` every export writes into and returns a pointer
/// to. One slot, so a host must read it before the next call — which
/// is the same rule the arena already imposes on payloads.
var result: Result = undefined;
/// The session's source buffers. Outlives an operation's arena, so it
/// carries its own storage — see `file_store`.
var file_set: files.Set = undefined;
var file_store: [max_file_bytes]u8 align(16) = undefined;
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

// ---------- lifecycle ----------

/// Prepare the session. `arena_bytes` of 0 takes the default; a larger
/// request is clamped. Calling it again starts over, which is how a
/// host recovers after raising its ceiling.
pub fn init(arena_bytes: u32) void {
    arena_limit = if (arena_bytes == 0) max_arena_bytes else @min(@as(usize, arena_bytes), max_arena_bytes);
    arena_used = null_guard;
    input_top = arena_limit;
    file_used = 0;
    file_set = files.Set.init(fileAllocator());
    initialized = true;
}

/// Drop the last operation's scratch **and** the inputs a host wrote
/// for it. Operations reset only scratch, so this is how input memory
/// is reclaimed.
pub fn reset() void {
    arena_used = null_guard;
    input_top = arena_limit;
}

/// Reserve `len` bytes of input and return its pointer, or 0 when the
/// region cannot satisfy it.
pub fn reserveInput(len: u32) u32 {
    if (!initialized) return 0;
    const bytes = allocInput(len) orelse return 0;
    return ptrOf(bytes);
}

/// Bytes handed out since the last reset — scratch plus input.
pub fn usedBytes() u32 {
    // safety: bounded by `arena_limit`, itself capped at 16 MiB.
    return @intCast((arena_used - null_guard) + (arena_limit - input_top));
}

/// The session's arena ceiling.
pub fn limitBytes() u32 {
    // safety: capped at `max_arena_bytes`.
    return @intCast(arena_limit);
}

/// Where the arena begins in linear memory. Every pointer the module
/// hands out is an offset from here.
pub fn base() u32 {
    // safety: the arena is a static region, well inside a 32-bit space
    // on the target this module is built for.
    return @intCast(@intFromPtr(&arena_store));
}

// ---------- the virtual file set (§4.2) ----------

/// The buffers an operation resolves `use` and `include` against.
pub fn fileSet() *const files.Set {
    return &file_set;
}

/// Add a buffer, or replace one of the same name.
pub fn putFile(name: []const u8, contents: []const u8) !void {
    return file_set.put(name, contents);
}

/// Drop a buffer. Removing an absent one is not an error.
pub fn removeFile(name: []const u8) void {
    file_set.remove(name);
}

/// Empty the set and reclaim its storage.
pub fn clearFiles() void {
    file_set.clear();
    file_used = 0;
}

/// How many buffers the set holds.
pub fn fileCount() u32 {
    // safety: bounded by the file store's capacity.
    return @intCast(file_set.count());
}

/// A failure that carries an explanation — a `.gx` that will not load
/// says *why*, in the same words a terminal would use, rather than
/// leaving a host to translate a status code.
///
/// The message rides in the diagnostics field: it is prose for a
/// person, which is what that field already carries.
pub fn failWith(status: Status, message: []const u8) *const Result {
    result = .{
        .status = @intFromEnum(status),
        .payload_ptr = 0,
        .payload_len = 0,
        .diagnostics_ptr = ptrOf(message),
        // safety: a bounded message, far under 4 GiB.
        .diagnostics_len = @intCast(message.len),
    };
    return &result;
}

/// A payload plus a count of bytes dropped on the way to producing it.
///
/// Used by the print drain: a program can outrun its buffer, and the
/// count is how that stays visible instead of silently truncating.
pub fn finishWithDropped(payload: []const u8, dropped: u64) *const Result {
    result = .{
        .status = @intFromEnum(Status.ok),
        .payload_ptr = ptrOf(payload),
        // safety: a bounded buffer, far under 4 GiB.
        .payload_len = @intCast(payload.len),
        .diagnostics_ptr = 0,
        // safety: clamped so a huge drop count still reports non-zero.
        .diagnostics_len = @intCast(@min(dropped, std.math.maxInt(u32))),
    };
    return &result;
}

/// The bytes a `Result`'s payload points at. Resolving a pointer is
/// the arena's job, so a caller — a test, or the module's own code —
/// does not reach into its storage to do it.
pub fn payloadOf(r: *const Result) []const u8 {
    return arena_store[r.payload_ptr..][0..r.payload_len];
}

/// The bytes a `Result`'s diagnostics point at.
pub fn diagnosticsOf(r: *const Result) []const u8 {
    return arena_store[r.diagnostics_ptr..][0..r.diagnostics_len];
}

// ---------- tests ----------

const testing = std.testing;

test "init: the arena is unusable until it is called" {
    initialized = false;
    // A host that skips init must get a status, not a trap or a wild
    // pointer — the same reason `alloc` reports rather than traps.
    try testing.expectEqual(@as(u32, 0), reserveInput(16));
    try testing.expect(begin() != null);
}

test "init: a request past the ceiling is clamped" {
    init(std.math.maxInt(u32));
    try testing.expectEqual(max_arena_bytes, arena_limit);
    init(0);
    try testing.expectEqual(max_arena_bytes, arena_limit);
}

test "alloc: reports exhaustion rather than trapping" {
    init(4096);
    // Reporting is the whole reason the module carries its own
    // allocator: a host can raise its ceiling and retry instead of
    // meeting an instance that has to be thrown away.
    try testing.expectEqual(@as(u32, 0), reserveInput(1 << 20));
    try testing.expect(reserveInput(128) != 0);
}

test "alloc: no live allocation has pointer 0" {
    init(0);
    // Exports signal failure with a null pointer, so a valid first
    // allocation must not land on offset 0 and look like one.
    try testing.expect(reserveInput(1) != 0);
}

test "input survives an operation's scratch reset" {
    init(0);
    // The bug this shape prevents: an operation resets scratch on
    // entry, and if input shared that region it would free its own
    // arguments before reading them.
    const p = reserveInput(16);
    try testing.expect(isInput(p, 16));
    _ = begin();
    try testing.expect(isInput(p, 16));
    try testing.expect(slice(p, 16) != null);
}

test "reset: reclaims input as well as scratch" {
    init(0);
    const first = reserveInput(64);
    _ = alloc(64);
    try testing.expect(usedBytes() > 64);
    reset();
    try testing.expectEqual(@as(u32, 0), usedBytes());
    // The same input address comes back, so nothing leaked.
    try testing.expectEqual(first, reserveInput(64));
}

test "reset: hands the same scratch memory back out" {
    init(0);
    const first = alloc(64).?;
    reset();
    // A bump arena reclaims in bulk, so the next operation starts from
    // the same place rather than drifting upward each time.
    try testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(alloc(64).?.ptr));
}

test "the two cursors cannot cross" {
    init(4096);
    // Scratch and input share one region from opposite ends, so
    // exhaustion is when they meet — not when either alone runs out.
    try testing.expect(reserveInput(3000) != 0);
    try testing.expect(alloc(3000) == null);
    try testing.expect(reserveInput(3000) == 0);
}

test "slice: a pointer outside the arena is refused" {
    init(0);
    const p = reserveInput(32);
    try testing.expect(slice(p, 32) != null);
    // A stale or invented pointer must not be dereferenced.
    try testing.expect(slice(0, 1) == null);
    try testing.expect(slice(p, max_arena_bytes) == null);
}

test "finish: an empty diagnostics array does not read as diagnostics" {
    init(0);
    const arena = allocator();
    // `[]` is what an operation with nothing to report produces, and it
    // must not flip the status — a host branches on the status, not on
    // whether the array happens to be empty.
    const r = finish(try arena.dupe(u8, "payload"), try arena.dupe(u8, "[]"), 0);
    try testing.expectEqual(@intFromEnum(Status.ok), r.status);
    try testing.expectEqualStrings("payload", payloadOf(r));
}

test "finish: reported diagnostics set the status" {
    init(0);
    const arena = allocator();
    const r = finish(null, try arena.dupe(u8, "[{\"code\":\"E001\"}]"), 1);
    try testing.expectEqual(@intFromEnum(Status.diagnostics), r.status);
    try testing.expectEqual(@as(u32, 0), r.payload_ptr);
    try testing.expect(r.diagnostics_len > 0);
}

test "putFile: replacing a buffer keeps the set's size" {
    init(0);
    try putFile("main.gr", "def main()\nend\n");
    try putFile("main.gr", "def main()\n  print 1\nend\n");
    try testing.expectEqual(@as(u32, 1), fileCount());
    try testing.expect(std.mem.indexOf(u8, fileSet().map.get("main.gr").?, "print") != null);
}
