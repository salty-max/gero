/// `gero run` — load a `.gx`, boot a fresh VM, execute until
/// halt / fault / breakpoint. The bare-VM target intercepts two
/// reserved `int N` syscalls before they reach the IVT:
///
///   `int 0x10` — print the low byte of `r1` to stdout.
///   `int 0x21` — flush the SRAM bytes through the host sink
///                (typically a write of `<basename>.sav`).
///
/// `--target=gtx-16` is intentionally not wired here — the
/// fantasy-console shim lives in a separate crate.
const std = @import("std");
const gero = @import("gero");
const cli = @import("cli.zig");

/// Host callback that persists the SRAM bytes. The pointer
/// `ctx` is opaque to `execute`; the host (or a test) owns
/// whatever type backs it.
pub const SramSink = struct {
    ctx: *anyopaque,
    write_fn: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,

    /// Forward the bytes through the callback.
    pub fn write(self: SramSink, bytes: []const u8) anyerror!void {
        return self.write_fn(self.ctx, bytes);
    }
};

/// Drive a parsed `.gx` to completion. Returns the CLI exit
/// code per cli.md §3.3: `0` on `hlt`, `6` on unhandled fault,
/// `1` on host-level error / bad file / unsupported target,
/// `2` on a `brk` breakpoint.
pub fn execute(
    allocator: std.mem.Allocator,
    opts: cli.Options,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    sram_sink: ?SramSink,
    gx_bytes: []const u8,
) !u8 {
    if (opts.target == .gtx_16) {
        try stderr.print("gero run: --target=gtx-16 is not implemented in this build\n", .{});
        return 1;
    }

    const loaded = gero.vm.parseGx(gx_bytes) catch |err| {
        try stderr.print("gero run: invalid .gx file ({s})\n", .{@errorName(err)});
        return 1;
    };

    var vm = gero.vm.VM.init(allocator);
    defer vm.deinit();
    try vm.boot(allocator, loaded);

    while (true) {
        const ip = vm.regs.read(.ip);
        const op = vm.readByte(ip);

        if (op == 0xFC) {
            const vec = vm.readByte(ip +% 1);
            switch (vec) {
                0x10 => {
                    // safety: truncating r1 to its low byte is the
                    //         documented print-syscall contract
                    const byte: u8 = @truncate(vm.regs.read(.r1));
                    try stdout.writeByte(byte);
                    vm.regs.write(.ip, ip +% 2);
                    continue;
                },
                0x21 => {
                    if (sram_sink) |sink| try sink.write(vm.sramSlice());
                    vm.regs.write(.ip, ip +% 2);
                    continue;
                },
                else => {},
            }
        }

        const result = gero.vm.step(&vm);
        switch (result) {
            .cont, .branched => continue,
            .halted => return 0,
            .halted_on_fault => {
                try stderr.print("gero run: unhandled fault at ip=0x{X:0>4}\n", .{vm.regs.read(.ip)});
                return 6;
            },
            .breakpoint => {
                if (opts.verbose) try stderr.print("gero run: breakpoint at ip=0x{X:0>4}\n", .{vm.regs.read(.ip)});
                return 2;
            },
        }
    }
}

// ---------- tests ----------

const testing = std.testing;

const RecordingSink = struct {
    bytes: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,

    fn writeImpl(ctx: *anyopaque, data: []const u8) anyerror!void {
        const self: *RecordingSink = @ptrCast(@alignCast(ctx));
        try self.bytes.appendSlice(self.allocator, data);
    }

    fn sink(self: *RecordingSink) SramSink {
        return .{ .ctx = self, .write_fn = writeImpl };
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
    out[0x04] = 0x01;
    out[0x05] = 0x00;
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

    const code = try execute(testing.allocator, .{}, &out, &err, null, &buf);
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

    const code = try execute(testing.allocator, .{}, &out, &err, null, &buf);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings("HI", out_buf[0..out.end]);
}

test "execute: save syscall (int 0x21) hands SRAM bytes to the sink" {
    // mov 0xCAFE → r1, mov r1, [0xC000] (writes to bank 0 byte 0),
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
    // mov r1, [0xC000] → 0x12 reg, addr
    buf[20] = 0x12;
    buf[21] = 0x02; // r1
    buf[22] = 0x00;
    buf[23] = 0xC0;
    // int 0x21
    buf[24] = 0xFC;
    buf[25] = 0x21;
    // hlt
    buf[26] = 0xFF;
    // Bank 0 starts at offset 16 + image_size = 28; zero-init.
    @memset(buf[16 + image_size ..], 0);

    var sink = RecordingSink{ .allocator = testing.allocator };
    defer sink.deinit();

    var out_buf: [256]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err: std.Io.Writer = .fixed(&err_buf);

    const code = try execute(testing.allocator, .{}, &out, &err, sink.sink(), &buf);
    try testing.expectEqual(@as(u8, 0), code);
    // First 2 bytes of SRAM hold the written word (little-endian).
    try testing.expectEqual(@as(usize, 0x4000), sink.bytes.items.len);
    try testing.expectEqual(@as(u8, 0xFE), sink.bytes.items[0]);
    try testing.expectEqual(@as(u8, 0xCA), sink.bytes.items[1]);
}

test "execute: --target=gtx-16 exits 1 with explicit message" {
    const buf = [_]u8{0} ** 16;
    var out_buf: [128]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err: std.Io.Writer = .fixed(&err_buf);

    const opts: cli.Options = .{ .target = .gtx_16 };
    const code = try execute(testing.allocator, opts, &out, &err, null, &buf);
    try testing.expectEqual(@as(u8, 1), code);
    try testing.expect(std.mem.indexOf(u8, err_buf[0..err.end], "gtx-16") != null);
}

test "execute: bad magic exits 1 with structured message" {
    var buf = [_]u8{0} ** 16;
    var out_buf: [128]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err: std.Io.Writer = .fixed(&err_buf);

    const code = try execute(testing.allocator, .{}, &out, &err, null, &buf);
    try testing.expectEqual(@as(u8, 1), code);
    try testing.expect(std.mem.indexOf(u8, err_buf[0..err.end], "BadMagic") != null);
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

    const code = try execute(testing.allocator, .{}, &out, &err, null, &buf);
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

    const code = try execute(testing.allocator, .{}, &out, &err, null, &buf);
    try testing.expectEqual(@as(u8, 2), code);
}
