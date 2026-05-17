/// Handlers for the misc, flag-manipulation, and system families:
/// `swap` / `nop`, `clc` / `sec` / `cli` / `sei` / `clv`, and
/// `int` / `rti` / `brk` / `hlt`. `int` reuses the interrupt-
/// entry path so software interrupts and faults share one
/// implementation.
const vm_mod = @import("../vm.zig");
const dispatch = @import("../dispatch.zig");
const VM = vm_mod.VM;
const StepResult = dispatch.StepResult;

const ok = StepResult.cont;

fn fault(vm: *VM, vector: dispatch.Vector) StepResult {
    return dispatch.raiseFault(vm, vector);
}

// ---------- misc ----------

/// `0x90` — `swap Reg, Reg` → atomic swap.
pub fn swap(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const a_idx = vm.readByte(ip +% 1);
    const b_idx = vm.readByte(ip +% 2);
    const a = vm.regs.readByIndex(a_idx) orelse return fault(vm, .invalid_register);
    const b = vm.regs.readByIndex(b_idx) orelse return fault(vm, .invalid_register);
    if (!vm.regs.writeByIndex(a_idx, b)) return fault(vm, .invalid_register);
    if (!vm.regs.writeByIndex(b_idx, a)) return fault(vm, .invalid_register);
    return ok;
}

/// `0x91` — `nop`.
pub fn nop(vm: *VM) StepResult {
    _ = vm;
    return ok;
}

// ---------- flag manipulation ----------

/// `0xA0` — `clc` → `flg.C ← 0`.
pub fn clc(vm: *VM) StepResult {
    vm.regs.setFlag(.carry, false);
    return ok;
}

/// `0xA1` — `sec` → `flg.C ← 1`.
pub fn sec(vm: *VM) StepResult {
    vm.regs.setFlag(.carry, true);
    return ok;
}

/// `0xA2` — `cli` → `flg.I ← 0` (enable interrupts globally).
pub fn cli(vm: *VM) StepResult {
    vm.regs.setFlag(.interrupt_disable, false);
    return ok;
}

/// `0xA3` — `sei` → `flg.I ← 1` (block interrupts globally).
pub fn sei(vm: *VM) StepResult {
    vm.regs.setFlag(.interrupt_disable, true);
    return ok;
}

/// `0xA4` — `clv` → `flg.V ← 0`.
pub fn clv(vm: *VM) StepResult {
    vm.regs.setFlag(.overflow, false);
    return ok;
}

// ---------- system ----------

/// `0xFC` — `int Imm8` → software interrupt: pushes the
/// post-instruction `ip`, then `fp` / `flg`, sets `flg.I`, jumps
/// to `mem[0x1000 + 2*imm]`. Shares the entry sequence with
/// VM-emitted faults.
pub fn intImm8(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const vector_byte = vm.readByte(ip +% 1);
    // Advance ip so the saved return address points at the
    // instruction AFTER int N, not at int itself.
    vm.regs.write(.ip, ip +% 2);
    const vector: dispatch.Vector = @enumFromInt(vector_byte);
    return dispatch.raiseFault(vm, vector);
}

/// `0xFD` — `rti` → pop `flg` / `fp` / `ip` (reverse push
/// order) and resume.
pub fn rti(vm: *VM) StepResult {
    const flg = dispatch.popWord(vm);
    const fp = dispatch.popWord(vm);
    const ret_ip = dispatch.popWord(vm);
    vm.regs.write(.flg, flg);
    vm.regs.write(.fp, fp);
    vm.regs.write(.ip, ret_ip);
    return .branched;
}

/// `0xFE` — `brk` → resumable breakpoint event. Returns
/// `.breakpoint`; `step` auto-advances `ip` past the brk so the
/// host can resume by calling `run` again.
pub fn brk(vm: *VM) StepResult {
    _ = vm;
    return .breakpoint;
}

/// `0xFF` — `hlt` → terminal halt; the program is done.
pub fn hlt(vm: *VM) StepResult {
    _ = vm;
    return .halted;
}

// ---------- syscall (host-callback) ----------

