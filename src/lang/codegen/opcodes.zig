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
    // allow-strict: byte-table mirror of VM opcodes — trailing-comment commentary is the canonical doc.
    pub const mov_imm16_reg: u8 = 0x10; // mov imm16, reg
    // allow-strict: byte-table mirror.
    pub const mov_reg_reg: u8 = 0x11; // mov src, dst
    // allow-strict: byte-table mirror.
    pub const mov_reg_offset_reg: u8 = 0x1C; // load:  reg ← [base + ofs]
    // allow-strict: byte-table mirror.
    pub const mov_reg_reg_offset: u8 = 0x1D; // store: [base + ofs] ← reg
    // allow-strict: byte-table mirror.
    pub const mov_reg_to_addr: u8 = 0x12; // store: [addr] ← reg (word)
    // allow-strict: byte-table mirror.
    pub const mov_addr_to_reg: u8 = 0x13; // load:  reg ← [addr] (word)
    // allow-strict: byte-table mirror.
    pub const mov_reg_to_zp: u8 = 0x19; // store: [zp] ← reg (word)
    // allow-strict: byte-table mirror.
    pub const mov_zp_to_reg: u8 = 0x1A; // load:  reg ← [zp] (word)
    // allow-strict: byte-table mirror.
    pub const mov_ptr_to_reg: u8 = 0x15; // load:  reg ← [ptr_reg] (word)
    // allow-strict: byte-table mirror.
    pub const mov_reg_to_ptr: u8 = 0x16; // store: [ptr_reg] ← reg (word)
    // allow-strict: byte-table mirror.
    pub const mov8_addr_to_reg: u8 = 0x22; // load:  reg ← byte [addr]
    // allow-strict: byte-table mirror.
    pub const mov8_reg_to_ptr: u8 = 0x23; // store: [ptr_reg] ← reg.lo (byte)
    // allow-strict: byte-table mirror.
    pub const mov8_ptr_to_reg: u8 = 0x24; // load:  reg ← byte [ptr_reg]
    // allow-strict: byte-table mirror.
    pub const mov8_zp_to_reg: u8 = 0x29; // load:  reg ← byte [zp]
    // allow-strict: byte-table mirror.
    pub const movl_reg_to_addr: u8 = 0x27; // store: [addr] ← reg.lo  (byte store)
    // allow-strict: byte-table mirror.
    pub const movl_reg_to_zp: u8 = 0x2B; // store: [zp]   ← reg.lo  (byte store)

    // allow-strict: byte-table mirror.
    pub const push_reg: u8 = 0x31; // push reg
    // allow-strict: byte-table mirror.
    pub const pop_reg: u8 = 0x32; // pop reg

    // allow-strict: byte-table mirror.
    pub const add_imm16_reg: u8 = 0x40; // add imm, reg
    // allow-strict: byte-table mirror.
    pub const add_reg_acu: u8 = 0x42; // acu ← acu + reg
    // allow-strict: byte-table mirror.
    pub const sub_imm16_reg: u8 = 0x43; // sub imm, reg
    // allow-strict: byte-table mirror.
    pub const sub_reg_acu: u8 = 0x45; // acu ← acu - reg
    // allow-strict: byte-table mirror.
    pub const mul_reg_reg: u8 = 0x47; // dst ← dst * src
    // allow-strict: byte-table mirror.
    pub const neg_reg: u8 = 0x4A; // reg ← -reg
    // allow-strict: byte-table mirror.
    pub const divs_reg_reg: u8 = 0x4E; // dst ← dst / src (signed)

    // allow-strict: byte-table mirror.
    pub const and_reg_reg: u8 = 0x61; // dst ← dst & src
    // allow-strict: byte-table mirror.
    pub const or_reg_reg: u8 = 0x63; // dst ← dst | src
    // allow-strict: byte-table mirror.
    pub const xor_reg_reg: u8 = 0x65; // dst ← dst ^ src
    // allow-strict: byte-table mirror.
    pub const not_reg: u8 = 0x66; // reg ← ~reg
    // allow-strict: byte-table mirror.
    pub const shl_reg_reg: u8 = 0x71; // dst ← dst << src
    // allow-strict: byte-table mirror.
    pub const shr_reg_reg: u8 = 0x73; // dst ← dst >> src

    // allow-strict: byte-table mirror.
    pub const shl_reg_imm8: u8 = 0x70; // reg ← reg << imm
    // allow-strict: byte-table mirror.
    pub const shr_reg_imm8: u8 = 0x72; // reg ← reg >> imm (logical / unsigned)
    // allow-strict: byte-table mirror.
    pub const asr_reg_imm8: u8 = 0x74; // reg ← reg >>a imm (arithmetic / signed)

    // allow-strict: byte-table mirror.
    pub const cmp_reg_imm16: u8 = 0x80; // flags ← reg - imm
    // allow-strict: byte-table mirror.
    pub const cmp_reg_reg: u8 = 0x81; // flags ← dst - src

    // allow-strict: byte-table mirror.
    pub const jmp_addr: u8 = 0x90; // unconditional jump
    // allow-strict: byte-table mirror.
    pub const jeq_addr: u8 = 0x92; // jump on Z = 1
    // allow-strict: byte-table mirror.
    pub const jne_addr: u8 = 0x93; // jump on Z = 0
    // allow-strict: byte-table mirror.
    pub const jlt_addr: u8 = 0x94; // signed less
    // allow-strict: byte-table mirror.
    pub const jle_addr: u8 = 0x95; // signed ≤
    // allow-strict: byte-table mirror.
    pub const jgt_addr: u8 = 0x96; // signed >
    // allow-strict: byte-table mirror.
    pub const jge_addr: u8 = 0x97; // signed ≥

    // allow-strict: byte-table mirror.
    pub const bcpy: u8 = 0x2C; // bcpy dst, src, len — memcpy via 3 regs
    // allow-strict: byte-table mirror.
    pub const bfill: u8 = 0x2D; // bfill addr, len, val — memset via 3 regs

    // allow-strict: byte-table mirror.
    pub const call_addr: u8 = 0xA0; // call abs addr
    // allow-strict: byte-table mirror.
    pub const call_reg: u8 = 0xA1; // call [reg]
    // allow-strict: byte-table mirror.
    pub const ret_op: u8 = 0xA2; // ret

    // allow-strict: byte-table mirror.
    pub const sys: u8 = 0xFB; // host-callback syscall
    // allow-strict: byte-table mirror.
    pub const hlt: u8 = 0xFF; // terminal halt
};

