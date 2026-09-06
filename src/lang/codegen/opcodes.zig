/// VM opcode byte values. Each constant is the leading byte;
/// subsequent bytes carry operands per ISA §5.
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

    /// `push imm16` — push a 16-bit immediate onto the stack.
    pub const push_imm16: u8 = 0x30;
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
    /// `mul dst, src` — dst ← dst * src (32-bit unsigned product;
    /// high half lands in acu, sets V/C when `high != 0`).
    pub const mul_reg_reg: u8 = 0x47;
    /// `add src, dst` — dst ← dst + src (ISA §5.4).
    pub const add_reg_reg: u8 = 0x41;
    /// `sub src, dst` — dst ← dst - src.
    pub const sub_reg_reg: u8 = 0x44;
    /// `adc imm16, reg` — reg ← reg + imm + C.
    pub const adc_imm16_reg: u8 = 0x50;
    /// `adc src, dst` — dst ← dst + src + C. The high half of a
    /// multi-word add (ISA §5.4.1).
    pub const adc_reg_reg: u8 = 0x51;
    /// `sbc src, dst` — dst ← dst - src - C. The high half of a
    /// multi-word subtract.
    pub const sbc_reg_reg: u8 = 0x53;
    /// `neg reg` — reg ← -reg.
    pub const neg_reg: u8 = 0x4A;
    /// `divs dst, src` — dst ← dst / src (signed).
    pub const divs_reg_reg: u8 = 0x4E;
    /// `muls dst, src` — dst ← dst * src (32-bit signed product;
    /// V/C set when the signed result doesn't fit in `i16`). Used
    /// by the debug overflow trap on signed `*`.
    pub const muls_reg_reg: u8 = 0x55;

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
    /// `jmp reg` — indirect jump via register (`ip ← reg`). Used by
    /// the match-stmt jump-table dispatch.
    pub const jmp_reg: u8 = 0x91;
    /// `jeq addr` — jump on Z = 1.
    pub const jeq_addr: u8 = 0x92;
    /// `jne addr` — jump on Z = 0.
    pub const jne_addr: u8 = 0x93;
    /// `jcs addr` — jump on C = 1 (a borrow occurred on the last `sub`).
    pub const jcs_addr: u8 = 0x99;
    /// `clc` — clear carry, so a following `rol` shifts a zero in.
    pub const clc_op: u8 = 0xB0;
    /// `rol reg, imm8` — rotate left through carry.
    pub const rol_reg_imm: u8 = 0x76;
    /// `jlt addr` — signed less-than.
    pub const jlt_addr: u8 = 0x94;
    /// `jle addr` — signed ≤.
    pub const jle_addr: u8 = 0x95;
    /// `jgt addr` — signed greater-than.
    pub const jgt_addr: u8 = 0x96;
    /// `jge addr` — signed ≥.
    pub const jge_addr: u8 = 0x97;
    /// `jcc addr` — jump on `C = 0` (no unsigned overflow / no borrow).
    /// Used by the debug overflow trap on unsigned `+` / `-` to
    /// skip past the trap when no carry / borrow occurred.
    pub const jcc_addr: u8 = 0x98;
    /// `jvc addr` — jump on `V = 0` (no signed overflow). Used by
    /// the debug overflow trap on signed `+` / `-` / `*` to skip
    /// past the trap when no signed overflow occurred.
    pub const jvc_addr: u8 = 0x9A;

    /// `bcpy dst, src, len` — memcpy via 3 regs.
    pub const bcpy: u8 = 0x2C;
    /// `bfill addr, len, val` — memset via 3 regs.
    pub const bfill: u8 = 0x2D;

    /// `mov imm16, addr` — `mem[addr] ← imm`. Used to wire IVT
    /// slots from `@interrupt N` handlers at boot.
    pub const mov_imm16_addr: u8 = 0x14;

    /// `call addr` — call absolute address.
    pub const call_addr: u8 = 0xA0;
    /// `call [reg]` — call via register.
    pub const call_reg: u8 = 0xA1;
    /// `ret` — return from call.
    pub const ret_op: u8 = 0xA2;
    /// `sei` — set interrupt-disable (`flg.I ← 1`, block IRQs). The
    /// matching clear is done by restoring a saved `flg`, not `cli`,
    /// so the prior interrupt-enable state is preserved.
    pub const sei_op: u8 = 0xB3;
    /// `rti` — return from interrupt (pop flg/fp/ip).
    pub const rti_op: u8 = 0xFD;

    /// `sys id` — host-callback syscall.
    pub const sys: u8 = 0xFB;
    /// `int imm8` — software interrupt via vector table.
    pub const int_imm8: u8 = 0xFC;
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
    /// General-purpose register 4.
    pub const r4: u8 = 0x05;
    /// General-purpose register 5.
    pub const r5: u8 = 0x06;
    /// General-purpose register 6.
    pub const r6: u8 = 0x07;
    /// Stack pointer.
    pub const sp: u8 = 0x0A;
    /// Frame pointer.
    pub const fp: u8 = 0x0B;
    /// Memory-bank selector — selects the active SRAM bank window.
    pub const mb: u8 = 0x0C;
    /// Status flags (Z/N/C/V/I). Read/written as a whole register to
    /// save + restore the interrupt-disable bit across a critical section.
    pub const flg: u8 = 0x0E;
};

