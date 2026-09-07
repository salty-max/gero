//! VM sessions behind the `gero_vm_*` exports.
//!
//! A host creates a session, loads a `.gx` into it, and drives it a
//! slice of instructions at a time (`docs/gero-lab.md` §3.3). Several
//! sessions coexist, each with its own machine, memory, and output.
//!
//! Sessions outlive an operation, so they carry their own storage
//! rather than the arena's — an operation's reset must not be able to
//! free a running program's RAM.

const std = @import("std");
const gero = @import("gero");
const abi = @import("abi.zig");

const Status = abi.Status;

/// How many sessions can exist at once. Fixed because the storage is
/// static: a browser tab running more than a handful of VMs at once is
/// not a case worth sizing for.
pub const max_sessions: usize = 4;

/// Per-session storage: RAM, bank pool, the loaded image, and the
/// snapshot `reset` re-boots from.
const session_bytes: usize = 512 * 1024;

/// Per-session print buffer. A host drains it every slice (§3.3), so
/// this only has to absorb one slice's output.
const output_bytes: usize = 16 * 1024;

/// Why `step` stopped. A host branches on this, so the numeric values
/// are part of the boundary.
pub const StepReason = enum(u32) {
    /// The instruction budget ran out; the program is still running.
    budget = 0,
    /// `hlt` — the program finished.
    halted = 1,
    /// `brk` — a breakpoint. `ip` is past it; resuming continues.
    breakpoint = 2,
    /// A fault fired with no handler installed. `fault` names the
    /// vector.
    faulted = 3,
    /// The session has no image loaded.
    not_loaded = 4,
};

/// What a `step` produced, as the `Result`'s payload. Fixed layout,
/// four little-endian `u32`s.
pub const StepOutcome = extern struct {
    reason: u32,
    /// Where execution stopped.
    ip: u32,
    /// Fault vector when `reason` is `faulted`, else 0.
    fault: u32,
    /// Instructions actually retired, which is below the budget when
    /// the program stopped early.
    steps: u32,

    pub const encoded_size: usize = 16;
};

/// A print sink that never fails the program.
///
/// The VM raises invalid-opcode when its writer errors, so a full
/// buffer must not be an error — a program printing faster than the
/// host drains would otherwise fault, which is a lie about the
/// program. Overflow is dropped and counted instead.
const Output = struct {
    writer: std.Io.Writer,
    dropped: u64 = 0,

    fn init(buffer: []u8) Output {
        return .{ .writer = .{ .vtable = &.{ .drain = drain }, .buffer = buffer } };
    }

    /// Called when the buffer is full. Keeps what is already buffered
    /// and discards the overflow, so a host still sees the output that
    /// arrived before the flood.
    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        // safety: `writer` is this struct's first field, so the parent
        // pointer is the Output that owns it.
        const self: *Output = @alignCast(@fieldParentPtr("writer", w));
        const head = data[0 .. data.len - 1];
        const pattern = data[head.len];
        var incoming = pattern.len * splat;
        for (head) |bytes| incoming += bytes.len;
        self.dropped += incoming;
        // Claim it consumed: the program must not observe a failure.
        return incoming;
    }

    fn buffered(self: *const Output) []const u8 {
        return self.writer.buffer[0..self.writer.end];
    }

    fn clear(self: *Output) void {
        self.writer.end = 0;
        self.dropped = 0;
    }
};

const Session = struct {
    live: bool = false,
    /// Bumped on destroy, so a handle held past that is detectable
    /// rather than aliasing whoever gets the slot next.
    generation: u16 = 1,
    machine: gero.vm.VM = undefined,
    output: Output = undefined,
    /// The `.gx` this session booted, kept so `reset` can re-boot it.
    image_len: usize = 0,
    /// Bump cursor into this session's store.
    used: usize = 0,
};

var sessions = [_]Session{.{}} ** max_sessions;
// Aligned for the same reason as the session arena: the allocator
// aligns offsets, so the base has to be aligned for that to mean
// anything.
var stores: [max_sessions][session_bytes]u8 align(16) = undefined;
var outputs: [max_sessions][output_bytes]u8 align(16) = undefined;

// ---------- handles ----------

/// A handle packs a slot index with the generation that occupied it,
/// so a handle held past `destroy` is refused rather than silently
/// addressing whichever session took the slot next. `0` is never
/// valid.
fn makeHandle(index: usize, generation: u16) u32 {
    // safety: index < max_sessions, so the shift cannot overflow u32.
    return (@as(u32, @intCast(index + 1)) << 16) | generation;
}