/// VM register byte values per `src/vm/registers.zig`. The
/// codegen reads / writes through these indices in operand
/// positions that expect a `Reg`.
pub const Reg = struct {
    // allow-strict: register-index mirror.
    pub const acu: u8 = 0x01;
    // allow-strict: register-index mirror.
    pub const r1: u8 = 0x02;
    // allow-strict: register-index mirror.
    pub const r2: u8 = 0x03;
    // allow-strict: register-index mirror.
    pub const r3: u8 = 0x04;
    // allow-strict: register-index mirror.
    pub const sp: u8 = 0x0A;
    // allow-strict: register-index mirror.
    pub const fp: u8 = 0x0B;
    // allow-strict: register-index mirror.
    pub const mb: u8 = 0x0C;
};

/// `sys` syscall ids per `src/vm/handlers/system.zig::SyscallId`.
/// The `sys` opcode reads one of these as its immediate operand
/// and routes to the matching host-callback handler.
pub const Sys = struct {
    // allow-strict: syscall-id mirror.
    pub const print_str: u8 = 0x01;
    // allow-strict: syscall-id mirror.
    pub const print_int: u8 = 0x02;
    // allow-strict: syscall-id mirror.
    pub const print_char: u8 = 0x03;
    // allow-strict: syscall-id mirror.
    pub const print_newline: u8 = 0x04;
    // allow-strict: syscall-id mirror.
    pub const print_fixed: u8 = 0x05;

    // allow-strict: syscall-id mirror.
    pub const format_str_to_buf: u8 = 0x10;
    // allow-strict: syscall-id mirror.
    pub const format_int_to_buf: u8 = 0x11;
    // allow-strict: syscall-id mirror.
    pub const format_char_to_buf: u8 = 0x12;
    // allow-strict: syscall-id mirror.
    pub const format_fixed_to_buf: u8 = 0x13;
    // allow-strict: syscall-id mirror.
    pub const format_terminate_buf: u8 = 0x14;
};
