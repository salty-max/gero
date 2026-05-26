const std = @import("std");
const Memory = @import("memory.zig").Memory;

/// Handle returned by `map`. Pass to `unmap` to remove the region.
/// `0` is reserved for "no region".
pub const RegionId = u32;

/// Errors returned by `map`.
pub const MapError = error{
    /// `size == 0`.
    EmptyRange,
    /// `start + size` overshoots the 64KB address space.
    RangeOverflow,
};

/// Host-pluggable I/O interface. Intrusive: the host embeds a
/// `Device` field in its concrete struct, supplies a vtable whose
/// callbacks recover the parent via `@fieldParentPtr`, and hands
/// `&concrete.device` to the mapper.
///
/// ```
/// const Vram = struct {
///     bytes: [16 * 1024]u8,
///     device: Device = .{ .vtable = &vtable },
///     const vtable: Device.VTable = .{ .readByte = read, .writeByte = write, ... };
/// };
/// _ = try mapper.map(&vram.device, 0x4000, 16 * 1024);
/// ```
pub const Device = struct {
    vtable: *const VTable,

    /// Method table. Each callback receives the `*Device` pointer
    /// the mapper holds; recover the parent via `@fieldParentPtr`.
    pub const VTable = struct {
        readByte: *const fn (self: *Device, addr: u16) u8,
        writeByte: *const fn (self: *Device, addr: u16, value: u8) void,
        readWord: *const fn (self: *Device, addr: u16) u16,
        writeWord: *const fn (self: *Device, addr: u16, value: u16) void,
    };

    /// Byte read through the vtable.
    pub fn readByte(self: *Device, addr: u16) u8 {
        return self.vtable.readByte(self, addr);
    }

    /// Byte write through the vtable.
    pub fn writeByte(self: *Device, addr: u16, value: u8) void {
        self.vtable.writeByte(self, addr, value);
    }

    /// Word read through the vtable.
    pub fn readWord(self: *Device, addr: u16) u16 {
        return self.vtable.readWord(self, addr);
    }

    /// Word write through the vtable.
    pub fn writeWord(self: *Device, addr: u16, value: u16) void {
        self.vtable.writeWord(self, addr, value);
    }
};

const Region = struct {
    id: RegionId,
    device: *Device,
    start: u16,
    /// Inclusive (so `0xFFFF` is representable).
    end: u16,
};

/// Routes accesses: device-claimed addresses go through the
/// device vtable; everything else falls through to `Memory`.
/// Regions scan newest-first, so the most-recent `map` wins on
/// overlap.
pub const MemoryMapper = struct {
    /// Underlying RAM. Prefer the routed read/write methods below.
    mem: Memory,
    regions: std.ArrayList(Region),
    allocator: std.mem.Allocator,
    next_id: RegionId,

    /// Fresh mapper: empty `Memory`, no devices mapped.
    pub fn init(allocator: std.mem.Allocator) MemoryMapper {
        return .{
            .mem = Memory.init(),
            .regions = .empty,
            .allocator = allocator,
            .next_id = 1,
        };
    }

    /// Release the region list (RAM is stack-allocated).
    pub fn deinit(self: *MemoryMapper) void {
        self.regions.deinit(self.allocator);
    }

    /// Claim `[start, start + size - 1]` for `device`. Overlap is
    /// allowed; later `map` calls take priority. Returns a handle
    /// for `unmap`.
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

    /// Remove a mapped region. `false` when the id is unknown.
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

    /// Routed word read. Routing is decided by `addr`; a word
    /// straddling a region boundary goes to whichever device
    /// claims `addr`.
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
        // Newest-first: latest `map` wins on overlap.
        var i: usize = self.regions.items.len;
        while (i > 0) {
            i -= 1;
            const r = self.regions.items[i];
            if (addr >= r.start and addr <= r.end) return r.device;
        }
        return null;
    }
};
