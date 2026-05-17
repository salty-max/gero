/// The gero VM. Composes the register file and the memory mapper.
/// Banking and the dispatch loop layer on top in subsequent PRs.
const std = @import("std");
const registers = @import("registers.zig");
const memory = @import("memory.zig");
const mapper = @import("mapper.zig");
const dispatch_mod = @import("dispatch.zig");
const opcodes_mod = @import("opcodes.zig");
const banks_mod = @import("banks.zig");
const loader_mod = @import("loader.zig");

/// Re-export: named register handles.
pub const Register = registers.Register;
/// Re-export: register file type.
pub const Registers = registers.Registers;
/// Re-export: flag bit positions inside `flg`.
pub const Flag = registers.Flag;
/// Re-export: 64KB memory type.
pub const Memory = memory.Memory;
/// Re-export: host-pluggable IO interface.
pub const Device = mapper.Device;
/// Re-export: the routing mapper that wraps `Memory`.
pub const MemoryMapper = mapper.MemoryMapper;
/// Re-export: handle returned by `MemoryMapper.map`.
pub const RegionId = mapper.RegionId;
/// Re-export: errors from `MemoryMapper.map`.
pub const MapError = mapper.MapError;
/// Re-export: outcome of `step` / `run`.
pub const StepResult = dispatch_mod.StepResult;
/// Re-export: reserved interrupt / fault vectors.
pub const Vector = dispatch_mod.Vector;
/// Re-export: one fetch-decode-execute cycle.
pub const step = dispatch_mod.step;
/// Re-export: dispatch loop until halt / fault.
pub const run = dispatch_mod.run;
/// Re-export: deliver a fault through the interrupt mechanism.
pub const raiseFault = dispatch_mod.raiseFault;
/// Re-export: deliver a maskable IRQ (respects `flg.I` and `im`).
pub const raiseIrq = dispatch_mod.raiseIrq;
/// Re-export: address of the IVT slot for a given vector.
pub const ivtSlot = dispatch_mod.ivtSlot;
/// Re-export: IVT base address.
pub const ivt_base = dispatch_mod.ivt_base;
/// Re-export: opcode operand kinds.
pub const Operand = opcodes_mod.Operand;
/// Re-export: opcode metadata entry.
pub const OpcodeInfo = opcodes_mod.OpcodeInfo;
/// Re-export: 256-entry opcode lookup table.
pub const opcode_table = opcodes_mod.table;
/// Re-export: byte size of one operand.
pub const operandSize = opcodes_mod.operandSize;
/// Re-export: bank pool type.
pub const Banks = banks_mod.Banks;
/// Re-export: bank pool errors.
pub const BanksError = banks_mod.BanksError;
/// Re-export: bank-window base address.
pub const bank_window_base = banks_mod.window_base;
/// Re-export: bank-window end address inclusive.
pub const bank_window_end = banks_mod.window_end;
/// Re-export: single-bank size in bytes.
pub const bank_size = banks_mod.bank_size;
/// Re-export: `.gx` parser entry point.
pub const parseGx = loader_mod.parse;
/// Re-export: parsed program shape.
pub const LoadedProgram = loader_mod.LoadedProgram;
/// Re-export: loader error set.
pub const LoaderError = loader_mod.LoaderError;

/// Boot-state default for `sp` — top of memory minus 1 word so the
/// first push lands on a valid word.
pub const sp_boot: u16 = 0xFFFE;

/// Boot-state default for `fp` — same as `sp_boot` (no frames open).
pub const fp_boot: u16 = 0xFFFE;

/// Boot-state default for `im` — every maskable vector enabled.
pub const im_boot: u16 = 0xFFFF;

/// Host-side I/O hookup. The `sys` opcode reads from / writes to
/// these handles instead of touching real OS state directly, so
/// the VM stays embeddable + testable (the host can install a
/// captured buffer instead of stdout).
///
/// `null` slots mean "the syscall is a silent no-op" — useful for
/// CI / tests that don't care about output.
pub const Host = struct {
    /// Sink for `sys` output syscalls (`print_str` / `print_int` /
    /// `print_char` / `print_newline`).
    out: ?*std.Io.Writer = null,
};

