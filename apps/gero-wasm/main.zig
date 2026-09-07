//! The `gero.wasm` boundary — a C-ABI surface over the toolchain and
//! the VM, for hosts with no filesystem and no allocator.
//!
//! This file is the surface itself: every `export fn` a host can call,
//! and nothing else. The shapes that cross it live in `abi.zig`, the
//! session state behind it in `session.zig`, and the operations in
//! `toolchain.zig`.
//!
//! Target is `wasm32-freestanding` rather than `wasm32-wasi`: the
//! consumer needs a narrow purpose-built surface, not a POSIX shim.
//! Print syscalls already route through `vm.host.out`, so a binding
//! captures them rather than needing stdout.

const std = @import("std");
const gero = @import("gero");
const abi = @import("abi.zig");
const session = @import("session.zig");
const toolchain = @import("toolchain.zig");
const vm = @import("vm.zig");

const Result = abi.Result;
const Status = abi.Status;
const Lang = abi.Lang;

// ---------- lifecycle (§2.1) ----------

/// Prepare the module. `arena_bytes` of 0 takes the default; a larger
/// request is clamped. Calling it again resets the session.
export fn gero_init(arena_bytes: u32) u32 {
    session.init(arena_bytes);
    return @intFromEnum(Status.ok);
}

/// Drop the last operation's scratch and the inputs written for it.
export fn gero_reset() void {
    session.reset();
}

/// Reserve `len` bytes to write source into. Survives an operation;
/// only `gero_reset` reclaims it. `0` means the region cannot satisfy
/// the request, which a host must check.
export fn gero_alloc(len: u32) u32 {
    return session.reserveInput(len);
}

/// Bytes handed out since the last reset. For a host sizing its
/// ceiling.
export fn gero_arena_used() u32 {
    return session.usedBytes();
}

/// The arena's ceiling for this session.
export fn gero_arena_limit() u32 {
    return session.limitBytes();
}

/// Where the arena begins in linear memory. Every pointer the module
/// hands out is an offset from here, so a host reads a payload at
/// `memory.buffer + gero_arena_base() + payload_ptr`.
export fn gero_arena_base() u32 {
    return session.base();
}

/// Size of the `Result` struct, so a host can assert its decoder
/// agrees with the module rather than hard-coding 20.
export fn gero_result_size() u32 {
    return @intCast(Result.encoded_size);
}

// ---------- the virtual file set (§4.2) ----------

/// Add a buffer to the set, or replace one of the same name.
/// `name` and `contents` are `(ptr, len)` into the arena.
export fn gero_file_put(name_ptr: u32, name_len: u32, src_ptr: u32, src_len: u32) u32 {
    if (!session.ready()) return @intFromEnum(Status.not_initialized);
    const name = session.slice(name_ptr, name_len) orelse return @intFromEnum(Status.bad_argument);
    const contents = session.slice(src_ptr, src_len) orelse return @intFromEnum(Status.bad_argument);
    session.putFile(name, contents) catch return @intFromEnum(Status.out_of_memory);
    return @intFromEnum(Status.ok);
}

/// Drop a buffer. Removing one that is not present is not an error.
export fn gero_file_remove(name_ptr: u32, name_len: u32) u32 {
    if (!session.ready()) return @intFromEnum(Status.not_initialized);
    const name = session.slice(name_ptr, name_len) orelse return @intFromEnum(Status.bad_argument);
    session.removeFile(name);
    return @intFromEnum(Status.ok);
}

/// Empty the set and reclaim its storage.
export fn gero_files_clear() void {
    session.clearFiles();
}

/// How many buffers the set holds.
export fn gero_file_count() u32 {
    return session.fileCount();
}

// ---------- identity ----------

/// The gero version this module was built from. The worker's `ready`
/// event carries it (§3.2) so a host can show which toolchain produced
/// the images it is running.
export fn gero_version() *const Result {
    if (session.begin()) |status| return session.fail(status);
    const copy = session.allocator().dupe(u8, gero.VERSION) catch
        return session.fail(.out_of_memory);
    return session.finish(copy, null, 0);
}

// ---------- toolchain exports (§2.2) ----------

/// Compile the named entry file to a `.gx`, resolving `use` against
/// the virtual file set.
export fn gero_compile(name_ptr: u32, name_len: u32) *const Result {
    if (session.begin()) |status| return session.fail(status);
    const name = session.slice(name_ptr, name_len) orelse return session.fail(.bad_argument);
    return toolchain.buildGr(name, .image);
}

