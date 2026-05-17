/// The fetch-decode-execute loop. Reads the byte at `ip`, dispatches
/// to the right handler in `handler_table`, and auto-advances `ip`
/// past the instruction unless the handler set `ip` itself
/// (jumps / calls / fault entry).
const std = @import("std");
const vm_mod = @import("vm.zig");
const opcodes = @import("opcodes.zig");
const mov = @import("handlers/mov.zig");
const stack_handlers = @import("handlers/stack.zig");
const arith = @import("handlers/arith.zig");
const bitwise = @import("handlers/bitwise.zig");
const cmp_handlers = @import("handlers/cmp.zig");
const jumps = @import("handlers/jumps.zig");
const subroutine = @import("handlers/subroutine.zig");
const system_handlers = @import("handlers/system.zig");
const VM = vm_mod.VM;
const Register = vm_mod.Register;
const Flag = vm_mod.Flag;

/// Base address of the interrupt vector table.
pub const ivt_base: u16 = 0x1000;

/// Interrupt / fault vector. Non-exhaustive: the reserved vectors
/// get named tags, but any `u8` in `0..0x3F` is a valid vector
/// index — the `int N` opcode can raise host-defined or
/// software-int vectors that aren't named.
pub const Vector = enum(u8) {
    /// Reset — runs at boot when the program's entry point is 0.
    reset = 0x00,
    /// Invalid-opcode fault.
    invalid_opcode = 0x01,
    /// Invalid-register fault.
    invalid_register = 0x02,
    /// Division by zero.
    div_by_zero = 0x03,
    /// Heap exhausted — `sys alloc` couldn't satisfy a request
    /// because the bump cursor would have collided with the stack
    /// or fallen outside the program's heap region.
    heap_exhausted = 0x04,
    /// Arithmetic overflow (e.g. `div` quotient > 16 bits).
    arith_overflow = 0x05,
    _,
};

/// Outcome of a `step` call.
pub const StepResult = enum {
    /// The handler completed normally; `step` auto-advances `ip`
    /// past the instruction.
    cont,
    /// The handler set `ip` itself (jump, call, fault entry).
    /// `step` leaves `ip` alone — the run loop keeps going.
    branched,
    /// The VM hit `hlt` (no resume).
    halted,
    /// A fault fired but no ISR was installed (vector slot is `0`).
    /// The host should surface the fault to the user.
    halted_on_fault,
    /// The VM hit `brk`. `ip` is already advanced past the
    /// breakpoint; calling `run` again resumes from there.
    breakpoint,
};

/// Per-opcode handler. Receives the VM and returns the post-step
/// outcome. A handler that returns `.cont` without touching `ip`
/// leaves the auto-advance work to `step`.
pub const Handler = *const fn (vm: *VM) StepResult;

/// Default handler for bytes with no implementation — raises the
/// invalid-opcode fault.
fn unimplemented(vm: *VM) StepResult {
    return raiseFault(vm, .invalid_opcode);
}

