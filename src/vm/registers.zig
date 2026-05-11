/// Register file: 15 u16 slots, indexable by name or by operand
/// index. `flg` gets bit-level helpers so callers don't open-code
/// the mask math.
const std = @import("std");

/// Number of named registers.
pub const reg_count: u8 = 15;

/// Highest valid operand index. Anything above raises an
/// invalid-register fault.
pub const max_index: u8 = 0x0E;

/// Named register handles. The numeric value IS the operand-encoding
/// index — cast via `@intFromEnum` / `@enumFromInt` at decode time.
pub const Register = enum(u8) {
    /// Instruction pointer.
    ip = 0x00,
    /// Accumulator. Implicit destination for short-form ALU ops;
    /// holds the high half of `mul` results and the remainder of
    /// `div`.
    acu = 0x01,
    /// General purpose.
    r1 = 0x02,
    /// General purpose.
    r2 = 0x03,
    /// General purpose.
    r3 = 0x04,
    /// General purpose.
    r4 = 0x05,
    /// General purpose.
    r5 = 0x06,
    /// General purpose.
    r6 = 0x07,
    /// General purpose.
    r7 = 0x08,
    /// General purpose.
    r8 = 0x09,
    /// Stack pointer. Stack grows downward.
    sp = 0x0A,
    /// Frame pointer. Set by `call`, restored by `ret`.
    fp = 0x0B,
    /// Memory bank — selects the 16KB page mapped at the bank window.
    mb = 0x0C,
    /// Interrupt mask. Bit `N` enables vector `N`.
    im = 0x0D,
    /// Status flags. See `Flag` for the bit layout.
    flg = 0x0E,
};

/// Bit positions inside the `flg` register.
pub const Flag = enum(u4) {
    /// Result was zero.
    zero = 0,
    /// Result high bit was 1 (signed-negative).
    negative = 1,
    /// Set on unsigned overflow / borrow / last bit shifted or
    /// rotated out.
    carry = 2,
    /// Signed overflow.
    overflow = 3,
    /// Interrupt-disable. `1` blocks IRQs globally.
    interrupt_disable = 4,
};

/// 15-slot u16 register file.
pub const Registers = struct {
    /// Backing storage. Public so tests and the loader can poke
    /// directly; production callers prefer the typed helpers.
    values: [reg_count]u16,

    /// Fresh zeroed file.
    pub fn init() Registers {
        return .{ .values = @splat(0) };
    }

    /// Read by named handle.
    pub fn read(self: Registers, reg: Register) u16 {
        return self.values[@intFromEnum(reg)];
    }

    /// Write by named handle.
    pub fn write(self: *Registers, reg: Register, value: u16) void {
        self.values[@intFromEnum(reg)] = value;
    }

    /// Read by raw operand index. `null` for out-of-range — caller
    /// raises the fault.
    pub fn readByIndex(self: Registers, index: u8) ?u16 {
        if (index > max_index) return null;
        return self.values[index];
    }

    /// Write by raw operand index. `false` for out-of-range — caller
    /// raises the fault.
    pub fn writeByIndex(self: *Registers, index: u8, value: u16) bool {
        if (index > max_index) return false;
        self.values[index] = value;
        return true;
    }

    /// Test a flag bit.
    pub fn flagSet(self: Registers, flag: Flag) bool {
        // @as: widen the literal `1` to u16 for the shift to produce a u16 mask
        const mask: u16 = @as(u16, 1) << @intFromEnum(flag);
        return (self.read(.flg) & mask) != 0;
    }

    /// Set a flag bit, leaving the other bits intact.
    pub fn setFlag(self: *Registers, flag: Flag, value: bool) void {
        // @as: widen the literal `1` to u16 for the shift to produce a u16 mask
        const mask: u16 = @as(u16, 1) << @intFromEnum(flag);
        const cur = self.read(.flg);
        const next: u16 = if (value) cur | mask else cur & ~mask;
        self.write(.flg, next);
    }
};
