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
    /// Arithmetic overflow (e.g. `div` quotient > 16 bits).
    arith_overflow = 0x05,
    _,
};

/// Outcome of a `step` call.
pub const StepResult = enum {
    /// The VM advanced — keep dispatching.
    cont,
    /// The VM hit `hlt` (no resume).
    halted,
    /// A fault fired but no ISR was installed (vector slot is `0`).
    /// The host should surface the fault to the user.
    halted_on_fault,
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

    // mov family
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

    // mov8 / movh / movl
    t[0x20] = mov.mov8Imm8Addr;
    t[0x21] = mov.mov8Imm8Reg;
    t[0x22] = mov.mov8AddrReg;
    t[0x23] = mov.mov8RegPtr;
    t[0x24] = mov.mov8PtrReg;
    t[0x25] = mov.movhRegAddr;
    t[0x26] = mov.movlRegAddr;

    // stack
    t[0x30] = stack_handlers.pushImm16;
    t[0x31] = stack_handlers.pushReg;
    t[0x32] = stack_handlers.popReg;

    // arithmetic
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
    t[0x64] = arith.adcImm16Reg;
    t[0x65] = arith.adcRegReg;
    t[0x66] = arith.sbcImm16Reg;
    t[0x67] = arith.sbcRegReg;

    // logical
    t[0x50] = bitwise.andRegImm16;
    t[0x51] = bitwise.andRegReg;
    t[0x52] = bitwise.orRegImm16;
    t[0x53] = bitwise.orRegReg;
    t[0x54] = bitwise.xorRegImm16;
    t[0x55] = bitwise.xorRegReg;
    t[0x56] = bitwise.notReg;

    // shifts and rotates
    t[0x58] = bitwise.shlRegImm8;
    t[0x59] = bitwise.shlRegReg;
    t[0x5A] = bitwise.shrRegImm8;
    t[0x5B] = bitwise.shrRegReg;
    t[0x5C] = bitwise.rolRegImm8;
    t[0x5D] = bitwise.rolRegReg;
    t[0x5E] = bitwise.rorRegImm8;
    t[0x5F] = bitwise.rorRegReg;

    // cmp / tst
    t[0x60] = cmp_handlers.cmpRegImm16;
    t[0x61] = cmp_handlers.cmpRegReg;
    t[0x62] = cmp_handlers.tstRegImm16;
    t[0x63] = cmp_handlers.tstRegReg;

    break :blk t;
};

/// One fetch-decode-execute cycle. Reads the byte at `ip`,
/// invokes its handler, and (if the handler returned `.cont`
/// without moving `ip`) advances past the instruction by the
/// schema-derived size.
pub fn step(vm: *VM) StepResult {
    const ip_before = vm.regs.read(.ip);
    const op = vm.mmap.readByte(ip_before);
    const handler = handler_table[op];
    const result = handler(vm);
    if (result == .cont and vm.regs.read(.ip) == ip_before) {
        const info = opcodes.table[op] orelse return .halted_on_fault;
        vm.regs.write(.ip, ip_before +% info.size());
    }
    return result;
}

/// Iterate `step` until it returns anything other than `.cont`.
/// Returns the final outcome (`.halted` or `.halted_on_fault`).
pub fn run(vm: *VM) StepResult {
    while (true) {
        const r = step(vm);
        if (r != .cont) return r;
    }
}

/// Deliver a fault through the interrupt mechanism. If the
/// vector slot is `0` the VM halts with a host-visible fault
/// marker; otherwise the entry sequence pushes `ip` / `fp` /
/// `flg`, sets `flg.I`, and jumps to the ISR.
pub fn raiseFault(vm: *VM, vector: Vector) StepResult {
    const target = vm.mmap.readWord(ivtSlot(vector));
    if (target == 0) return .halted_on_fault;

    pushWord(vm, vm.regs.read(.ip));
    pushWord(vm, vm.regs.read(.fp));
    pushWord(vm, vm.regs.read(.flg));
    vm.regs.setFlag(.interrupt_disable, true);
    vm.regs.write(.ip, target);
    return .cont;
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
    vm.mmap.writeWord(new_sp, value);
}

/// Pop a 16-bit word from the stack. Post-increment:
/// `value = mem[sp]; sp += 2`. Overflow wraps silently.
pub fn popWord(vm: *VM) u16 {
    const sp = vm.regs.read(.sp);
    const value = vm.mmap.readWord(sp);
    vm.regs.write(.sp, sp +% 2);
    return value;
}