/// 256-slot handler table. Bytes without a real handler default
/// to `unimplemented`; subsequent opcode-family PRs install their
/// handlers by overwriting individual slots here.
pub const handler_table: [256]Handler = blk: {
    var t = [_]Handler{unimplemented} ** 256;

    // 0x1X — mov word
    t[0x10] = mov.movImm16Reg;
    t[0x11] = mov.movRegReg;
    t[0x12] = mov.movRegAddr;
    t[0x13] = mov.movAddrReg;
    t[0x14] = mov.movImm16Addr;
    t[0x15] = mov.movRegPtr;
    t[0x16] = mov.movPtrReg;
    t[0x17] = mov.movIndexed;
    t[0x18] = mov.movImm16Ptr;
    t[0x19] = mov.movRegZp;
    t[0x1A] = mov.movZpReg;
    t[0x1B] = mov.movImm16Zp;
    t[0x1C] = mov.movRegOffsetReg;
    t[0x1D] = mov.movRegRegOffset;

    // 0x2X — mov byte (mov8 / movh / movl + block memory)
    t[0x20] = mov.mov8Imm8Addr;
    t[0x21] = mov.mov8Imm8Reg;
    t[0x22] = mov.mov8AddrReg;
    t[0x23] = mov.mov8RegPtr;
    t[0x24] = mov.mov8PtrReg;
    t[0x25] = mov.mov8Indexed;
    t[0x26] = mov.movhRegAddr;
    t[0x27] = mov.movlRegAddr;
    t[0x28] = mov.mov8Imm8Zp;
    t[0x29] = mov.mov8ZpReg;
    t[0x2A] = mov.movhRegZp;
    t[0x2B] = mov.movlRegZp;
    t[0x2C] = mov.bcpyRegRegReg;
    t[0x2D] = mov.bfillRegRegReg;

    // 0x3X — stack
    t[0x30] = stack_handlers.pushImm16;
    t[0x31] = stack_handlers.pushReg;
    t[0x32] = stack_handlers.popReg;

    // 0x4X — arithmetic primary
    t[0x40] = arith.addImm16Reg;
    t[0x41] = arith.addRegReg;
    t[0x42] = arith.addRegAcu;
    t[0x43] = arith.subImm16Reg;
    t[0x44] = arith.subRegReg;
    t[0x45] = arith.subRegAcu;
    t[0x46] = arith.mulImm16Reg;
    t[0x47] = arith.mulRegReg;
    t[0x48] = arith.incReg;
    t[0x49] = arith.decReg;
    t[0x4A] = arith.negReg;
    t[0x4B] = arith.divImm16Reg;
    t[0x4C] = arith.divRegReg;
    t[0x4D] = arith.divsImm16Reg;
    t[0x4E] = arith.divsRegReg;
    t[0x4F] = mov.sextReg;

    // 0x5X — arithmetic carry-propagating
    t[0x50] = arith.adcImm16Reg;
    t[0x51] = arith.adcRegReg;
    t[0x52] = arith.sbcImm16Reg;
    t[0x53] = arith.sbcRegReg;

    // 0x6X — bitwise (logical word ops + single-bit ops)
    t[0x60] = bitwise.andRegImm16;
    t[0x61] = bitwise.andRegReg;
    t[0x62] = bitwise.orRegImm16;
    t[0x63] = bitwise.orRegReg;
    t[0x64] = bitwise.xorRegImm16;
    t[0x65] = bitwise.xorRegReg;
    t[0x66] = bitwise.notReg;
    t[0x67] = cmp_handlers.btestRegImm8;
    t[0x68] = cmp_handlers.bsetRegImm8;
    t[0x69] = cmp_handlers.bclrRegImm8;

    // 0x7X — shifts / rotates
    t[0x70] = bitwise.shlRegImm8;
    t[0x71] = bitwise.shlRegReg;
    t[0x72] = bitwise.shrRegImm8;
    t[0x73] = bitwise.shrRegReg;
    t[0x74] = bitwise.asrRegImm8;
    t[0x75] = bitwise.asrRegReg;
    t[0x76] = bitwise.rolRegImm8;
    t[0x77] = bitwise.rolRegReg;
    t[0x78] = bitwise.rorRegImm8;
    t[0x79] = bitwise.rorRegReg;

    // 0x8X — comparison
    t[0x80] = cmp_handlers.cmpRegImm16;
    t[0x81] = cmp_handlers.cmpRegReg;
    t[0x82] = cmp_handlers.tstRegImm16;
    t[0x83] = cmp_handlers.tstRegReg;

    // 0x9X — branches
    t[0x90] = jumps.jmpAddr;
    t[0x91] = jumps.jmpReg;
    t[0x92] = jumps.jeqAddr;
    t[0x93] = jumps.jneAddr;
    t[0x94] = jumps.jltAddr;
    t[0x95] = jumps.jleAddr;
    t[0x96] = jumps.jgtAddr;
    t[0x97] = jumps.jgeAddr;
    t[0x98] = jumps.jccAddr;
    t[0x99] = jumps.jcsAddr;
    t[0x9A] = jumps.jvcAddr;
    t[0x9B] = jumps.jvsAddr;
    t[0x9C] = jumps.jzAddr;
    t[0x9D] = jumps.jnzAddr;
    t[0x9E] = jumps.djnzRegAddr;
    t[0x9F] = jumps.jrImm8;

    // 0xAX — subroutines
    t[0xA0] = subroutine.callAddr;
    t[0xA1] = subroutine.callReg;
    t[0xA2] = subroutine.ret;

    // 0xBX — flag manipulation
    t[0xB0] = system_handlers.clc;
    t[0xB1] = system_handlers.sec;
    t[0xB2] = system_handlers.cli;
    t[0xB3] = system_handlers.sei;
    t[0xB4] = system_handlers.clv;

    // 0xCX — misc
    t[0xC0] = system_handlers.swap;
    t[0xC1] = system_handlers.nop;

    // 0xFX — system
    t[0xFB] = system_handlers.sys;
    t[0xFC] = system_handlers.intImm8;
    t[0xFD] = system_handlers.rti;
    t[0xFE] = system_handlers.brk;
    t[0xFF] = system_handlers.hlt;

    break :blk t;
};

