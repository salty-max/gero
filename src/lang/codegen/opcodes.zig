/// VM opcode + register + syscall byte values used by the
/// codegen. Mirrored from `src/vm/opcodes.zig`,
/// `src/vm/registers.zig`, and `src/vm/handlers/system.zig`. The
/// codegen deliberately doesn't `@import` the VM module — the two
/// sides stay decoupled — so adding an opcode in the VM means
/// adding the matching constant here.
/// VM opcode byte values. Each constant is the leading byte of
/// the matching instruction; subsequent bytes carry operands per
/// ISA §5.
pub const Op = struct {
    /// `mov imm16, reg` — load 16-bit immediate into reg.
    pub const mov_imm16_reg: u8 = 0x10;
    /// `mov src, dst` — copy register.
    pub const mov_reg_reg: u8 = 0x11;
    /// load: reg ← [base + ofs] (word).
    pub const mov_reg_offset_reg: u8 = 0x1C;
    /// store: [base + ofs] ← reg (word).
    pub const mov_reg_reg_offset: u8 = 0x1D;
    /// store: [addr] ← reg (word).
    pub const mov_reg_to_addr: u8 = 0x12;
    /// load: reg ← [addr] (word).
    pub const mov_addr_to_reg: u8 = 0x13;
    /// store: [zp] ← reg (word).
    pub const mov_reg_to_zp: u8 = 0x19;
    /// load: reg ← [zp] (word).
    pub const mov_zp_to_reg: u8 = 0x1A;
    /// load: reg ← [ptr_reg] (word).
    pub const mov_ptr_to_reg: u8 = 0x15;
    /// store: [ptr_reg] ← reg (word).
    pub const mov_reg_to_ptr: u8 = 0x16;
    /// load: reg ← byte [addr].
    pub const mov8_addr_to_reg: u8 = 0x22;
    /// store: [ptr_reg] ← reg.lo (byte).
    pub const mov8_reg_to_ptr: u8 = 0x23;
    /// load: reg ← byte [ptr_reg].
    pub const mov8_ptr_to_reg: u8 = 0x24;
    /// load: reg ← byte [zp].
    pub const mov8_zp_to_reg: u8 = 0x29;
    /// store: [addr] ← reg.lo (byte store).
    pub const movl_reg_to_addr: u8 = 0x27;
    /// store: [zp] ← reg.lo (byte store).
    pub const movl_reg_to_zp: u8 = 0x2B;

    /// `push reg` — push register onto the stack.
    pub const push_reg: u8 = 0x31;
    /// `pop reg` — pop top of stack into register.
    pub const pop_reg: u8 = 0x32;

    /// `add imm, reg` — reg ← reg + imm.
    pub const add_imm16_reg: u8 = 0x40;
    /// `add reg, acu` — acu ← acu + reg.
    pub const add_reg_acu: u8 = 0x42;
    /// `sub imm, reg` — reg ← reg - imm.
    pub const sub_imm16_reg: u8 = 0x43;
    /// `sub reg, acu` — acu ← acu - reg.
    pub const sub_reg_acu: u8 = 0x45;
    /// `mul dst, src` — dst ← dst * src.
    pub const mul_reg_reg: u8 = 0x47;
    /// `neg reg` — reg ← -reg.
    pub const neg_reg: u8 = 0x4A;
    /// `divs dst, src` — dst ← dst / src (signed).
    pub const divs_reg_reg: u8 = 0x4E;

    /// `and dst, src` — dst ← dst & src.
    pub const and_reg_reg: u8 = 0x61;
    /// `or dst, src` — dst ← dst | src.
    pub const or_reg_reg: u8 = 0x63;
    /// `xor dst, src` — dst ← dst ^ src.
    pub const xor_reg_reg: u8 = 0x65;
    /// `not reg` — reg ← ~reg.
    pub const not_reg: u8 = 0x66;
    /// `shl dst, src` — dst ← dst << src.
    pub const shl_reg_reg: u8 = 0x71;
    /// `shr dst, src` — dst ← dst >> src (logical).
    pub const shr_reg_reg: u8 = 0x73;

    /// `shl reg, imm` — reg ← reg << imm.
    pub const shl_reg_imm8: u8 = 0x70;
    /// `shr reg, imm` — reg ← reg >> imm (logical / unsigned).
    pub const shr_reg_imm8: u8 = 0x72;
    /// `asr reg, imm` — reg ← reg >>a imm (arithmetic / signed).
    pub const asr_reg_imm8: u8 = 0x74;

    /// `cmp reg, imm` — flags ← reg - imm.
    pub const cmp_reg_imm16: u8 = 0x80;
    /// `cmp dst, src` — flags ← dst - src.
    pub const cmp_reg_reg: u8 = 0x81;

    /// `jmp addr` — unconditional jump.
    pub const jmp_addr: u8 = 0x90;
    /// `jeq addr` — jump on Z = 1.
    pub const jeq_addr: u8 = 0x92;
    /// `jne addr` — jump on Z = 0.
    pub const jne_addr: u8 = 0x93;
    /// `jlt addr` — signed less-than.
    pub const jlt_addr: u8 = 0x94;
    /// `jle addr` — signed ≤.
    pub const jle_addr: u8 = 0x95;
    /// `jgt addr` — signed greater-than.
    pub const jgt_addr: u8 = 0x96;
    /// `jge addr` — signed ≥.
    pub const jge_addr: u8 = 0x97;

    /// `bcpy dst, src, len` — memcpy via 3 regs.
    pub const bcpy: u8 = 0x2C;
    /// `bfill addr, len, val` — memset via 3 regs.
    pub const bfill: u8 = 0x2D;

    /// `call addr` — call absolute address.
    pub const call_addr: u8 = 0xA0;
    /// `call [reg]` — call via register.
    pub const call_reg: u8 = 0xA1;
    /// `ret` — return from call.
    pub const ret_op: u8 = 0xA2;

    /// `sys id` — host-callback syscall.
    pub const sys: u8 = 0xFB;
    /// `hlt` — terminal halt.
    pub const hlt: u8 = 0xFF;
};