/// Host-callback syscall identifiers. The `sys imm8` opcode
/// dispatches on this number; unknown ids raise the
/// `invalid_opcode` fault. See `gero.vm.VM.host` for the sinks
/// these syscalls write to.
pub const SyscallId = enum(u8) {
    /// `acu` = address in memory of a null-terminated byte string;
    /// the bytes (excluding the trailing `\0`) get written to
    /// `host.out`.
    print_str = 0x01,
    /// `acu` = signed 16-bit value, formatted as decimal into
    /// `host.out`.
    print_int = 0x02,
    /// `acu` low byte → `host.out` as a raw character.
    print_char = 0x03,
    /// Writes a single `\n` byte to `host.out`. No args.
    print_newline = 0x04,
    /// `acu` = Q8.8 fixed-point value. Formats as
    /// `<int>.<3-digit-frac>` decimal — e.g. value `384`
    /// (1.5 in Q8.8) prints `1.500`. Negative values get a
    /// leading `-`.
    print_fixed = 0x05,

    // ---------- format-to-buffer family ----------
    //
    // These backstop non-print string interpolation per spec
    // §3.2.2 + #194 ("one-alloc per non-print interpolation").
    // The caller supplies the destination cursor in `r1`; each
    // syscall appends bytes at `[r1]` and advances `r1` past
    // them so the calls compose without any extra bookkeeping
    // on the codegen side.

    /// `acu` = source str address (null-terminated). `r1` = dst
    /// cursor. Copies the bytes (excluding the trailing null)
    /// from `[acu]` to `[r1]`, advances `r1` past the copy.
    format_str_to_buf = 0x10,
    /// `acu` = i16 value. `r1` = dst cursor. Appends the signed
    /// decimal representation of `acu` at `[r1]`, advances `r1`.
    format_int_to_buf = 0x11,
    /// `acu` = char value (low byte). `r1` = dst cursor. Writes
    /// the low byte to `[r1]`, advances `r1` by 1.
    format_char_to_buf = 0x12,
    /// `acu` = Q8.8 value. `r1` = dst cursor. Appends the same
    /// `<int>.<3-digit-frac>` formatting as `print_fixed`.
    format_fixed_to_buf = 0x13,
    /// `r1` = dst cursor. Writes a single null byte at `[r1]`
    /// and advances `r1` by 1 (so chained terminators don't
    /// stomp the same slot).
    format_terminate_buf = 0x14,

    /// Open-enum tail — unknown syscall ids coerce here and the
    /// `sys` handler routes them to the `invalid_opcode` fault.
    _,
};

/// `0xFB` — `sys imm8` → host-callback syscall. Reads the
/// syscall id from the operand byte, dispatches to a fixed
/// handler. Print syscalls are silent no-ops when
/// `vm.host.out` is `null`; format-to-buffer syscalls still
/// run (they touch VM memory, not the host). Writer failures
/// and unknown syscall ids both raise the `invalid_opcode`
/// fault.
pub fn sys(vm: *VM) StepResult {
    const ip = vm.regs.read(.ip);
    const id_byte = vm.readByte(ip +% 1);
    // safety: enum payload is u8 — every value round-trips, even
    // unrecognized ones via the `else` arm below.
    const id: SyscallId = @enumFromInt(id_byte);
    switch (id) {
        .print_str, .print_int, .print_char, .print_newline, .print_fixed => {
            const writer = vm.host.out orelse return ok;
            return dispatchPrint(vm, id, writer);
        },
        .format_str_to_buf => formatStrToBuf(vm),
        .format_int_to_buf => formatIntToBuf(vm) catch return fault(vm, .invalid_opcode),
        .format_char_to_buf => formatCharToBuf(vm),
        .format_fixed_to_buf => formatFixedToBuf(vm) catch return fault(vm, .invalid_opcode),
        .format_terminate_buf => formatTerminateBuf(vm),
        // Unknown id — open-enum coercion picks this up; future
        // syscall ids should add an arm above.
        _ => return fault(vm, .invalid_opcode),
    }
    return ok;
}

