const std = @import("std");
const registers = @import("registers.zig");
const memory = @import("memory.zig");
const mapper = @import("mapper.zig");
const dispatch_mod = @import("dispatch.zig");
const opcodes_mod = @import("opcodes.zig");
const banks_mod = @import("banks.zig");
const loader_mod = @import("loader.zig");

/// Named register handles.
pub const Register = registers.Register;
/// Register file.
pub const Registers = registers.Registers;
/// Flag bit positions inside `flg`.
pub const Flag = registers.Flag;
/// 64KB memory.
pub const Memory = memory.Memory;
/// Host-pluggable I/O interface.
pub const Device = mapper.Device;
/// Routing mapper wrapping `Memory`.
pub const MemoryMapper = mapper.MemoryMapper;
/// Handle returned by `MemoryMapper.map`.
pub const RegionId = mapper.RegionId;
/// Errors from `MemoryMapper.map`.
pub const MapError = mapper.MapError;
/// Outcome of `step` / `run`.
pub const StepResult = dispatch_mod.StepResult;
/// Reserved interrupt / fault vectors.
pub const Vector = dispatch_mod.Vector;
/// One fetch-decode-execute cycle.
pub const step = dispatch_mod.step;
/// Dispatch loop until halt / fault.
pub const run = dispatch_mod.run;
/// Deliver a fault through the interrupt mechanism.
pub const raiseFault = dispatch_mod.raiseFault;
/// Deliver a maskable IRQ (respects `flg.I` and `im`).
pub const raiseIrq = dispatch_mod.raiseIrq;
/// Address of the IVT slot for a vector.
pub const ivtSlot = dispatch_mod.ivtSlot;
/// IVT base address.
pub const ivt_base = dispatch_mod.ivt_base;
/// Opcode operand kinds.
pub const Operand = opcodes_mod.Operand;
/// Opcode metadata entry.
pub const OpcodeInfo = opcodes_mod.OpcodeInfo;
/// 256-entry opcode lookup table.
pub const opcode_table = opcodes_mod.table;
/// Byte size of one operand.
pub const operandSize = opcodes_mod.operandSize;
/// Bank pool.
pub const Banks = banks_mod.Banks;
/// Bank pool errors.
pub const BanksError = banks_mod.BanksError;
/// Bank-window base address.
pub const bank_window_base = banks_mod.window_base;
/// Bank-window end address (inclusive).
pub const bank_window_end = banks_mod.window_end;
/// Single-bank size in bytes.
pub const bank_size = banks_mod.bank_size;
/// `.gx` parser entry point.
pub const parseGx = loader_mod.parse;
/// Parsed program shape.
pub const LoadedProgram = loader_mod.LoadedProgram;
/// Loader error set.
pub const LoaderError = loader_mod.LoaderError;

/// Boot value for `sp`: top of memory minus one word.
pub const sp_boot: u16 = 0xFFFE;

/// Boot value for `fp`: same as `sp_boot`.
pub const fp_boot: u16 = 0xFFFE;

/// Boot value for `im`: every maskable vector enabled.
pub const im_boot: u16 = 0xFFFF;

/// Host-side I/O hookup. The `sys` opcode reads/writes these
/// handles instead of OS state directly, keeping the VM embeddable.
///
/// `null` slots mean "silent no-op".
pub const Host = struct {
    /// Sink for `sys` output syscalls (`print_str` / `print_int` /
    /// `print_char` / `print_newline`).
    out: ?*std.Io.Writer = null,
};

/// The VM. Owns the register file, the memory mapper, and an
/// optional bank pool backing the `0xC000..0xFEFF` window.
/// A captured VM state: everything execution can change, and nothing
/// the host owns.
///
/// Registers, RAM, banks and the scalar bookkeeping are copied.
/// The mapped-device registry and the host hooks deliberately are not —
/// a device is a live host object, so copying the registry would leave
/// two VMs writing through the same peripherals and either `deinit`
/// freeing what both point at. Devices stay mapped across a restore;
/// only what the program can change comes back.
pub const Snapshot = struct {
    regs: Registers,
    /// Raw RAM behind the mapper, captured without routing through
    /// devices — a device's state belongs to the host, not the program.
    ram: []u8,
    /// Bank pool contents, or `null` for an unbanked program.
    banks: ?[]u8,
    bank_count: u8,
    sram_bank_count: u8,
    cycles: u64,
    last_fault: ?dispatch_mod.Vector,
    heap_cursor: u16,
    allocator: std.mem.Allocator,

    /// Release the captured buffers.
    pub fn deinit(self: *Snapshot) void {
        self.allocator.free(self.ram);
        if (self.banks) |b| self.allocator.free(b);
    }
};

/// Why a snapshot could not be restored into a VM.
pub const RestoreError = error{
    /// The snapshot's bank pool doesn't match the VM's — a banked
    /// snapshot into an unbanked VM, or a different bank count.
    BankShapeMismatch,
};