/// Assemble the named entry file to a `.gx`, resolving `include`
/// against the virtual file set.
export fn gero_assemble(name_ptr: u32, name_len: u32) *const Result {
    if (session.begin()) |status| return session.fail(status);
    const name = session.slice(name_ptr, name_len) orelse return session.fail(.bad_argument);
    return toolchain.buildGas(name, .image);
}

/// Diagnostics for the named entry file, with no image — the editor's
/// fast path.
export fn gero_check(name_ptr: u32, name_len: u32, lang: u32) *const Result {
    if (session.begin()) |status| return session.fail(status);
    const name = session.slice(name_ptr, name_len) orelse return session.fail(.bad_argument);
    return switch (Lang.from(lang) orelse return session.fail(.bad_lang)) {
        .gr => toolchain.buildGr(name, .diagnostics_only),
        .gas => toolchain.buildGas(name, .diagnostics_only),
    };
}

/// Canonical formatting of a single buffer. Formatting is per-buffer
/// rather than per-graph: an editor formats the file in front of it,
/// and a `use` target's own formatting is its own business.
export fn gero_format(src_ptr: u32, src_len: u32, lang: u32) *const Result {
    if (session.begin()) |status| return session.fail(status);
    const src = session.slice(src_ptr, src_len) orelse return session.fail(.bad_argument);
    const which = Lang.from(lang) orelse return session.fail(.bad_lang);
    const arena = session.allocator();

    const formatted = switch (which) {
        .gr => toolchain.formatGr(arena, src),
        .gas => toolchain.formatGas(arena, src),
    } catch return session.fail(.out_of_memory);

    // A buffer that does not parse formats to nothing rather than to a
    // rewrite from a partial tree — the same rule the language server
    // follows, for the same reason.
    return session.finish(formatted, null, 0);
}

/// Disassemble a `.gx` into annotated assembly. `bank` selects a bank
/// window, or `no_bank` for the base image.
export fn gero_disasm(gx_ptr: u32, gx_len: u32, bank: u32) *const Result {
    if (session.begin()) |status| return session.fail(status);
    const image = session.slice(gx_ptr, gx_len) orelse return session.fail(.bad_argument);
    const arena = session.allocator();

    const header = gero.disasm.parseHeader(image) catch return session.fail(.bad_argument);
    const region = if (bank == no_bank) header.image else blk: {
        if (bank >= header.bank_count) return session.fail(.bad_argument);
        const window = gero.gx.bank_disk_size;
        const start = @as(usize, bank) * window;
        break :blk header.banks[start .. start + window];
    };

    var out = std.Io.Writer.Allocating.init(arena);
    gero.disasm.writeBytes(arena, &out.writer, region) catch return session.fail(.out_of_memory);
    return session.finish(out.written(), null, 0);
}

/// `bank` value selecting the base image rather than a bank window.
pub const no_bank: u32 = 0xFFFF_FFFF;
/// The debug tables from a `.gx`, as JSON: the symbols that drive a
/// disassembly's label column, and the line rows that drive
/// source-level stepping and click-to-breakpoint (§6).
///
/// Separate from the build result rather than a sixth `Result` field:
/// the tables live in the image the build already returned, a host
/// wants them once per build rather than on every operation, and a
/// release image carries neither.
export fn gero_debug_info(gx_ptr: u32, gx_len: u32) *const Result {
    if (session.begin()) |status| return session.fail(status);
    const image = session.slice(gx_ptr, gx_len) orelse return session.fail(.bad_argument);
    const arena = session.allocator();

    const header = gero.disasm.parseHeader(image) catch return session.fail(.bad_argument);
    var out = std.Io.Writer.Allocating.init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };

    toolchain.writeDebugJson(arena, &jw, header.debug) catch return session.fail(.out_of_memory);
    return session.finish(out.written(), null, 0);
}

// ---------- VM session exports (§2.2) ----------

/// Start a VM session. Returns a handle, or `0` when every slot is in
/// use — reported rather than trapped, like every other ceiling here.
export fn gero_vm_create() u32 {
    if (!session.ready()) return 0;
    return vm.create();
}

/// End a session and free its slot. A handle held past this is
/// refused rather than addressing whoever takes the slot next.
export fn gero_vm_destroy(handle: u32) u32 {
    return @intFromEnum(vm.destroy(handle));
}

/// Parse a `.gx` and boot it into the session.
///
/// A file that will not load reports **why** in the words `gero run`
/// uses, not a bare status — the same shared messages a terminal
/// shows (#415).
export fn gero_vm_load(handle: u32, gx_ptr: u32, gx_len: u32) *const Result {
    if (session.begin()) |status| return session.fail(status);
    const image = session.slice(gx_ptr, gx_len) orelse return session.fail(.bad_argument);

    var message_buf: [gero.load_error.max_message_len]u8 = undefined;
    if (vm.load(handle, image, &message_buf)) |failure| {
        const copy = session.allocator().dupe(u8, failure.message) catch
            return session.fail(.out_of_memory);
        return session.failWith(failure.status, copy);
    }
    return session.finish(null, null, 0);
}

