const std = @import("std");
const gero = @import("gero");
const cli = @import("cli.zig");
const load_error = gero.load_error;
const term_mod = @import("term.zig");

/// Host interface that persists the SRAM bytes. Intrusive:
/// hosts embed `SramStore` as a field and supply a vtable whose
/// callbacks recover the parent via `@fieldParentPtr`.
pub const SramStore = struct {
    vtable: *const VTable,

    /// What a `load` can fail with. A store that holds a save of the
    /// wrong size reports it rather than filling what it can: SRAM is
    /// a program's own state, and a half-restored save is worse than
    /// a missing one.
    pub const LoadError = error{ WrongSize, Unreadable };

    /// Method table — each callback receives the same `*SramStore`
    /// the caller holds.
    pub const VTable = struct {
        write: *const fn (self: *SramStore, bytes: []const u8) anyerror!void,
        /// Fill `dst` with the persisted image. Returns `false` when
        /// the store holds no save, which is the first-run case and
        /// not an error.
        load: *const fn (self: *SramStore, dst: []u8) LoadError!bool,
    };

    /// Forward the bytes through the vtable.
    pub fn write(self: *SramStore, bytes: []const u8) anyerror!void {
        return self.vtable.write(self, bytes);
    }

    /// Seed `dst` from the store, reporting whether a save existed.
    pub fn load(self: *SramStore, dst: []u8) LoadError!bool {
        return self.vtable.load(self, dst);
    }
};

/// Drive a parsed `.gx` to completion. Returns the CLI exit
/// code per cli.md §3.3: `0` on `hlt`, `6` on unhandled fault,
/// `1` on host-level error / bad file, `2` on a `brk` breakpoint.
pub fn execute(
    allocator: std.mem.Allocator,
    opts: cli.Options,
    stdout: *std.Io.Writer,
    term: *term_mod.Term,
    sram_store: ?*SramStore,
    gx_bytes: []const u8,
) !u8 {
    const loaded = gero.vm.parseGx(gx_bytes) catch |err| {
        var msg_buf: [load_error.max_message_len]u8 = undefined;
        try term.err("gero run: {s}", .{load_error.describe(&msg_buf, err, gx_bytes)});
        return 1;
    };

    var vm = gero.vm.VM.init(allocator);
    defer vm.deinit();
    try vm.boot(allocator, loaded);

    // Battery-backed banks come back from the store before the first
    // instruction runs (ISA §3.2.1). `boot` leaves them zeroed, which
    // is also the right state when no save exists yet.
    if (sram_store) |store| {
        const persistent = vm.sramSliceMut();
        if (persistent.len > 0) {
            _ = store.load(persistent) catch |err| {
                try term.err("gero run: cannot restore saved data ({s})", .{switch (err) {
                    error.WrongSize => "the save file does not match this program's SRAM size",
                    error.Unreadable => "the save file could not be read",
                }});
                return 1;
            };
        }
    }
    // Route lang `print` (`sys print_str` / `print_int` /
    // `print_char` / `print_newline`) through stdout. The asm-
    // level `int $10` syscall is intercepted below regardless;
    // wiring host.out makes `.gx` images produced by
    // `gero compile` runnable end-to-end.
    vm.host = .{ .out = stdout };

    while (true) {
        // The host-convention `int` vectors, shared with every other
        // host so a program prints the same wherever it runs. Where a
        // save *goes* is this host's business, hence the switch.
        switch (try gero.vm.host_int.handle(&vm)) {
            .printed => continue,
            .sram_flush_requested => {
                if (sram_store) |store| try store.write(vm.sramSlice());
                continue;
            },
            .no => {},
        }

        const result = gero.vm.step(&vm);
        switch (result) {
            .cont, .branched => continue,
            .halted => {
                // Deterministic, so this is a property of the program
                // rather than of the machine it ran on — which is what
                // makes two runs comparable.
                if (opts.cycles) try term.info("cycles: {d}", .{vm.cycles});
                return 0;
            },
            .halted_on_fault => {
                try term.err("gero run: unhandled fault at ip=0x{X:0>4} — {s}", .{
                    vm.regs.read(.ip),
                    faultName(vm.last_fault),
                });
                return 6;
            },
            .breakpoint => {
                if (opts.verbose) try term.info("gero run: breakpoint at ip=0x{X:0>4}", .{vm.regs.read(.ip)});
                return 2;
            },
        }
    }
}