/// The VM. Owns the register file, the memory mapper (which
/// holds the 64KB RAM and the host device registry), and the
/// optional bank pool that backs the `0xC000..0xFEFF` window.
pub const VM = struct {
    regs: Registers,
    mmap: MemoryMapper,
    /// `null` when the program is unbanked — the bank window
    /// falls through to plain RAM in that case.
    banks: ?Banks,
    /// Total instructions retired since boot. `step` increments
    /// by one per dispatch (faulting instructions counted too —
    /// they still consumed a cycle).
    cycles: u64,
    /// Host-side I/O hooks consulted by the `sys` opcode. Default
    /// (`.{}`) leaves every sink `null` so `sys` syscalls become
    /// silent no-ops — fine for tests / headless smoke runs that
    /// don't care about output.
    host: Host,

    /// Construct a fresh VM with default boot state. `ip` is left
    /// at 0; the loader sets it to the program's entry point. The
    /// `allocator` backs the device registry — pass the runtime
    /// allocator (or `std.testing.allocator` in tests).
    pub fn init(allocator: std.mem.Allocator) VM {
        var vm: VM = .{
            .regs = Registers.init(),
            .mmap = MemoryMapper.init(allocator),
            .banks = null,
            .cycles = 0,
            .host = .{},
        };
        vm.bootInitRegisters();
        return vm;
    }

    /// Release VM-owned resources (the device registry + banks).
    pub fn deinit(self: *VM) void {
        if (self.banks) |*b| b.deinit();
        self.mmap.deinit();
    }

    /// Allocate a fresh bank pool of `bank_count` zero banks,
    /// the last `sram_bank_count` of which are battery-backed.
    /// Replaces any previously-installed pool.
    pub fn installBanks(
        self: *VM,
        allocator: std.mem.Allocator,
        bank_count: u8,
        sram_bank_count: u8,
    ) (std.mem.Allocator.Error || BanksError)!void {
        if (self.banks) |*b| b.deinit();
        self.banks = try Banks.init(allocator, bank_count, sram_bank_count);
    }

    /// Same as `installBanks` but seeds the pool from `image`.
    /// `image.len` must equal `bank_count * bank_size`.
    pub fn installBanksWithImage(
        self: *VM,
        allocator: std.mem.Allocator,
        image: []const u8,
        bank_count: u8,
        sram_bank_count: u8,
    ) (std.mem.Allocator.Error || BanksError)!void {
        if (self.banks) |*b| b.deinit();
        self.banks = try Banks.initWithImage(allocator, image, bank_count, sram_bank_count);
    }

    /// Persisted SRAM bytes (read-only). Empty when the pool is
    /// not installed or `sram_bank_count == 0`.
    pub fn sramSlice(self: *const VM) []const u8 {
        if (self.banks) |b| return b.sramSlice();
        return &.{};
    }

    /// Mutable SRAM bytes — the host writes restored bytes here
    /// during boot.
    pub fn sramSliceMut(self: *VM) []u8 {
        if (self.banks) |*b| return b.sramSliceMut();
        return &.{};
    }

    /// Load a parsed `.gx` program: copies the base image into
    /// RAM at `0x0000`, sets `ip` to the entry point, and
    /// installs zeroed bank storage if the program is banked.
    /// The caller is responsible for seeding SRAM via
    /// `sramSliceMut` after boot if a save store exists.
    pub fn boot(
        self: *VM,
        allocator: std.mem.Allocator,
        loaded: LoadedProgram,
    ) (std.mem.Allocator.Error || BanksError)!void {
        @memcpy(self.mmap.mem.bytes[0..loaded.image.len], loaded.image);
        self.regs.write(.ip, loaded.header.entry_point);
        if (loaded.header.bank_count > 0) {
            try self.installBanksWithImage(
                allocator,
                loaded.banks,
                loaded.header.bank_count,
                loaded.header.sram_bank_count,
            );
        }
    }

    /// Bank-aware byte read. Falls through to plain RAM outside
    /// the bank window, or when no bank pool is installed.
    pub fn readByte(self: *const VM, addr: u16) u8 {
        if (banks_mod.inWindow(addr)) {
            if (self.banks) |b| return b.readByte(self.regs.read(.mb), addr);
        }
        return self.mmap.readByte(addr);
    }

    /// Bank-aware byte write.
    pub fn writeByte(self: *VM, addr: u16, value: u8) void {
        if (banks_mod.inWindow(addr)) {
            if (self.banks) |*b| {
                b.writeByte(self.regs.read(.mb), addr, value);
                return;
            }
        }
        self.mmap.writeByte(addr, value);
    }

    /// Bank-aware word read. The low and high bytes are routed
    /// independently, so a word straddling the window edge gets
    /// the right source for each half.
    pub fn readWord(self: *const VM, addr: u16) u16 {
        const lo: u16 = self.readByte(addr);
        const hi: u16 = self.readByte(addr +% 1);
        return lo | (hi << 8);
    }

    /// Bank-aware word write.
    pub fn writeWord(self: *VM, addr: u16, value: u16) void {
        self.writeByte(addr, @truncate(value & 0xFF));
        self.writeByte(addr +% 1, @truncate((value >> 8) & 0xFF));
    }

    /// Re-applies the register defaults. Public so the loader can
    /// re-boot between programs without recreating memory (memory
    /// is deliberately preserved — useful for SRAM-backed runs).
    pub fn bootInitRegisters(self: *VM) void {
        self.regs.write(.ip, 0);
        self.regs.write(.acu, 0);
        self.regs.write(.r1, 0);
        self.regs.write(.r2, 0);
        self.regs.write(.r3, 0);
        self.regs.write(.r4, 0);
        self.regs.write(.r5, 0);
        self.regs.write(.r6, 0);
        self.regs.write(.r7, 0);
        self.regs.write(.r8, 0);
        self.regs.write(.sp, sp_boot);
        self.regs.write(.fp, fp_boot);
        self.regs.write(.mb, 0);
        self.regs.write(.im, im_boot);
        self.regs.write(.flg, 0);
    }
};