/// `sys` syscall ids per `src/vm/handlers/system.zig::SyscallId`.
/// The `sys` opcode reads one of these as its immediate operand
/// and routes to the matching host-callback handler.
pub const Sys = struct {
    /// `print_str` — write a null-terminated string from `[acu]`.
    pub const print_str: u8 = 0x01;
    /// `print_int` — write `acu` as signed decimal.
    pub const print_int: u8 = 0x02;
    /// `print_char` — write `acu.lo` as a single byte.
    pub const print_char: u8 = 0x03;
    /// `print_newline` — write `\n`.
    pub const print_newline: u8 = 0x04;
    /// `print_fixed` — write `acu` as Q-format fixed-point.
    pub const print_fixed: u8 = 0x05;
    /// `print_uint` — write `acu` as unsigned decimal.
    pub const print_uint: u8 = 0x06;

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
    /// `format_uint_to_buf` — append `acu` as unsigned decimal to the
    /// buffer pointed to by `r1`.
    pub const format_uint_to_buf: u8 = 0x15;
    /// `format_spec_to_buf` — append `acu` formatted per a §3.2.2 format
    /// spec to the buffer at `r1`. `r2` = width (bits 0-7) | fill char
    /// (bits 8-15); `r3` = type / align / flags / precision. For the `str`
    /// type `acu` is the byte pointer; otherwise the value. The full bit
    /// layout is the contract in `docs/isa.md`.
    pub const format_spec_to_buf: u8 = 0x16;

    /// `format_runtime` — `str.format(fmt, args)` (§3.2.2). `acu` = the
    /// (non-literal) format string; `r1` = dst cursor; `r2` = base of the
    /// `args` words; `r3` = count (bits 0-7) | element default type (bits
    /// 8-10, the `format_spec_to_buf` type codes) | element-signed (bit 11).
    /// Parses `{N}` / `{N:spec}` positional placeholders and `{{` / `}}`,
    /// and formats `args[N]` per the spec at `[r1]`, advancing `r1`.
    pub const format_runtime: u8 = 0x17;

    /// `format_spec_to_buf` `r3` flag bits + field shifts (§3.2.2). The VM
    /// unpacker mirrors these; the type field (bits 0-2) uses the numeric
    /// codes documented in `docs/isa.md`.
    pub const FmtSpec = struct {
        /// `r3` bit position of the alignment field (bits 3-4).
        pub const align_shift: u4 = 3;
        /// `r3` flag — signed value (decimal sign handling).
        pub const flag_signed: u16 = 1 << 5;
        /// `r3` flag — zero-pad numeric output to the width.
        pub const flag_zero_pad: u16 = 1 << 6;
        /// `r3` flag — a precision is present (bits 8-15).
        pub const flag_has_precision: u16 = 1 << 7;
        /// `r3` bit position of the precision field (bits 8-15).
        pub const precision_shift: u4 = 8;
        /// `r2` bit position of the fill char (width is bits 0-7).
        pub const fill_shift: u4 = 8;
    };

    /// `alloc` — bump-allocate `acu` bytes on the heap. Returns
    /// the freshly-allocated address in `acu`; faults
    /// `heap_exhausted` (vector `0x04`) on out-of-heap.
    pub const alloc: u8 = 0x20;

    /// `trap` — raise the `trap` fault (ISA vector `$06`). Emitted
    /// after a diverging builtin or a failed `test.assert_*` prints,
    /// so the halt is distinguishable from a clean `hlt`.
    pub const trap: u8 = 0x30;
};
