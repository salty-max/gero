/// `MemoryMapper` — the indirection layer between the VM and RAM.
/// Hosts can register `Device` callbacks against address ranges so
/// memory-mapped IO (VRAM, registers) intercepts reads / writes.
/// When no device claims an address the access falls through to
/// the underlying `Memory`.
const std = @import("std");
const Memory = @import("memory.zig").Memory;

/// Stable handle returned by `map`. Pass to `unmap` to remove the
/// region. `0` is reserved for "no region" so callers can use the
/// raw integer in optional patterns.
pub const RegionId = u32;

/// Errors returned by `map`.
pub const MapError = error{
    /// `size == 0` — caller likely intended at least one byte.
    EmptyRange,
    /// `start + size` overshoots the 64KB address space.
    RangeOverflow,
};

/// Host-pluggable IO interface. Intrusive: the host embeds a
/// `Device` as a field of its concrete struct, supplies a vtable
/// whose callbacks recover the parent struct via `@fieldParentPtr`,
/// and hands `&concrete.device` to the mapper.
///
/// No type erasure — the mapper stores `*Device` (typed) and the
/// host's vtable callbacks know exactly which struct owns them.
pub const Device = struct {
    vtable: *const VTable,

    /// Method table. Each callback receives the same `*Device`
    /// pointer the mapper holds; the host recovers the parent
    /// struct via `@fieldParentPtr("<field-name>", self)`.
    pub const VTable = struct {
        readByte: *const fn (self: *Device, addr: u16) u8,
        writeByte: *const fn (self: *Device, addr: u16, value: u8) void,
        readWord: *const fn (self: *Device, addr: u16) u16,
        writeWord: *const fn (self: *Device, addr: u16, value: u16) void,
    };

    /// Convenience: byte read through the vtable.
    pub fn readByte(self: *Device, addr: u16) u8 {
        return self.vtable.readByte(self, addr);
    }

    /// Convenience: byte write through the vtable.
    pub fn writeByte(self: *Device, addr: u16, value: u8) void {
        self.vtable.writeByte(self, addr, value);
    }

    /// Convenience: word read through the vtable.
    pub fn readWord(self: *Device, addr: u16) u16 {
        return self.vtable.readWord(self, addr);
    }

    /// Convenience: word write through the vtable.
    pub fn writeWord(self: *Device, addr: u16, value: u16) void {
        self.vtable.writeWord(self, addr, value);
    }
};

const Region = struct {
    id: RegionId,
    device: *Device,
    start: u16,
    /// Inclusive — kept as `u16` so the full last byte 0xFFFF fits.
    end: u16,
};

/// Routes memory accesses: device-claimed addresses go through the
/// device vtable, everything else falls through to the underlying
/// `Memory`. Regions are scanned newest-first so the most-recent
/// `map` wins on overlap.
pub const MemoryMapper = struct {
    /// The underlying RAM. Accessible directly for raw inspection
    /// (loader, tests); production callers prefer the routed
    /// `readByte` / `writeByte` / `readWord` / `writeWord` below.
    mem: Memory,
    regions: std.ArrayList(Region),
    allocator: std.mem.Allocator,
    next_id: RegionId,

    /// Fresh mapper with empty `Memory` and no devices mapped.
    pub fn init(allocator: std.mem.Allocator) MemoryMapper {
        return .{
            .mem = Memory.init(),
            .regions = .empty,
            .allocator = allocator,
            .next_id = 1,
        };
    }

    /// Release the region list. RAM is stack-allocated so it does
    /// not need an explicit free.
    pub fn deinit(self: *MemoryMapper) void {
        self.regions.deinit(self.allocator);
    }

    /// Claim `[start, start + size - 1]` for `device`. Returns a
    /// handle that `unmap` consumes. Overlap is allowed — later
    /// `map` calls take priority.
    pub fn map(
        self: *MemoryMapper,
        device: *Device,
        start: u16,
        size: usize,
    ) (std.mem.Allocator.Error || MapError)!RegionId {
        if (size == 0) return error.EmptyRange;
        // @as: widen `u16` to `usize` so the arithmetic does not wrap
        const last = @as(usize, start) + size - 1;
        if (last > 0xFFFF) return error.RangeOverflow;

        const id = self.next_id;
        self.next_id += 1;
        try self.regions.append(self.allocator, .{
            .id = id,
            .device = device,
            .start = start,
            .end = @intCast(last),
        });
        return id;
    }

    /// Remove a previously-mapped region. Returns `false` if the
    /// id is unknown (already unmapped, or never registered).
    pub fn unmap(self: *MemoryMapper, id: RegionId) bool {
        var i: usize = 0;
        while (i < self.regions.items.len) : (i += 1) {
            if (self.regions.items[i].id == id) {
                _ = self.regions.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Routed byte read.
    pub fn readByte(self: MemoryMapper, addr: u16) u8 {
        if (self.findDevice(addr)) |dev| return dev.readByte(addr);
        return self.mem.readByte(addr);
    }

    /// Routed byte write.
    pub fn writeByte(self: *MemoryMapper, addr: u16, value: u8) void {
        if (self.findDevice(addr)) |dev| {
            dev.writeByte(addr, value);
            return;
        }
        self.mem.writeByte(addr, value);
    }

    /// Routed word read. Routing is decided by the starting address
    /// — a word straddling a region boundary is delivered to the
    /// device that claims `addr`, matching real-bus behavior on
    /// devices that don't honor unaligned accesses.
    pub fn readWord(self: MemoryMapper, addr: u16) u16 {
        if (self.findDevice(addr)) |dev| return dev.readWord(addr);
        return self.mem.readWord(addr);
    }

    /// Routed word write. Same routing rule as `readWord`.
    pub fn writeWord(self: *MemoryMapper, addr: u16, value: u16) void {
        if (self.findDevice(addr)) |dev| {
            dev.writeWord(addr, value);
            return;
        }
        self.mem.writeWord(addr, value);
    }

    fn findDevice(self: MemoryMapper, addr: u16) ?*Device {
        // Iterate newest-first so the most-recently-mapped region
        // wins on overlap.
        var i: usize = self.regions.items.len;
        while (i > 0) {
            i -= 1;
            const r = self.regions.items[i];
            if (addr >= r.start and addr <= r.end) return r.device;
        }
        return null;
    }
};