/// VM register byte values per `src/vm/registers.zig`. The
/// codegen reads / writes through these indices in operand
/// positions that expect a `Reg`.
pub const Reg = struct {
    /// Accumulator — return-value and host-syscall arg register.
    pub const acu: u8 = 0x01;
    /// General-purpose register 1.
    pub const r1: u8 = 0x02;
    /// General-purpose register 2.
    pub const r2: u8 = 0x03;
    /// General-purpose register 3.
    pub const r3: u8 = 0x04;
    /// Stack pointer.
    pub const sp: u8 = 0x0A;
    /// Frame pointer.
    pub const fp: u8 = 0x0B;
    /// Memory-bank selector — selects the active SRAM bank window.
    pub const mb: u8 = 0x0C;
};

/// `sys` syscall ids per `src/vm/handlers/system.zig::SyscallId`.
/// The `sys` opcode reads one of these as its immediate operand
/// and routes to the matching host-callback handler.
pub const Sys = struct {
    /// `print_str` — write a null-terminated string from `[acu]`.
    pub const print_str: u8 = 0x01;
    /// `print_int` — write `acu` as decimal.
    pub const print_int: u8 = 0x02;
    /// `print_char` — write `acu.lo` as a single byte.
    pub const print_char: u8 = 0x03;
    /// `print_newline` — write `\n`.
    pub const print_newline: u8 = 0x04;
    /// `print_fixed` — write `acu` as Q-format fixed-point.
    pub const print_fixed: u8 = 0x05;

    /// `format_str_to_buf` — append `[acu]` (null-terminated str)
    /// to the buffer pointed to by `r1`.
    pub const format_str_to_buf: u8 = 0x10;
    /// `format_int_to_buf` — append `acu` as decimal to the buffer
    /// pointed to by `r1`.
    pub const format_int_to_buf: u8 = 0x11;
    /// `format_char_to_buf` — append `acu.lo` as a single byte to
    /// the buffer pointed to by `r1`.
    pub const format_char_to_buf: u8 = 0x12;
    /// `format_fixed_to_buf` — append `acu` as Q-format fixed-
    /// point to the buffer pointed to by `r1`.
    pub const format_fixed_to_buf: u8 = 0x13;
    /// `format_terminate_buf` — write a trailing null byte at the
    /// current cursor of the buffer pointed to by `r1`.
    pub const format_terminate_buf: u8 = 0x14;
};
