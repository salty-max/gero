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
    /// `acu` = unsigned 16-bit value, formatted as decimal into
    /// `host.out`. (`print_int` is the signed counterpart.)
    print_uint = 0x06,

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
    /// `acu` = u16 value. `r1` = dst cursor. Appends the unsigned
    /// decimal representation of `acu` at `[r1]`, advances `r1`.
    /// (`format_int_to_buf` is the signed counterpart.)
    format_uint_to_buf = 0x15,
    /// `acu` = value (or str pointer for the `str` type). `r1` = dst
    /// cursor. `r2` = width (bits 0-7) | fill (bits 8-15). `r3` = type
    /// (bits 0-2) | align (bits 3-4) | signed (bit 5) | zero-pad (bit 6) |
    /// has-precision (bit 7) | precision (bits 8-15). Appends `acu`
    /// formatted per a §3.2.2 format spec at `[r1]`, advances `r1`.
    format_spec_to_buf = 0x16,
    /// `str.format(fmt, args)`. `acu` = format string. `r1` = dst cursor.
    /// `r2` = base of the `args` words. `r3` = count (bits 0-7) | element
    /// default type (bits 8-10) | element-signed (bit 11). Parses `$(N)` /
    /// `$(N:spec)` placeholders + `$$`, formats `args[N]` at `[r1]`.
    format_runtime = 0x17,

    /// `acu` = requested size in bytes. On success: `acu` ← the
    /// address of the freshly-allocated block, and the VM's bump
    /// cursor advances by the requested size. Raises the
    /// `heap_exhausted` fault when the cursor is 0 (program
    /// declared no heap), when the request overflows the 16-bit
    /// address space, or when the new cursor would collide with
    /// the stack (`new_cursor > sp`).
    alloc = 0x20,

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
        .print_str, .print_int, .print_uint, .print_char, .print_newline, .print_fixed => {
            const writer = vm.host.out orelse return ok;
            return dispatchPrint(vm, id, writer);
        },
        .format_str_to_buf => formatStrToBuf(vm),
        .format_int_to_buf => formatIntToBuf(vm) catch return fault(vm, .invalid_opcode),
        .format_uint_to_buf => formatUintToBuf(vm) catch return fault(vm, .invalid_opcode),
        .format_spec_to_buf => formatSpecToBuf(vm) catch return fault(vm, .invalid_opcode),
        .format_runtime => formatRuntime(vm) catch return fault(vm, .invalid_opcode),
        .format_char_to_buf => formatCharToBuf(vm),
        .format_fixed_to_buf => formatFixedToBuf(vm) catch return fault(vm, .invalid_opcode),
        .format_terminate_buf => formatTerminateBuf(vm),
        .alloc => return allocSyscall(vm),
        // Unknown id — open-enum coercion picks this up; future
        // syscall ids should add an arm above.
        _ => return fault(vm, .invalid_opcode),
    }
    return ok;
}