/// The VM. Owns the register file, the memory mapper, and an
/// optional bank pool backing the `0xC000..0xFEFF` window.
pub const VM = struct {
    regs: Registers,
    mmap: MemoryMapper,
    /// `null` when the program is unbanked; the bank window falls
    /// through to plain RAM.
    banks: ?Banks,
    /// Instructions retired since boot. Incremented per `step`,
    /// including faulting instructions.
    cycles: u64,
    /// Host-side I/O hooks consulted by `sys`. Defaults silence
    /// every output syscall.
    host: Host,
    /// Vector of the most recent fault, or `null` if none has fired.
    /// Lets a host report *which* fault stopped a program rather than
    /// only that one did — `StepResult.halted_on_fault` carries no
    /// vector of its own.
    last_fault: ?dispatch_mod.Vector = null,
    /// Next address `sys alloc` returns. Initialized from
    /// `loaded.header.heap_base`; `0` means no heap and `sys alloc`
    /// faults on first call.
    heap_cursor: u16,

    /// Construct a fresh VM with default boot state. `ip = 0`;
    /// the loader sets the entry point.
    pub fn init(allocator: std.mem.Allocator) VM {
        var vm: VM = .{
            .regs = Registers.init(),
            .mmap = MemoryMapper.init(allocator),
            .banks = null,
            .cycles = 0,
            .host = .{},
            .last_fault = null,
            .heap_cursor = 0,
        };
        vm.bootInitRegisters();
        return vm;
    }

    /// Capture registers, RAM, banks and the scalar bookkeeping.
    /// Mapped devices and the host hooks are left out — see `Snapshot`.
    ///
    /// ```
    /// var snap = try vm.snapshot(allocator);
    /// defer snap.deinit();
    /// ```
    pub fn snapshot(self: *const VM, allocator: std.mem.Allocator) std.mem.Allocator.Error!Snapshot {
        const ram = try allocator.dupe(u8, &self.mmap.mem.bytes);
        errdefer allocator.free(ram);
        const banks: ?[]u8 = if (self.banks) |b| try allocator.dupe(u8, b.data) else null;
        return .{
            .regs = self.regs,
            .ram = ram,
            .banks = banks,
            .bank_count = if (self.banks) |b| b.bank_count else 0,
            .sram_bank_count = if (self.banks) |b| b.sram_bank_count else 0,
            .cycles = self.cycles,
            .last_fault = self.last_fault,
            .heap_cursor = self.heap_cursor,
            .allocator = allocator,
        };
    }

    /// Load `snap` back into this VM. The mapped devices and host hooks
    /// are untouched, so a peripheral written before the snapshot is
    /// still mapped and still the same object afterwards.
    ///
    /// The snapshot keeps its buffers — restoring twice is fine, and the
    /// caller still owns the `deinit`.
    pub fn restore(self: *VM, snap: Snapshot) RestoreError!void {
        if (self.banks) |*b| {
            const src = snap.banks orelse return error.BankShapeMismatch;
            if (b.bank_count != snap.bank_count or b.data.len != src.len) return error.BankShapeMismatch;
            @memcpy(b.data, src);
        } else if (snap.banks != null) {
            return error.BankShapeMismatch;
        }
        @memcpy(&self.mmap.mem.bytes, snap.ram);
        self.regs = snap.regs;
        self.cycles = snap.cycles;
        self.last_fault = snap.last_fault;
        self.heap_cursor = snap.heap_cursor;
    }

    /// Release VM-owned resources (device registry + banks).
    pub fn deinit(self: *VM) void {
        if (self.banks) |*b| b.deinit();
        self.mmap.deinit();
    }

    /// Allocate a fresh bank pool of `bank_count` zero banks; the
    /// last `sram_bank_count` are battery-backed.
    pub fn installBanks(
        self: *VM,
        allocator: std.mem.Allocator,
        bank_count: u8,
        sram_bank_count: u8,
    ) (std.mem.Allocator.Error || BanksError)!void {
        if (self.banks) |*b| b.deinit();
        self.banks = try Banks.init(allocator, bank_count, sram_bank_count);
    }

    /// Like `installBanks` but seeds the pool from `image`.
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

    /// Persisted SRAM bytes (read-only). Empty when no pool is
    /// installed or `sram_bank_count == 0`.
    pub fn sramSlice(self: *const VM) []const u8 {
        if (self.banks) |b| return b.sramSlice();
        return &.{};
    }

    /// Mutable SRAM bytes. Host writes restored bytes here at boot.
    pub fn sramSliceMut(self: *VM) []u8 {
        if (self.banks) |*b| return b.sramSliceMut();
        return &.{};
    }

    /// Load a parsed `.gx`: copies the base image into RAM at
    /// `0x0000`, sets `ip` to the entry point, and installs bank
    /// storage if the program is banked. Caller seeds SRAM via
    /// `sramSliceMut` after boot if needed.
    pub fn boot(
        self: *VM,
        allocator: std.mem.Allocator,
        loaded: LoadedProgram,
    ) (std.mem.Allocator.Error || BanksError)!void {
        @memcpy(self.mmap.mem.bytes[0..loaded.image.len], loaded.image);
        self.regs.write(.ip, loaded.header.entry_point);
        self.heap_cursor = loaded.header.heap_base;
        if (loaded.header.bank_count > 0) {
            try self.installBanksWithImage(
                allocator,
                loaded.banks,
                loaded.header.bank_count,
                loaded.header.sram_bank_count,
            );
        }
    }

    /// Bank-aware byte read. Falls through to plain RAM outside the
    /// bank window or when no pool is installed.
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

    /// Bank-aware word read. Low + high bytes route independently
    /// so a word straddling the window edge picks the right source
    /// for each half.
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

    /// Re-apply register defaults. Lets the loader re-boot without
    /// recreating memory (useful for SRAM-backed runs).
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