/// Source-level name for a fault vector, so an unhandled fault says
/// what went wrong rather than only that something did.
fn faultName(vector: ?gero.vm.Vector) []const u8 {
    const v = vector orelse return "unknown";
    return switch (v) {
        .reset => "reset",
        .invalid_opcode => "invalid-opcode",
        .invalid_register => "invalid-register",
        .div_by_zero => "divide-by-zero",
        .heap_exhausted => "heap-exhausted (the heap never reclaims — reuse a buffer instead of allocating in a loop)",
        .arith_overflow => "arithmetic-overflow",
        .trap => "trap (panic / failed assertion)",
        _ => "unknown",
    };
}

// ---------- tests ----------

const testing = std.testing;

const RecordingSink = struct {
    sink: SramStore,
    bytes: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    /// Stands in for an existing save file; null means first run.
    saved: ?[]const u8 = null,

    const vtable: SramStore.VTable = .{ .write = writeImpl, .load = loadImpl };

    fn writeImpl(s: *SramStore, data: []const u8) anyerror!void {
        // safety: `s` points at the `sink` field of a *RecordingSink
        const self: *RecordingSink = @fieldParentPtr("sink", s);
        try self.bytes.appendSlice(self.allocator, data);
    }

    fn loadImpl(s: *SramStore, dst: []u8) SramStore.LoadError!bool {
        // safety: `s` points at the `sink` field of a *RecordingSink
        const self: *RecordingSink = @fieldParentPtr("sink", s);
        const saved = self.saved orelse return false;
        if (saved.len != dst.len) return error.WrongSize;
        @memcpy(dst, saved);
        return true;
    }

    fn init(allocator: std.mem.Allocator) RecordingSink {
        return .{ .sink = .{ .vtable = &vtable }, .allocator = allocator };
    }

    fn deinit(self: *RecordingSink) void {
        self.bytes.deinit(self.allocator);
    }
};

fn buildGx(
    out: []u8,
    flags: u16,
    entry: u16,
    image_size: u16,
    bank_count: u8,
    sram_bank_count: u8,
) []u8 {
    @memset(out, 0);
    @memcpy(out[0..4], "GERO");
    // Stamped from the constant, never a literal: a fixture pinned to
    // an old version stops being loadable the moment the major moves.
    out[0x04] = @truncate(gero.gx.version & 0xFF);
    out[0x05] = @truncate(gero.gx.version >> 8);
    out[0x06] = @truncate(flags & 0xFF);
    out[0x07] = @truncate(flags >> 8);
    out[0x08] = @truncate(entry & 0xFF);
    out[0x09] = @truncate(entry >> 8);
    out[0x0A] = @truncate(image_size & 0xFF);
    out[0x0B] = @truncate(image_size >> 8);
    out[0x0C] = bank_count;
    out[0x0D] = sram_bank_count;
    return out;
}

test "execute: hlt program exits 0" {
    var buf: [16 + 1]u8 = undefined;
    _ = buildGx(buf[0..16], 0, 0x0000, 1, 0, 0);
    buf[16] = 0xFF; // hlt

    var out_buf: [256]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err: std.Io.Writer = .fixed(&err_buf);
    var term = term_mod.Term{ .out = &err, .color = false };

    const code = try execute(testing.allocator, .{}, &out, &term, null, &buf);
    try testing.expectEqual(@as(u8, 0), code);
}

test "execute: print syscall (int 0x10) writes r1.lo to stdout" {
    // mov 0x0048 → r1 (4 bytes), int 0x10 (2), mov 0x0049 → r1 (4),
    // int 0x10 (2), hlt (1) = 13 bytes total. Prints "HI".
    var buf: [16 + 13]u8 = undefined;
    _ = buildGx(buf[0..16], 0, 0x0000, 13, 0, 0);
    buf[16 + 0] = 0x10; // mov imm16, reg
    buf[16 + 1] = 0x48; // 'H'
    buf[16 + 2] = 0x00;
    buf[16 + 3] = 0x02; // r1
    buf[16 + 4] = 0xFC; // int
    buf[16 + 5] = 0x10;
    buf[16 + 6] = 0x10;
    buf[16 + 7] = 0x49; // 'I'
    buf[16 + 8] = 0x00;
    buf[16 + 9] = 0x02;
    buf[16 + 10] = 0xFC;
    buf[16 + 11] = 0x10;
    buf[16 + 12] = 0xFF;

    var out_buf: [256]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err: std.Io.Writer = .fixed(&err_buf);
    var term = term_mod.Term{ .out = &err, .color = false };

    const code = try execute(testing.allocator, .{}, &out, &term, null, &buf);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings("HI", out_buf[0..out.end]);
}