/// Re-boot the loaded image, discarding everything execution changed.
export fn gero_vm_reset(handle: u32) u32 {
    return @intFromEnum(vm.reset(handle));
}

/// Execute at most `budget` instructions. The payload is a
/// `StepOutcome`: four little-endian `u32`s — reason, ip, fault, and
/// instructions actually retired.
export fn gero_vm_step(handle: u32, budget: u32) *const Result {
    if (session.begin()) |status| return session.fail(status);
    const out = vm.step(handle, budget) orelse return session.fail(.bad_argument);
    const bytes = session.allocator().alloc(u8, vm.StepOutcome.encoded_size) catch
        return session.fail(.out_of_memory);
    @memcpy(bytes, std.mem.asBytes(&out));
    return session.finish(bytes, null, 0);
}

/// The register file: 15 little-endian `u16`s, in `Register` index
/// order.
export fn gero_vm_regs(handle: u32) *const Result {
    if (session.begin()) |status| return session.fail(status);
    const bytes = session.allocator().alloc(u8, vm.register_bytes) catch
        return session.fail(.out_of_memory);
    if (!vm.registers(handle, bytes[0..vm.register_bytes])) return session.fail(.bad_argument);
    return session.finish(bytes, null, 0);
}

/// Read `len` bytes from `addr` through the memory mapper, so a banked
/// address returns what the running program sees.
export fn gero_vm_peek(handle: u32, addr: u32, len: u32) *const Result {
    if (session.begin()) |status| return session.fail(status);
    const bytes = session.allocator().alloc(u8, len) catch return session.fail(.out_of_memory);
    // safety: the ISA's address space is 16-bit.
    if (!vm.peek(handle, @truncate(addr), bytes)) return session.fail(.bad_argument);
    return session.finish(bytes, null, 0);
}

/// Write bytes at `addr` through the mapper.
export fn gero_vm_poke(handle: u32, addr: u32, src_ptr: u32, src_len: u32) u32 {
    const bytes = session.slice(src_ptr, src_len) orelse return @intFromEnum(Status.bad_argument);
    // safety: the ISA's address space is 16-bit.
    if (!vm.poke(handle, @truncate(addr), bytes)) return @intFromEnum(Status.bad_argument);
    return @intFromEnum(Status.ok);
}

/// Set one register by index.
export fn gero_vm_set_reg(handle: u32, index: u32, value: u32) u32 {
    if (index > 0xFF) return @intFromEnum(Status.bad_argument);
    // safety: both bounded by the checks above and the 16-bit file.
    return @intFromEnum(vm.setRegister(handle, @truncate(index), @truncate(value)));
}

/// Inject a maskable interrupt, honouring `flg.I` and `im` exactly as
/// the VM does.
export fn gero_vm_raise_irq(handle: u32, vector: u32) u32 {
    if (vector > 0xFF) return @intFromEnum(Status.bad_argument);
    // safety: bounded by the check above.
    return @intFromEnum(vm.raiseIrq(handle, @truncate(vector)));
}

/// Drain the print buffer. The payload is what the program printed;
/// `diagnostics_len` carries how many bytes were **dropped** because
/// it outran the buffer, so a flood is visible rather than silent.
export fn gero_vm_take_output(handle: u32) *const Result {
    if (session.begin()) |status| return session.fail(status);
    const out = vm.takeOutput(handle) orelse return session.fail(.bad_argument);
    const copy = session.allocator().dupe(u8, out.text) catch return session.fail(.out_of_memory);
    vm.clearOutput(handle);
    return session.finishWithDropped(copy, out.dropped);
}

/// The battery-backed banks, for persistence (§7). Empty when the
/// program declares none.
export fn gero_vm_sram(handle: u32) *const Result {
    if (session.begin()) |status| return session.fail(status);
    const bytes = vm.sram(handle) orelse return session.fail(.bad_argument);
    const copy = session.allocator().dupe(u8, bytes) catch return session.fail(.out_of_memory);
    return session.finish(copy, null, 0);
}

/// Restore battery-backed banks saved by an earlier session.
export fn gero_vm_load_sram(handle: u32, src_ptr: u32, src_len: u32) u32 {
    const bytes = session.slice(src_ptr, src_len) orelse return @intFromEnum(Status.bad_argument);
    return @intFromEnum(vm.loadSram(handle, bytes));
}