/// Print-family dispatch — split out so the host-null fast path
/// can short-circuit before evaluating which print syscall fired.
fn dispatchPrint(vm: *VM, id: SyscallId, writer: *@import("std").Io.Writer) StepResult {
    switch (id) {
        .print_str => printStr(vm, writer) catch return fault(vm, .invalid_opcode),
        .print_int => {
            // safety: acu is u16; bit-cast to i16 for signed-decimal output.
            const v: i16 = @bitCast(vm.regs.read(.acu));
            writer.print("{d}", .{v}) catch return fault(vm, .invalid_opcode);
        },
        .print_char => {
            // @as: acu is u16; the print_char syscall writes the low byte only.
            const byte: u8 = @intCast(vm.regs.read(.acu) & 0xFF);
            writer.writeByte(byte) catch return fault(vm, .invalid_opcode);
        },
        .print_newline => writer.writeByte('\n') catch return fault(vm, .invalid_opcode),
        .print_fixed => printFixed(vm, writer) catch return fault(vm, .invalid_opcode),
        // allow-strict: the outer `sys` filters to the five print ids before calling here.
        else => unreachable,
    }
    return ok;
}

fn printStr(vm: *VM, writer: *@import("std").Io.Writer) !void {
    var addr: u16 = vm.regs.read(.acu);
    while (true) {
        const b = vm.readByte(addr);
        if (b == 0) break;
        try writer.writeByte(b);
        addr +%= 1;
    }
}

// ---------- format-to-buffer ----------

/// Write `byte` at `[r1]` and advance `r1` by 1. Helper used by
/// every `format_*_to_buf` syscall so cursor advance + memory
/// write stay in one place.
fn writeBufByte(vm: *VM, byte: u8) void {
    const cur = vm.regs.read(.r1);
    vm.writeByte(cur, byte);
    vm.regs.write(.r1, cur +% 1);
}

fn formatStrToBuf(vm: *VM) void {
    var src: u16 = vm.regs.read(.acu);
    while (true) {
        const b = vm.readByte(src);
        if (b == 0) break;
        writeBufByte(vm, b);
        src +%= 1;
    }
}

fn formatIntToBuf(vm: *VM) !void {
    // safety: acu is u16; bit-cast to i16 for signed-decimal output.
    const v: i16 = @bitCast(vm.regs.read(.acu));
    var stack_buf: [8]u8 = undefined;
    var local: @import("std").Io.Writer = .fixed(&stack_buf);
    try local.print("{d}", .{v});
    for (local.buffered()) |b| writeBufByte(vm, b);
}

fn formatCharToBuf(vm: *VM) void {
    // @as: acu is u16; the format_char syscall writes the low byte only.
    const byte: u8 = @intCast(vm.regs.read(.acu) & 0xFF);
    writeBufByte(vm, byte);
}

fn formatFixedToBuf(vm: *VM) !void {
    var stack_buf: [16]u8 = undefined;
    var local: @import("std").Io.Writer = .fixed(&stack_buf);
    try writeFixedTo(vm, &local);
    for (local.buffered()) |b| writeBufByte(vm, b);
}

fn formatTerminateBuf(vm: *VM) void {
    writeBufByte(vm, 0);
}

/// Q8.8 → `<int>.<3-digit-frac>` decimal. Shared between
/// `print_fixed` (writes through to host.out) and
/// `format_fixed_to_buf` (writes to VM memory at `r1`) — the
/// formatting math is identical; only the sink differs.
fn writeFixedTo(vm: *VM, writer: *@import("std").Io.Writer) !void {
    // safety: Q8.8 lives in acu as a u16 — bit-cast to i16 for sign + magnitude split.
    const raw: i16 = @bitCast(vm.regs.read(.acu));
    if (raw < 0) try writer.writeByte('-');
    // @as: widen i16 → i32 so negating the minimum value (-32768) doesn't overflow.
    const widened_neg: i32 = -@as(i32, raw);
    // safety: i16 bit pattern → u16 of the same width preserves the bits (used only on the positive branch).
    const positive_u16: u16 = @bitCast(raw);
    const abs: u16 = if (raw < 0)
        // @as: i32 → u16; the magnitude of an i16 fits a u16 by 1 bit of headroom.
        @intCast(widened_neg)
    else
        positive_u16;
    const int_part: u16 = abs >> 8;
    const frac_part: u16 = abs & 0xFF;
    // @as: widen u16 → u32 so the *1000 multiplication doesn't overflow.
    const frac_thousandths: u32 = @as(u32, frac_part) * 1000 / 256;
    try writer.print("{d}.{d:0>3}", .{ int_part, frac_thousandths });
}

fn printFixed(vm: *VM, writer: *@import("std").Io.Writer) !void {
    try writeFixedTo(vm, writer);
}