/// One fetch-decode-execute cycle. Reads the byte at `ip`,
/// invokes its handler, and (if the handler returned `.cont`
/// without moving `ip`) advances past the instruction by the
/// schema-derived size.
pub fn step(vm: *VM) StepResult {
    vm.cycles +%= 1;
    const ip_before = vm.regs.read(.ip);
    const op = vm.readByte(ip_before);
    const handler = handler_table[op];
    const result = handler(vm);
    if (result == .cont or result == .breakpoint) {
        const info = opcodes.table[op] orelse return .halted_on_fault;
        vm.regs.write(.ip, ip_before +% info.size());
    }
    return result;
}

/// Iterate `step` until the VM signals a terminal state. `.cont`
/// and `.branched` both keep the loop going; `.breakpoint`,
/// `.halted`, and `.halted_on_fault` exit so the host can
/// inspect / decide whether to resume.
pub fn run(vm: *VM) StepResult {
    while (true) {
        const r = step(vm);
        if (r == .cont or r == .branched) continue;
        return r;
    }
}

/// Deliver a fault through the interrupt mechanism. Faults
/// (and software `int N`) bypass `flg.I` and `im` — they always
/// fire, so a buggy program can't silently drop a div-by-zero.
/// If the vector slot is `0` the VM halts with a host-visible
/// fault marker; otherwise the entry sequence pushes `ip` /
/// `fp` / `flg`, sets `flg.I`, and jumps to the ISR.
pub fn raiseFault(vm: *VM, vector: Vector) StepResult {
    const target = vm.readWord(ivtSlot(vector));
    if (target == 0) return .halted_on_fault;

    pushWord(vm, vm.regs.read(.ip));
    pushWord(vm, vm.regs.read(.fp));
    pushWord(vm, vm.regs.read(.flg));
    vm.regs.setFlag(.interrupt_disable, true);
    vm.regs.write(.ip, target);
    return .branched;
}

/// Deliver a hardware-style IRQ. Honors the maskable layer
/// (`flg.I` globally + `im` for vectors `0..0x0F`); host /
/// device code calls this to signal an interrupt. Returns
/// `null` when the IRQ is blocked by masking, otherwise the
/// outcome of the entry sequence (same as `raiseFault`).
pub fn raiseIrq(vm: *VM, vector: Vector) ?StepResult {
    if (vm.regs.flagSet(.interrupt_disable)) return null;
    const v = @intFromEnum(vector);
    if (v < 0x10) {
        const mask = vm.regs.read(.im);
        if ((mask >> @intCast(v)) & 1 == 0) return null;
    }
    return raiseFault(vm, vector);
}

/// Address of the slot for `vector` inside the IVT.
pub fn ivtSlot(vector: Vector) u16 {
    // @as: widen the u8 vector index to u16 before the multiply
    return ivt_base + 2 * @as(u16, @intFromEnum(vector));
}

/// Push a 16-bit word onto the stack. Pre-decrement:
/// `sp -= 2; mem[sp] = value`. Underflow wraps silently — no
/// fault, the program is responsible.
pub fn pushWord(vm: *VM, value: u16) void {
    const new_sp = vm.regs.read(.sp) -% 2;
    vm.regs.write(.sp, new_sp);
    vm.writeWord(new_sp, value);
}

/// Pop a 16-bit word from the stack. Post-increment:
/// `value = mem[sp]; sp += 2`. Overflow wraps silently.
pub fn popWord(vm: *VM) u16 {
    const sp = vm.regs.read(.sp);
    const value = vm.readWord(sp);
    vm.regs.write(.sp, sp +% 2);
    return value;
}