test "execute: save syscall (int 0x21) hands SRAM bytes to the sink" {
    // mov 0xCAFE → r1, mov r1, [0xBE00] (writes to bank 0 byte 0),
    // int 0x21, hlt. bank_count=1, sram_bank_count=1.
    const image_size: u16 = 4 + 5 + 2 + 1; // 12
    const total = 16 + image_size + 0x4000; // header + image + 1 bank
    var buf: [total]u8 = undefined;
    _ = buildGx(buf[0..16], 0x0001, 0x0000, image_size, 1, 1);
    // mov 0xCAFE → r1
    buf[16] = 0x10;
    buf[17] = 0xFE;
    buf[18] = 0xCA;
    buf[19] = 0x02;
    // mov r1, [0xBE00] → 0x12 reg, addr
    buf[20] = 0x12;
    buf[21] = 0x02; // r1
    buf[22] = 0x00;
    buf[23] = 0xBE;
    // int 0x21
    buf[24] = 0xFC;
    buf[25] = 0x21;
    // hlt
    buf[26] = 0xFF;
    // Bank 0 starts at offset 16 + image_size = 28; zero-init.
    @memset(buf[16 + image_size ..], 0);

    var rec = RecordingSink.init(testing.allocator);
    defer rec.deinit();

    var out_buf: [256]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err: std.Io.Writer = .fixed(&err_buf);
    var term = term_mod.Term{ .out = &err, .color = false };

    const code = try execute(testing.allocator, .{}, &out, &term, &rec.sink, &buf);
    try testing.expectEqual(@as(u8, 0), code);
    // First 2 bytes of SRAM hold the written word (little-endian).
    try testing.expectEqual(@as(usize, 0x4000), rec.bytes.items.len);
    try testing.expectEqual(@as(u8, 0xFE), rec.bytes.items[0]);
    try testing.expectEqual(@as(u8, 0xCA), rec.bytes.items[1]);
}

test "execute: a saved image is restored into SRAM before the first instruction" {
    // mov [0xBE00] → r1 (reads bank 0 byte 0), int 0x10, hlt. The
    // program prints what the restore put there, so a byte reaching
    // stdout is proof the save was in place before it ran.
    const image_size: u16 = 4 + 2 + 1; // 7
    const total = 16 + image_size + 0x4000;
    var buf: [total]u8 = undefined;
    _ = buildGx(buf[0..16], 0x0001, 0x0000, image_size, 1, 1);
    // mov [0xBE00], r1 → 0x13 addr, reg
    buf[16] = 0x13;
    buf[17] = 0x00;
    buf[18] = 0xBE;
    buf[19] = 0x02; // r1
    // int 0x10
    buf[20] = 0xFC;
    buf[21] = 0x10;
    // hlt
    buf[22] = 0xFF;
    @memset(buf[16 + image_size ..], 0);

    var saved = [_]u8{0} ** 0x4000;
    saved[0] = 'S';
    var rec = RecordingSink.init(testing.allocator);
    defer rec.deinit();
    rec.saved = &saved;

    var out_buf: [256]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err: std.Io.Writer = .fixed(&err_buf);
    var term = term_mod.Term{ .out = &err, .color = false };

    const code = try execute(testing.allocator, .{}, &out, &term, &rec.sink, &buf);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings("S", out.buffered());
}