/// `sys alloc` (0x20) — bump-allocate `acu` bytes on the heap.
/// Returns the freshly-allocated address in `acu` and advances
/// `vm.heap_cursor` by the requested size. Faults on out-of-heap.
fn allocSyscall(vm: *VM) StepResult {
    const cursor = vm.heap_cursor;
    if (cursor == 0) return fault(vm, .heap_exhausted);
    const size = vm.regs.read(.acu);
    // @as: widen both u16 operands to u32 so the overflow check sees the real sum, not the wrapped low 16 bits.
    const new_cursor: u32 = @as(u32, cursor) + @as(u32, size);
    if (new_cursor > 0xFFFF) return fault(vm, .heap_exhausted);
    if (new_cursor > vm.regs.read(.sp)) return fault(vm, .heap_exhausted);
    // @as: u32 fits in u16 here — the check above proved it.
    vm.heap_cursor = @intCast(new_cursor);
    vm.regs.write(.acu, cursor);
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
        .print_uint => {
            const v: u16 = vm.regs.read(.acu);
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

fn formatUintToBuf(vm: *VM) !void {
    const v: u16 = vm.regs.read(.acu);
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

/// Append `acu` formatted per a §3.2.2 format spec (the packed `r2` / `r3`
/// params, mirroring `opcodes.FmtSpec`) to the buffer at `r1`.
fn formatSpecToBuf(vm: *VM) !void {
    const std = @import("std");
    var buf: [80]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try formatValueTo(vm, &w, vm.regs.read(.acu), vm.regs.read(.r2), vm.regs.read(.r3));
    for (w.buffered()) |b| writeBufByte(vm, b);
}

/// Render `value` formatted per the packed `r2` / `r3` format-spec params
/// to `w` (no cursor side effects). Shared by `format_spec_to_buf` and the
/// runtime `format`'s per-placeholder formatting. Numeric types render
/// through the host writer's radix formatter; `str` / `char` / `fixed`
/// align a byte run. For the `str` type `value` is the byte pointer.
fn formatValueTo(vm: *VM, w: *@import("std").Io.Writer, value: u16, r2: u16, r3: u16) !void {
    const std = @import("std");
    // safety: each field is masked into its byte/bit width before the cast.
    const width: u8 = @truncate(r2);
    const fill: u8 = @truncate(r2 >> 8);
    const ftype: u16 = r3 & 0x7;
    const align_bits: u16 = (r3 >> 3) & 0x3;
    const signed = r3 & (1 << 5) != 0;
    const zero_pad = r3 & (1 << 6) != 0;
    const has_prec = r3 & (1 << 7) != 0;
    const precision: u8 = @truncate(r3 >> 8);

    const is_text = ftype == 5 or ftype == 6;
    const alignment: std.fmt.Alignment = switch (align_bits) {
        1 => .left,
        2 => .right,
        3 => .center,
        else => if (is_text) .left else .right, // type default
    };
    const fill_char: u8 = if (zero_pad and !is_text) '0' else if (fill == 0) ' ' else fill;
    const opts: std.fmt.Options = .{
        .width = if (width != 0) width else null,
        .fill = fill_char,
        .alignment = alignment,
        .precision = if (has_prec and !is_text) precision else null,
    };

    switch (ftype) {
        0 => {
            // Decimal. A positive (or unsigned) value renders its magnitude
            // with no sign. A negative value keeps its `-`; zero-padding is
            // sign-aware (`-` then zero-padded magnitude), since the host
            // writer would otherwise pad ahead of the sign (`0-42`).
            // safety: `value` holds the i16 bit pattern for a signed decimal.
            const sv: i16 = @bitCast(value);
            if (signed and sv < 0) {
                // @as: widen i16 → i32 so negating -32768 can't overflow; the magnitude fits u16.
                const mag: u16 = @intCast(-@as(i32, sv));
                if (zero_pad and width > 1) {
                    try w.writeByte('-');
                    try w.printInt(mag, 10, .lower, .{ .width = width - 1, .fill = '0', .alignment = .right });
                } else {
                    try w.printInt(sv, 10, .lower, opts);
                }
            } else {
                try w.printInt(value, 10, .lower, opts);
            }
        },
        1 => try w.printInt(value, 16, .lower, opts),
        2 => try w.printInt(value, 16, .upper, opts),
        3 => try w.printInt(value, 2, .lower, opts),
        4 => try w.printInt(value, 8, .lower, opts),
        6 => {
            // @as: a `char` value renders its low byte.
            const ch: u8 = @truncate(value);
            try w.alignBufferOptions(&[1]u8{ch}, opts);
        },
        5 => {
            // `str`: bytes at `[value]`, truncated to `precision` (max length).
            var tmp: [80]u8 = undefined;
            var n: usize = 0;
            var src: u16 = value;
            const max: usize = if (has_prec) @min(precision, tmp.len) else tmp.len;
            while (n < max) {
                const b = vm.readByte(src);
                if (b == 0) break;
                tmp[n] = b;
                n += 1;
                src +%= 1;
            }
            try w.alignBufferOptions(tmp[0..n], opts);
        },
        else => {
            // `fixed` (7): render the Q8.8 form, then apply width / align.
            var tmp: [16]u8 = undefined;
            var tw: std.Io.Writer = .fixed(&tmp);
            try writeFixedValueTo(&tw, value);
            try w.alignBufferOptions(tw.buffered(), opts);
        },
    }
}

/// `str.format(fmt, args)` — walk the runtime format string, copying
/// literal bytes and replacing `$(N)` / `$(N:spec)` with `args[N]`
/// formatted per the (runtime-parsed) spec. `$$` is a literal `$`. An
/// out-of-range or digit-less placeholder is dropped (the format string is
/// runtime data — leniency over a fault).
fn formatRuntime(vm: *VM) !void {
    const std = @import("std");
    const args_base: u16 = vm.regs.read(.r2);
    const r3 = vm.regs.read(.r3);
    // safety: each field is masked to its width.
    const count: u16 = r3 & 0xFF;
    const elem_ftype: u16 = (r3 >> 8) & 0x7;
    const elem_signed: bool = r3 & (1 << 11) != 0;

    var i: u16 = vm.regs.read(.acu);
    while (true) {
        const c = vm.readByte(i);
        if (c == 0) break;
        if (c == '$') {
            const nx = vm.readByte(i +% 1);
            if (nx == '$') { // `$$` → literal `$`
                writeBufByte(vm, '$');
                i +%= 2;
                continue;
            }
            if (nx == '(') {
                var j: u16 = i +% 2;
                // Positional index `N`.
                var n: u16 = 0;
                var have_digit = false;
                while (vm.readByte(j) >= '0' and vm.readByte(j) <= '9') : (j +%= 1) {
                    n = n *% 10 +% (vm.readByte(j) - '0');
                    have_digit = true;
                }
                // Optional `:spec`, captured up to `)`.
                var spec: [24]u8 = undefined;
                var spec_len: usize = 0;
                if (vm.readByte(j) == ':') {
                    j +%= 1;
                    while (vm.readByte(j) != ')' and vm.readByte(j) != 0) : (j +%= 1) {
                        if (spec_len < spec.len) {
                            spec[spec_len] = vm.readByte(j);
                            spec_len += 1;
                        }
                    }
                }
                if (vm.readByte(j) == ')') j +%= 1;
                if (have_digit and n < count) {
                    const value: u16 = vm.readWord(args_base +% n *% 2);
                    const params = packSpecRuntime(spec[0..spec_len], elem_ftype, elem_signed);
                    var tmp: [80]u8 = undefined;
                    var w: std.Io.Writer = .fixed(&tmp);
                    try formatValueTo(vm, &w, value, params.r2, params.r3);
                    for (w.buffered()) |b| writeBufByte(vm, b);
                }
                i = j;
                continue;
            }
        }
        writeBufByte(vm, c);
        i +%= 1;
    }
}

/// Parse a runtime format spec (`[[fill]align][0][width][.precision][type]`)
/// into the packed `format_spec_to_buf` `r2` / `r3` words, defaulting the
/// type + signedness to the element's when the spec omits a type letter.
/// Mirrors the compile-time `lang/fmtspec.zig`; leniency over errors since
/// the format string is runtime data.
fn packSpecRuntime(bytes: []const u8, default_ftype: u16, default_signed: bool) struct { r2: u16, r3: u16 } {
    var fill: u8 = 0;
    var align_code: u16 = 0;
    var zero_pad = false;
    var width: u16 = 0;
    var has_prec = false;
    var precision: u16 = 0;
    var ftype: u16 = default_ftype;
    var signed = default_signed;

    var k: usize = 0;
    if (bytes.len >= 2 and isAlignByte(bytes[1])) {
        fill = bytes[0];
        align_code = alignCode(bytes[1]);
        k = 2;
    } else if (bytes.len >= 1 and isAlignByte(bytes[0])) {
        align_code = alignCode(bytes[0]);
        k = 1;
    }
    if (k < bytes.len and bytes[k] == '0') {
        zero_pad = true;
        k += 1;
    }
    while (k < bytes.len and bytes[k] >= '0' and bytes[k] <= '9') : (k += 1) width = width *% 10 +% (bytes[k] - '0');
    if (k < bytes.len and bytes[k] == '.') {
        k += 1;
        has_prec = true;
        while (k < bytes.len and bytes[k] >= '0' and bytes[k] <= '9') : (k += 1) precision = precision *% 10 +% (bytes[k] - '0');
    }
    if (k < bytes.len) switch (bytes[k]) {
        'd' => ftype = 0,
        'x' => {
            ftype = 1;
            signed = false;
        },
        'X' => {
            ftype = 2;
            signed = false;
        },
        'b' => {
            ftype = 3;
            signed = false;
        },
        'o' => {
            ftype = 4;
            signed = false;
        },
        's' => ftype = 5,
        'c' => ftype = 6,
        else => {},
    };

    var r3: u16 = (ftype & 0x7) | (align_code << 3);
    if (signed) r3 |= (1 << 5);
    if (zero_pad) r3 |= (1 << 6);
    if (has_prec) r3 |= (1 << 7) | ((precision & 0xFF) << 8);
    // @as: width + fill are u8 fields packed into the 16-bit r2 word.
    const r2: u16 = (width & 0xFF) | (@as(u16, fill) << 8);
    return .{ .r2 = r2, .r3 = r3 };
}

fn isAlignByte(c: u8) bool {
    return c == '<' or c == '>' or c == '^';
}

fn alignCode(c: u8) u16 {
    return switch (c) {
        '<' => 1,
        '>' => 2,
        '^' => 3,
        else => 0,
    };
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
    return writeFixedValueTo(writer, vm.regs.read(.acu));
}

/// Render the Q8.8 value `raw` as `<int>.<3-digit-frac>` to `writer`.
fn writeFixedValueTo(writer: *@import("std").Io.Writer, raw_bits: u16) !void {
    // safety: Q8.8 is a u16 — bit-cast to i16 for sign + magnitude split.
    const raw: i16 = @bitCast(raw_bits);
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