/// The session a handle names, or `null` when it is stale, out of
/// range, or was never valid.
fn lookup(handle: u32) ?*Session {
    const index = (handle >> 16);
    if (index == 0 or index > max_sessions) return null;
    const slot = &sessions[index - 1];
    if (!slot.live) return null;
    // safety: the low half holds a generation, which is a u16.
    if (slot.generation != @as(u16, @truncate(handle))) return null;
    return slot;
}

/// Allocator over one session's store. Bump-only; the whole store is
/// reclaimed when the session is destroyed or reset.
fn sessionAlloc(index: usize, len: usize, alignment: usize) ?[]u8 {
    const slot = &sessions[index];
    const aligned = std.mem.alignForward(usize, slot.used, @max(alignment, @alignOf(u64)));
    if (aligned + len > session_bytes) return null;
    slot.used = aligned + len;
    return stores[index][aligned .. aligned + len];
}

/// Index of `slot` in the session table, which the allocator vtable
/// recovers from the pointer it is given.
fn indexOf(slot: *const Session) usize {
    // safety: every Session lives in `sessions`, so the difference is
    // its index.
    return (@intFromPtr(slot) - @intFromPtr(&sessions)) / @sizeOf(Session);
}

const SessionAllocator = struct {
    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        // safety: `ctx` is the `*Session` handed to `allocatorFor`.
        const slot: *Session = @ptrCast(@alignCast(ctx));
        const bytes = sessionAlloc(indexOf(slot), len, alignment.toByteUnits()) orelse return null;
        return bytes.ptr;
    }

    fn resizeFn(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remapFn(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    /// Bump-only: a session frees in bulk, on destroy or reset.
    fn freeFn(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };
};

fn allocatorFor(slot: *Session) std.mem.Allocator {
    return .{ .ptr = slot, .vtable = &SessionAllocator.vtable };
}

// ---------- lifecycle ----------

/// Take a free slot and start a session in it. `0` when every slot is
/// in use — reported rather than trapped, like every other ceiling in
/// this module.
pub fn create() u32 {
    for (&sessions, 0..) |*slot, i| {
        if (slot.live) continue;
        slot.live = true;
        slot.used = 0;
        slot.image_len = 0;
        slot.output = Output.init(&outputs[i]);
        slot.machine = gero.vm.VM.init(allocatorFor(slot));
        slot.machine.host = .{ .out = &slot.output.writer };
        return makeHandle(i, slot.generation);
    }
    return 0;
}

/// End a session and free its slot. Bumping the generation is what
/// makes a handle held past this refuse rather than address whoever
/// takes the slot next.
pub fn destroy(handle: u32) Status {
    const slot = lookup(handle) orelse return .bad_argument;
    slot.machine.deinit();
    slot.live = false;
    slot.used = 0;
    slot.image_len = 0;
    slot.generation +%= 1;
    // Generation 0 would collide with the "never valid" handle.
    if (slot.generation == 0) slot.generation = 1;
    return .ok;
}

/// How many sessions are live. For a host, and for tests.
pub fn liveCount() u32 {
    var n: u32 = 0;
    for (&sessions) |*slot| {
        if (slot.live) n += 1;
    }
    return n;
}

// ---------- loading and running ----------

/// Why a load failed, in the words `gero run` would use — the shared
/// `load_error` messages rather than a raw status a host would have to
/// translate.
pub const LoadFailure = struct {
    status: Status,
    message: []const u8,
};

/// Parse `image` and boot it. The image is copied into the session's
/// store, because `reset` re-boots from it and the caller's arena is
/// gone by then.
pub fn load(handle: u32, image: []const u8, message_buf: *[gero.load_error.max_message_len]u8) ?LoadFailure {
    const slot = lookup(handle) orelse
        return .{ .status = .bad_argument, .message = "no such VM session" };

    // Re-booting starts from a clean store, so a reload does not
    // accumulate the previous image's allocations.
    slot.machine.deinit();
    slot.used = 0;
    slot.output.clear();
    slot.machine = gero.vm.VM.init(allocatorFor(slot));
    slot.machine.host = .{ .out = &slot.output.writer };

    const copy = sessionAlloc(indexOf(slot), image.len, 1) orelse
        return .{ .status = .out_of_memory, .message = "image does not fit the session's memory" };
    @memcpy(copy, image);
    slot.image_len = image.len;

    const loaded = gero.vm.parseGx(copy) catch |err| return .{
        .status = .bad_argument,
        .message = gero.load_error.describe(message_buf, err, copy),
    };
    slot.machine.boot(allocatorFor(slot), loaded) catch
        return .{ .status = .out_of_memory, .message = "program does not fit the session's memory" };
    return null;
}

/// Re-boot the loaded image, discarding everything execution changed.
pub fn reset(handle: u32) Status {
    const slot = lookup(handle) orelse return .bad_argument;
    if (slot.image_len == 0) return .bad_argument;

    // The image sits at the base of the store, so rewinding to just
    // past it keeps it while dropping everything booted on top.
    const image = stores[indexOf(slot)][0..slot.image_len];
    slot.machine.deinit();
    slot.used = slot.image_len;
    slot.output.clear();
    slot.machine = gero.vm.VM.init(allocatorFor(slot));
    slot.machine.host = .{ .out = &slot.output.writer };

    const loaded = gero.vm.parseGx(image) catch return .bad_argument;
    slot.machine.boot(allocatorFor(slot), loaded) catch return .out_of_memory;
    return .ok;
}

/// Execute at most `budget` instructions, stopping early on `hlt`,
/// `brk`, or an unhandled fault.
///
/// The reason it stopped is what drives the worker's run loop (§3.3),
/// so the four cases are distinguished rather than collapsed into
/// "still running / not".
pub fn step(handle: u32, budget: u32) ?StepOutcome {
    const slot = lookup(handle) orelse return null;
    if (slot.image_len == 0) {
        return .{ .reason = @intFromEnum(StepReason.not_loaded), .ip = 0, .fault = 0, .steps = 0 };
    }

    var retired: u32 = 0;
    while (retired < budget) : (retired += 1) {
        switch (gero.vm.step(&slot.machine)) {
            .cont, .branched => continue,
            .halted => return outcome(slot, .halted, retired + 1),
            .breakpoint => return outcome(slot, .breakpoint, retired + 1),
            .halted_on_fault => return outcome(slot, .faulted, retired + 1),
        }
    }
    return outcome(slot, .budget, retired);
}

fn outcome(slot: *Session, reason: StepReason, steps: u32) StepOutcome {
    return .{
        .reason = @intFromEnum(reason),
        .ip = slot.machine.regs.read(.ip),
        .fault = if (slot.machine.last_fault) |f| @intFromEnum(f) else 0,
        .steps = steps,
    };
}

// ---------- inspection ----------

/// The register file, as 15 little-endian `u16`s in the order
/// `Register`'s indices define.
pub fn registers(handle: u32, out: *[register_bytes]u8) bool {
    const slot = lookup(handle) orelse return false;
    var i: u8 = 0;
    while (i < register_count) : (i += 1) {
        const value = slot.machine.regs.readByIndex(i) orelse 0;
        gero.gx.writeU16Le(out[i * 2 ..][0..2], value);
    }
    return true;
}

/// Registers in the file, and the bytes they encode to.
pub const register_count: u8 = 15;
pub const register_bytes: usize = register_count * 2;

/// Read `len` bytes from `addr` **through the memory mapper**, so a
/// banked address returns what the running program would see rather
/// than the raw backing store.
pub fn peek(handle: u32, addr: u16, out: []u8) bool {
    const slot = lookup(handle) orelse return false;
    for (out, 0..) |*b, i| {
        // safety: the address space is 16-bit and wraps, which is what
        // a program reading past the end would observe too.
        b.* = slot.machine.readByte(addr +% @as(u16, @intCast(i % 0x10000)));
    }
    return true;
}

/// Write `bytes` at `addr` through the mapper.
pub fn poke(handle: u32, addr: u16, bytes: []const u8) bool {
    const slot = lookup(handle) orelse return false;
    for (bytes, 0..) |b, i| {
        // safety: as `peek` — 16-bit wrapping is the program's view.
        slot.machine.writeByte(addr +% @as(u16, @intCast(i % 0x10000)), b);
    }
    return true;
}

/// Set one register by index.
pub fn setRegister(handle: u32, index: u8, value: u16) Status {
    const slot = lookup(handle) orelse return .bad_argument;
    if (!slot.machine.regs.writeByIndex(index, value)) return .bad_argument;
    return .ok;
}

/// Deliver a maskable interrupt, honouring `flg.I` and `im` exactly as
/// the VM does — the lab must not be able to inject an interrupt a
/// real program could not receive.
pub fn raiseIrq(handle: u32, vector: u8) Status {
    const slot = lookup(handle) orelse return .bad_argument;
    _ = gero.vm.raiseIrq(&slot.machine, @enumFromInt(vector));
    return .ok;
}

/// Everything the program printed since the last drain, and how many
/// bytes were dropped because it outran the buffer.
pub const Output_ = struct {
    text: []const u8,
    dropped: u64,
};

/// Drain the print buffer. The bytes stay valid until the next VM
/// call on this session.
pub fn takeOutput(handle: u32) ?Output_ {
    const slot = lookup(handle) orelse return null;
    const result: Output_ = .{ .text = slot.output.buffered(), .dropped = slot.output.dropped };
    return result;
}

/// Discard what `takeOutput` just reported. Separate so a host reads
/// the bytes before they are invalidated.
pub fn clearOutput(handle: u32) void {
    const slot = lookup(handle) orelse return;
    slot.output.clear();
}

/// The battery-backed banks, for persistence (§7). Empty when the
/// program declares none.
pub fn sram(handle: u32) ?[]const u8 {
    const slot = lookup(handle) orelse return null;
    return slot.machine.sramSlice();
}

/// Restore battery-backed banks saved by an earlier session.
pub fn loadSram(handle: u32, bytes: []const u8) Status {
    const slot = lookup(handle) orelse return .bad_argument;
    const dst = slot.machine.sramSliceMut();
    // A program that declares no SRAM has nowhere to put this, and a
    // save from a different program will not fit — either way the
    // caller has the wrong bytes for this session.
    if (dst.len == 0 or bytes.len != dst.len) return .bad_argument;
    @memcpy(dst, bytes);
    return .ok;
}

// ---------- tests ----------

const testing = std.testing;

/// Assemble `src` into a `.gx` the tests can load. Uses the testing
/// allocator rather than a session's, so the image outlives boot.
fn buildImage(allocator: std.mem.Allocator, src: []const u8) ![]const u8 {
    const pt = try gero.asm_.parse(allocator, src);
    // Both error sets, not just codegen's: a parse error otherwise
    // slips through and yields a garbage image that faults for a
    // reason having nothing to do with the test.
    try testing.expectEqual(@as(usize, 0), pt.errors.len);
    const cg = try gero.asm_.assemble(allocator, src, pt, .{});
    try testing.expectEqual(@as(usize, 0), cg.errors.len);
    return cg.image;
}

/// Start a session with `src` loaded.
fn session(allocator: std.mem.Allocator, src: []const u8) !u32 {
    const image = try buildImage(allocator, src);
    const handle = create();
    try testing.expect(handle != 0);
    var buf: [gero.load_error.max_message_len]u8 = undefined;
    try testing.expect(load(handle, image, &buf) == null);
    return handle;
}

fn resetAll() void {
    for (&sessions) |*slot| {
        if (slot.live) slot.machine.deinit();
        slot.* = .{};
    }
}

test "create: sessions are independent, and destroying one leaves the other" {
    resetAll();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const a = try session(arena.allocator(), "main:\n  mov $0001, r1\n  hlt\n");
    const b = try session(arena.allocator(), "main:\n  mov $0002, r1\n  hlt\n");
    try testing.expect(a != b);
    try testing.expectEqual(@as(u32, 2), liveCount());

    _ = step(a, 100);
    _ = step(b, 100);
    var regs_a: [register_bytes]u8 = undefined;
    var regs_b: [register_bytes]u8 = undefined;
    try testing.expect(registers(a, &regs_a));
    try testing.expect(registers(b, &regs_b));
    // Each ran its own program; the two register files differ.
    try testing.expect(!std.mem.eql(u8, &regs_a, &regs_b));

    try testing.expectEqual(Status.ok, destroy(b));
    try testing.expectEqual(@as(u32, 1), liveCount());
    // The survivor is untouched.
    try testing.expect(registers(a, &regs_a));
}

test "handles: a destroyed one is refused rather than aliasing its slot" {
    resetAll();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const first = try session(arena.allocator(), "main:\n  hlt\n");
    _ = destroy(first);
    // The slot is free, so the next create takes it — but the old
    // handle must not address the new session.
    const second = create();
    try testing.expect(second != first);
    try testing.expect(step(first, 1) == null);
    try testing.expect(step(second, 1) != null);
}

test "handles: nonsense is refused, never indexed" {
    resetAll();
    try testing.expect(step(0, 1) == null);
    try testing.expect(step(0xDEAD_BEEF, 1) == null);
    try testing.expect(step(makeHandle(max_sessions + 5, 1), 1) == null);
    try testing.expectEqual(Status.bad_argument, destroy(12345));
}

test "step: distinguishes budget, halt, breakpoint, and fault" {
    resetAll();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The run loop branches on each of these, so collapsing any two
    // would strand a host — a fault is not a halt.
    const spin = try session(a, "main:\n  jmp main\n");
    try testing.expectEqual(@intFromEnum(StepReason.budget), step(spin, 20).?.reason);

    const halt = try session(a, "main:\n  hlt\n");
    try testing.expectEqual(@intFromEnum(StepReason.halted), step(halt, 20).?.reason);

    const brk = try session(a, "main:\n  brk\n  hlt\n");
    try testing.expectEqual(@intFromEnum(StepReason.breakpoint), step(brk, 20).?.reason);

    const fault = try session(a, "main:\n  mov $0000, r1\n  div r1, r1\n  hlt\n");
    const out = step(fault, 20).?;
    try testing.expectEqual(@intFromEnum(StepReason.faulted), out.reason);
    // Vector 0x03 is division by zero (isa.md §6.1).
    try testing.expectEqual(@as(u32, 0x03), out.fault);
}

test "step: a session with no image says so rather than running" {
    resetAll();
    const handle = create();
    try testing.expectEqual(@intFromEnum(StepReason.not_loaded), step(handle, 10).?.reason);
}

test "output: a program printing past the buffer is bounded and says so" {
    resetAll();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // `print_char` in a loop, never drained — the flood case.
    const handle = try session(arena.allocator(),
        \\main:
        \\  mov $0041, acu
        \\.loop:
        \\  sys $03
        \\  jmp .loop
        \\
    );
    _ = step(handle, 200_000);
    const out = takeOutput(handle).?;
    // Bounded by the buffer...
    try testing.expect(out.text.len <= output_bytes);
    // ...and the overflow is reported rather than vanishing.
    try testing.expect(out.dropped > 0);
}

test "output: a full buffer does not fault the program" {
    resetAll();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // The VM raises invalid-opcode when its writer errors, so a sink
    // that failed on overflow would turn a chatty program into a
    // crashing one — a lie about the program.
    const handle = try session(arena.allocator(),
        \\main:
        \\  mov $0041, acu
        \\.loop:
        \\  sys $03
        \\  jmp .loop
        \\
    );
    const out = step(handle, 200_000).?;
    try testing.expectEqual(@intFromEnum(StepReason.budget), out.reason);
}

test "peek: reads through the mapper, and poke round-trips" {
    resetAll();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const handle = try session(arena.allocator(), "main:\n  hlt\n");

    try testing.expect(poke(handle, 0x2000, &[_]u8{ 0xDE, 0xAD }));
    var seen: [2]u8 = undefined;
    try testing.expect(peek(handle, 0x2000, &seen));
    try testing.expectEqualSlices(u8, &.{ 0xDE, 0xAD }, &seen);
}

test "reset: re-boots the loaded image" {
    resetAll();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const handle = try session(arena.allocator(), "main:\n  mov $0042, r1\n  hlt\n");

    _ = step(handle, 100);
    _ = poke(handle, 0x2000, &[_]u8{0xFF});
    try testing.expectEqual(Status.ok, reset(handle));

    // Execution starts over and the scribble is gone.
    var seen: [1]u8 = undefined;
    try testing.expect(peek(handle, 0x2000, &seen));
    try testing.expectEqual(@as(u8, 0), seen[0]);
    try testing.expectEqual(@intFromEnum(StepReason.halted), step(handle, 100).?.reason);
}

test "load: a malformed image explains why, in the shared wording" {
    resetAll();
    const handle = create();
    var buf: [gero.load_error.max_message_len]u8 = undefined;
    const failure = load(handle, "NOPE not a gx file at all", &buf).?;
    try testing.expectEqual(Status.bad_argument, failure.status);
    // The same sentence `gero run` prints (#415), not a status code.
    try testing.expect(std.mem.indexOf(u8, failure.message, "not a .gx file") != null);
}

test "sram: round-trips through a fresh session" {
    resetAll();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\bank $00
        \\sram_banks $01
        \\main:
        \\  hlt
        \\
    ;
    const handle = try session(arena.allocator(), src);
    const banks = sram(handle).?;
    try testing.expect(banks.len > 0);

    // A save written by one session reloads into another, which is
    // what makes a cart's saved game survive a reload (§7).
    const saved = try arena.allocator().dupe(u8, banks);
    saved[0] = 0x7E;
    try testing.expectEqual(Status.ok, loadSram(handle, saved));
    try testing.expectEqual(@as(u8, 0x7E), sram(handle).?[0]);

    // A save of the wrong size belongs to a different program.
    try testing.expectEqual(Status.bad_argument, loadSram(handle, "short"));
}