test "execute: a save of the wrong size is refused rather than part-restored" {
    // Same program; the store holds a save one byte short. Half a
    // save is worse than none, so the run stops with exit 1.
    const image_size: u16 = 4 + 2 + 1;
    const total = 16 + image_size + 0x4000;
    var buf: [total]u8 = undefined;
    _ = buildGx(buf[0..16], 0x0001, 0x0000, image_size, 1, 1);
    buf[16] = 0x13;
    buf[17] = 0x00;
    buf[18] = 0xBE;
    buf[19] = 0x02;
    buf[20] = 0xFC;
    buf[21] = 0x10;
    buf[22] = 0xFF;
    @memset(buf[16 + image_size ..], 0);

    var saved = [_]u8{0} ** (0x4000 - 1);
    var rec = RecordingSink.init(testing.allocator);
    defer rec.deinit();
    rec.saved = &saved;

    var out_buf: [256]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err: std.Io.Writer = .fixed(&err_buf);
    var term = term_mod.Term{ .out = &err, .color = false };

    const code = try execute(testing.allocator, .{}, &out, &term, &rec.sink, &buf);
    try testing.expectEqual(@as(u8, 1), code);
    try testing.expect(std.mem.indexOf(u8, err.buffered(), "SRAM size") != null);
}

test "execute: --cycles reports one cycle per instruction executed" {
    // mov 0x0001 → r1, hlt. Two instructions, so two cycles — the
    // count is instructions retired, not a per-opcode cost model.
    const image_size: u16 = 4 + 1;
    var buf: [16 + image_size]u8 = undefined;
    _ = buildGx(buf[0..16], 0x0000, 0x0000, image_size, 0, 0);
    buf[16] = 0x10;
    buf[17] = 0x01;
    buf[18] = 0x00;
    buf[19] = 0x02;
    buf[20] = 0xFF;

    var out_buf: [256]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err: std.Io.Writer = .fixed(&err_buf);
    var term = term_mod.Term{ .out = &err, .color = false };

    const code = try execute(testing.allocator, .{ .cycles = true }, &out, &term, null, &buf);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, err.buffered(), "cycles: 2") != null);
}

test "execute: the cycle count is silent unless asked for" {
    const image_size: u16 = 1;
    var buf: [16 + image_size]u8 = undefined;
    _ = buildGx(buf[0..16], 0x0000, 0x0000, image_size, 0, 0);
    buf[16] = 0xFF;

    var out_buf: [256]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err: std.Io.Writer = .fixed(&err_buf);
    var term = term_mod.Term{ .out = &err, .color = false };

    const code = try execute(testing.allocator, .{}, &out, &term, null, &buf);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqual(@as(usize, 0), err.buffered().len);
}

test "execute: bad magic exits 1 with structured message" {
    var buf = [_]u8{0} ** 16;
    var out_buf: [128]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err: std.Io.Writer = .fixed(&err_buf);
    var term = term_mod.Term{ .out = &err, .color = false };

    const code = try execute(testing.allocator, .{}, &out, &term, null, &buf);
    try testing.expectEqual(@as(u8, 1), code);
    // The message names what is wrong, not the Zig error — an
    // `@errorName` tells the user nothing they can act on.
    const written = err_buf[0..err.end];
    try testing.expect(std.mem.indexOf(u8, written, "not a .gx file") != null);
    try testing.expect(std.mem.indexOf(u8, written, "BadMagic") == null);
}

test "execute: unhandled fault exits 6" {
    // Program: byte 0x00 at entry → invalid-opcode fault. IVT[0x01]
    // is zero (never installed), so the fault halts with .halted_on_fault.
    var buf: [16 + 1]u8 = undefined;
    _ = buildGx(buf[0..16], 0, 0x0000, 1, 0, 0);
    buf[16] = 0x00;

    var out_buf: [128]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err: std.Io.Writer = .fixed(&err_buf);
    var term = term_mod.Term{ .out = &err, .color = false };

    const code = try execute(testing.allocator, .{}, &out, &term, null, &buf);
    try testing.expectEqual(@as(u8, 6), code);
    try testing.expect(std.mem.indexOf(u8, err_buf[0..err.end], "fault") != null);
}

test "execute: brk exits 2" {
    var buf: [16 + 2]u8 = undefined;
    _ = buildGx(buf[0..16], 0, 0x0000, 2, 0, 0);
    buf[16] = 0xFE; // brk
    buf[17] = 0xFF; // hlt (unreachable in this run)

    var out_buf: [128]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err: std.Io.Writer = .fixed(&err_buf);
    var term = term_mod.Term{ .out = &err, .color = false };

    const code = try execute(testing.allocator, .{}, &out, &term, null, &buf);
    try testing.expectEqual(@as(u8, 2), code);
}
