# Gero ISA — Bytecode Specification

The contract between the VM, the assembler, and the disassembler.
This document is **the** source of truth — once a bytecode is in the
wild, breaking changes bump the version field in the file header
and require a documented migration.

Two languages target this machine: [`asm.md`](./asm.md) and
[`lang.md`](./lang.md). Both emit the bytecode specified
here, and [`asm-vs-lang.md`](./asm-vs-lang.md) explains when to reach
for which.

---

## 1. Philosophy

Gero is a 16-bit register machine in the lineage of the 6502, Z80,
and 8086 — pre-RISC, CISC-flavored, deliberately old-school.

- **16-bit word size** — registers, addresses, and natural-width
  operands are all `u16` / `i16`.
- **Little-endian** — multi-byte values in bytecode and memory are
  stored low-byte-first. Aligns with 6502/Z80/8086 (the 8/16-bit
  micro era) and with `knit`'s `binary.uXXle` parsers.
- **Variable-length encoding** — 1 opcode byte + a per-opcode operand
  schema. Common operations get short encodings (zero-page mode,
  accumulator-implicit ops).
- **Banked memory** — 16-bit address bus exposes 64KB at any moment;
  the `mb` register swaps a 16KB high window between banks for
  programs that exceed 64KB.
- **No floating point** — values are `i16` / `u16`. Fractional math is
  the consumer's job (fixed-point is the canonical answer).

---

## 2. Register file

15 named registers, each 2 bytes (`u16`). Addressed by 1-byte index in
operands — register indices `0x00..0x0E` are valid; `0x0F..0xFF` are
reserved and produce an `InvalidRegister` fault when referenced.

| Idx  | Name  | Purpose |
|------|-------|---------|
| 0x00 | `ip`  | Instruction pointer (PC). Auto-advances per fetch. |
| 0x01 | `acu` | Accumulator. Implicit destination for short-form ALU ops, high-half target for `mul`. |
| 0x02 | `r1`  | General-purpose. |
| 0x03 | `r2`  | General-purpose. |
| 0x04 | `r3`  | General-purpose. |
| 0x05 | `r4`  | General-purpose. |
| 0x06 | `r5`  | General-purpose. |
| 0x07 | `r6`  | General-purpose. |
| 0x08 | `r7`  | General-purpose. |
| 0x09 | `r8`  | General-purpose. |
| 0x0A | `sp`  | Stack pointer. Stack grows toward lower addresses; `push` decrements then writes. |
| 0x0B | `fp`  | Frame pointer. Set by `call`, restored by `ret`. |
| 0x0C | `mb`  | Memory bank — selects which bank is mapped at `0xBE00..0xFDFF`. |
| 0x0D | `im`  | Interrupt mask. Bit set ⇒ that vector is enabled. `0xFFFF` at boot (all enabled). |
| 0x0E | `flg` | Status flags (see §2.1). |

### 2.1 Flags register (`flg`)

ALU operations set the flags; conditional branches read them. Layout
within `flg` (bit 0 = LSB):

| Bit | Name | Set when |
|-----|------|----------|
| 0   | `Z`  | Result is zero. |
| 1   | `N`  | Result high bit is 1 (signed-negative). |
| 2   | `C`  | Unsigned overflow on add, borrow on sub, last bit shifted out of `shl`/`shr`. |
| 3   | `V`  | Signed overflow (sign of result differs from sign of both operands on add; from sign of minuend on sub). |
| 4   | `I`  | Interrupt-disable. `1` ⇒ global IRQs blocked (per-vector mask in `im` still applies on top). |
| 5-15 | reserved | Read as `0`. A write to them is discarded, so a program cannot stash data there and find it later. |

Operations that affect arithmetic flags (Z/N/C/V): `add`, `sub`,
`mul`, `div`, `divs`, `neg`, `and`, `or`, `xor`, `not`, `shl`,
`shr`, `cmp`, `tst`. `mov` and stack ops (`push`, `pop`) do **not**
affect flags.

`inc` / `dec` set Z, N, V but deliberately **leave C intact** — this
matches 6502 / Z80 / 8086 / ARM convention so `cmp` + loop counters
can coexist (you can `cmp` once, then `inc`/`dec` your loop counter,
then conditional-branch on the original carry).

The `I` bit is touched by interrupt-entry / `rti` (see §6) and is
freely writable via `mov ... flg`.

---

## 3. Memory model

### 3.1 Address space

16-bit linear address space, **64KB** addressable at any moment. The
layout below carves the space into regions sized for a fantasy-console
host (gero's primary downstream consumer is gtx-16). The VM itself
only enforces the IVT and bank window; the rest is recommendation —
the host's `MemoryMapper` (§3.5) can remap any region to a device.

| Range          | Size | Role |
|----------------|------|------|
| `0x0000..0x00FF` | 256 B | **Zero page** — 1-byte addressing mode, fast access for lang globals and frequently-touched flags (6502-style). |
| `0x0100..0x0FFF` | 3.75 KB | **Low RAM** — always flat, never banked and never a host register. Where a runtime keeps structures that must survive a bank switch; Gero puts its cross-bank save-stack here. |
| `0x1000..0x11FF` | 512 B | **Interrupt vector table** — 256 entries × 2 bytes each, one per vector. Vector `N` lives at `0x1000 + 2*N`. |
| `0x1200..0x7FFF` | 27.5 KB | **User RAM** — code, data, heap, and the stack. The image is loaded from `0x0000`, so this is where a program's code actually begins to sit; `.gr` puts code at `0x1200` and data at `0x2000`. `sp` boots at `0x7FFE` and grows **down** toward the heap growing **up**. |
| `0x8000..0xBDFF` | 15.5 KB | **Mapped region A** — host-defined. Plain RAM by default. gtx-16 leaves this region as plain RAM and recommends carts use it for sprite-sheet storage + other large assets (the cart sets `SPRITESHEET_BASE` here). |
| `0xBE00..0xFDFF` | 16 KB | **Bank window** — mirrors bank `mb` if the program is banked, otherwise plain RAM. Exactly one bank wide, so every byte of a bank is addressable. |
| `0xFE00..0xFFFF` | 512 B | **Mapped region B / IO page** — host-defined peripheral registers. gtx-16 maps display registers, drawing command surface, audio channels, input, RNG, timer, and KV store here. Plain RAM if no host device claims it. |

The two **Mapped region** ranges (`0x8000..0xBDFF` and
`0xFE00..0xFFFF`) are the convention for embedding hosts. A pure
"compute" program (one that never expects graphics) sees plain RAM
there and can use it freely. A gtx-16-targeted program issues
drawing commands via the IO page (`0xFE50..0xFE61` for the
command surface) and stores sprite data wherever it wants in
cart memory — typically in mapped region A — see gtx-16 §2 for
the full mapping.

### 3.2 Banks

If the program file declares `bank_count > 0` in its header:

- The window `0xBE00..0xFDFF` is mapped to bank number `mb`. It is
  **exactly one bank wide** — 16384 bytes — so a window address reaches
  bank offset `addr - 0xBE00` and every byte of a bank is addressable.
  Nothing in a bank is unreachable, and a `.sav` carries no dead bytes.
- The window sits **below** the IO page rather than against the top of
  memory, so no host register can be swapped out from under a program
  by a write to `mb`.
- `mb = 0` selects the first bank, `mb = bank_count - 1` the last.
- Writing `mb` (via `mov`) swaps the window atomically — code
  executing **from** the bank window during the swap is undefined
  (canonical pattern: copy a trampoline to low RAM, jump to it,
  swap, jump back).
- If `mb >= bank_count`, reads from the window return `0xFF` and
  writes are silently dropped (faulting is too loud for emulator
  use cases — the VM is permissive here by design).

If unbanked (`bank_count == 0`), `mb` is a plain read/write register
with no addressing effect and the window is plain RAM.

#### 3.2.1 Persistent banks (SRAM)

The header field `sram_bank_count` (§7.1) marks the **last N banks**
as battery-backed SRAM — write-persistent across program runs. This
is the standard NES / Game Boy / SNES save mechanism (MMC1/3/5,
MBC1+RAM+BATTERY, etc.) ported into gero's bank model.

If `bank_count = 10` and `sram_bank_count = 2`, banks `8` and `9`
are persistent; banks `0..7` are ROM-style (writes silently dropped
on real hardware emulation, plain RAM in dev hosts that don't
distinguish).

Behavior:

- **At boot** — the host loads SRAM banks from disk if a save file
  exists, otherwise zero-initializes them.
- **At shutdown OR on `int 0x21`** — the host flushes the SRAM
  banks back to disk. `int 0x21` is the conventional "save now"
  syscall (§5.11); useful as insurance against crashes / sudden
  poweroff.
- **From the program's perspective** — bank-switching is uniform.
  The program writes to `mb` to select an SRAM bank and reads/writes
  through the window like any other bank. Persistence is
  transparent.

The host decides where saves live (file path, slot, format). gero
guarantees only that the bytes survive reboots. Programs that need
a save format should reserve a small header (magic + version + length
+ checksum) at the start of the SRAM region — same hygiene as the
program file format itself.

### 3.3 Stack

- Grows **downward**: `push` decrements `sp` by 2 then stores; `pop`
  loads then increments `sp` by 2.
- `sp` is initialized to `0xFFFE` at boot (highest 2-aligned address).
- Stack overflow / underflow are **not** trapped — they wrap. A
  program that misuses the stack corrupts the bank window. (Old-
  school: the 6502 stack was 256 bytes that wrapped silently.)
- `call` pushes the return address (post-instruction `ip`); `ret`
  pops it. `call` also pushes the current `fp`, then sets `fp = sp`.

### 3.4 Endianness

All multi-byte values in bytecode and memory are **little-endian**.
`u16 0x1234` is stored as bytes `0x34 0x12`.

### 3.5 Memory mapping (devices)

The VM accesses memory through a `MemoryMapper` indirection. By
default the mapper exposes 64KB of plain RAM. A host can register
**devices** that claim address ranges:

```zig
pub const Device = struct {
    readByte:  *const fn (ctx: *anyopaque, addr: u16) u8,
    writeByte: *const fn (ctx: *anyopaque, addr: u16, value: u8) void,
    readWord:  *const fn (ctx: *anyopaque, addr: u16) u16,
    writeWord: *const fn (ctx: *anyopaque, addr: u16, value: u16) void,
    ctx: *anyopaque,
};

pub fn map(self: *MemoryMapper, device: Device, start: u16, size: u16) void;
```

(The `*anyopaque` here is a host-API convention, not a VM-internal
convention — the strict-compiler lint allows it at the public-host
boundary with a `// safety:` comment. The VM core itself stays
typed.)

When the CPU performs a memory access, the mapper finds the matching
device (most-recently-mapped wins on overlap) and dispatches. Devices
that don't implement an op (e.g. ROM exposes no `writeByte`) silently
swallow the write.

Bank-window switching (when the program is banked) is implemented
internally as a mapper update on `mb` write — the bank pages are
themselves devices that the VM swaps in.

---

## 4. Instruction encoding

```
[opcode: 1 byte][operands: 0..N bytes per opcode schema]
```

Operand types:

| Type       | Size | Range            | Notes |
|------------|------|------------------|-------|
| `Reg`      | 1    | `0x00..0x0E`     | Register index — see §2 for the full register file. |
| `Imm8`     | 1    | `0x00..0xFF`     | Unsigned 8-bit immediate. |
| `Imm16`    | 2    | `0x0000..0xFFFF` | Little-endian 16-bit immediate. |
| `Addr`     | 2    | `0x0000..0xFFFF` | Little-endian 16-bit address — asm syntax `&XXXX` or `@SYM`. |
| `RegIndirect` | 1 | `0x00..0x0E`     | Register index whose `u16` value is the effective address — asm syntax `[r1]`, `[r2]`, … |
| `Indexed`  | 3    | (`Addr` + `Reg`) | 16-bit base address + 1-byte register index. Effective address = `base + reg.u16`. Asm syntax `[@SYM + r3]` or `[&XXXX + r1]`. |
| `ZP`       | 1    | `0x00..0xFF`     | Zero-page address — 1-byte form of `Addr` for `0x0000..0x00FF`. The assembler downgrades any `&XX` operand whose value fits in `0..0xFF` to its `ZP` variant automatically (peephole pass, opcodes `0x19`/`0x1A`/`0x1B`). Saves 1 byte per access — significant on programs with many global accesses (per-frame counters, scroll positions, etc.). |

---

## 5. Instruction set

The `Schema` column lists operand encoding using a mix of the
type names from §4 (`Reg`, `Imm8`, `Imm16`, `Addr`) and the asm-
syntax shorthand for indirect / indexed forms (`[Reg]` for
`RegIndirect`, `[Addr + Reg]` for `Indexed`, `[Reg + Imm8]` for
`RegOffset`). Read left to right in asm-source order: `Schema:
A, B` means the asm form is `mnemonic A, B` (e.g. `mov $00, r1`).

Operand order convention:

- **Stores and arithmetic** (`mov`, `add`, `sub`, `mul`, `div`, `adc`, `sbc`, bitwise `and`/`or`/`xor`) — `(src, dst)`. Reads naturally: "add X to r1".
- **Tests** (`cmp`, `tst`) — `(subject, value)`. Reads naturally: "compare r1 to 42". No destination operand.

### Pagination — one page, one role

Opcode bytes are organized by 16-slot pages. Each page hosts a
single role; reading the high nibble of a byte tells you what
family of instruction you're looking at.

| Page         | Role                                  | §    |
|--------------|---------------------------------------|------|
| `0x00-0x0F`  | **Unassigned** — always invalid (see below) | —    |
| `0x10-0x1F`  | Word moves (`mov`)                    | 5.1  |
| `0x20-0x2F`  | Byte moves (`mov8` / `movh` / `movl` + block) | 5.2  |
| `0x30-0x3F`  | Stack (`push` / `pop`)                | 5.3  |
| `0x40-0x4F`  | Core arithmetic                       | 5.4  |
| `0x50-0x5F`  | Carry arithmetic (`adc` / `sbc`)      | 5.5  |
| `0x60-0x6F`  | Bitwise (word logic + bit ops)        | 5.6  |
| `0x70-0x7F`  | Shifts / rotates                      | 5.7  |
| `0x80-0x8F`  | Comparison (`cmp` / `tst`)            | 5.8  |
| `0x90-0x9F`  | Branches (jumps)                      | 5.9  |
| `0xA0-0xAF`  | Subroutines (`call` / `ret`)          | 5.10 |
| `0xB0-0xBF`  | Flag manipulation                     | 5.11 |
| `0xC0-0xCF`  | Miscellaneous (`swap` / `nop`)        | 5.12 |
| `0xD0-0xEF`  | **Reserved** for future extensions    | —    |
| `0xF0-0xFF`  | System (`int` / `rti` / `brk` / `hlt`) | 5.13 |

`0x00-0x0F` and `0xD0-0xEF` differ in intent, and the difference is
frozen:

- **`0x00-0x0F` stays permanently unassigned.** Zeroed RAM decodes as
  `0x00`, so a program that runs off the end of its code faults
  immediately on the invalid-opcode vector instead of executing
  whatever the zero page happens to mean. Assigning anything here
  would turn that into silent execution.
- **`0xD0-0xEF` is reserved for future instructions.** A decoder that
  meets one must raise the invalid-opcode fault, which is what makes
  filling a slot later an additive change: an older VM rejects the
  new program loudly rather than mis-decoding it.

Every unassigned byte in either range raises the invalid-opcode fault
(vector `0x01`). No opcode is "ignored".

### 5.1 Data movement (`mov` family) — `0x1X`

Every `mov` variant writes the source to the destination without
affecting flags. Multiple opcodes share the `mov` mnemonic — the
assembler picks the correct one from operand types.

| Opcode | Mnemonic | Schema | Effect |
|--------|----------|--------|--------|
| `0x10` | `mov`    | `Imm16, Reg`    | reg ← imm |
| `0x11` | `mov`    | `Reg, Reg`      | dst ← src |
| `0x12` | `mov`    | `Reg, Addr`     | mem[addr] ← reg |
| `0x13` | `mov`    | `Addr, Reg`     | reg ← mem[addr] |
| `0x14` | `mov`    | `Imm16, Addr`   | mem[addr] ← imm |
| `0x15` | `mov`    | `Reg, [Reg]`    | mem[ptr] ← reg (indirect store — `ptr` is the second `Reg` operand's `u16` value) |
| `0x16` | `mov`    | `[Reg], Reg`    | reg ← mem[ptr] (indirect load) |
| `0x17` | `mov`    | `[Addr + Reg], Reg` | reg ← mem[base + idx] (indexed load — asm form `[@SYM + r3]`) |
| `0x18` | `mov`    | `Imm16, [Reg]`  | mem[ptr] ← imm |
| `0x19` | `mov`    | `Reg, ZP`       | mem[zp] ← reg (zero-page store, 1-byte addr) |
| `0x1A` | `mov`    | `ZP, Reg`       | reg ← mem[zp] (zero-page load) |
| `0x1B` | `mov`    | `Imm16, ZP`     | mem[zp] ← imm (zero-page immediate store) |
| `0x1C` | `mov`    | `[Reg + Imm8], Reg` | load via register-relative offset: `dst ← mem[base + sign_extend(imm)]`. Offset range −128..+127. Typical use: stack-frame locals (`mov [fp - $04], r1`). |
| `0x1D` | `mov`    | `Reg, [Reg + Imm8]` | store via register-relative offset: `mem[base + sign_extend(imm)] ← src`. Offset range −128..+127. |

### 5.2 Byte-sized data movement (`mov8` family) — `0x2X`

Reads and writes a single byte (low half) instead of the full word.
Useful for character buffers, packed data, and bulk memory transfers
(`bcpy` / `bfill`).

| Opcode | Mnemonic | Schema | Effect |
|--------|----------|--------|--------|
| `0x20` | `mov8`   | `Imm8, Addr`    | mem[addr] ← imm (1 byte) |
| `0x21` | `mov8`   | `Imm8, Reg`     | reg.lo ← imm; reg.hi ← 0 |
| `0x22` | `mov8`   | `Addr, Reg`     | reg.lo ← mem[addr]; reg.hi ← 0 |
| `0x23` | `mov8`   | `Reg, [Reg]`    | mem[ptr] ← reg.lo |
| `0x24` | `mov8`   | `[Reg], Reg`    | reg.lo ← mem[ptr]; reg.hi ← 0 |
| `0x25` | `mov8`   | `[Addr + Reg], Reg` | reg.lo ← mem[addr + idx]; reg.hi ← 0 (byte-level indexed load — useful for stepping through `data8` arrays) |
| `0x26` | `movh`   | `Reg, Addr`     | mem[addr] ← reg.hi |
| `0x27` | `movl`   | `Reg, Addr`     | mem[addr] ← reg.lo |
| `0x28` | `mov8`   | `Imm8, ZP`      | mem[zp] ← imm (1 byte, zero-page store) |
| `0x29` | `mov8`   | `ZP, Reg`       | reg.lo ← mem[zp]; reg.hi ← 0 (zero-page byte load) |
| `0x2A` | `movh`   | `Reg, ZP`       | mem[zp] ← reg.hi (zero-page hi-byte store) |
| `0x2B` | `movl`   | `Reg, ZP`       | mem[zp] ← reg.lo (zero-page lo-byte store) |
| `0x2C` | `bcpy`   | `Reg, Reg, Reg` | block copy: mem[dst..dst+len] ← mem[src..src+len]. Operand order: `dst, src, len` (Intel-style dst first). Length is the third register's `u16` value (0..65535 bytes). Copies low-to-high; overlapping ranges with `dst > src` produce corruption — split or use disjoint regions. Address arithmetic wraps. Doesn't touch flags. |
| `0x2D` | `bfill`  | `Reg, Reg, Reg` | block byte-fill: mem[addr..addr+len] ← val.lo for each byte. Operand order: `addr, len, val`. Length is the second register's `u16` value; `val.lo` is the low byte of the third register. Address arithmetic wraps. Doesn't touch flags. **Renamed from `bset` — that mnemonic now means single-bit set, see `0x68`.** |

### 5.3 Stack (`push`, `pop`) — `0x3X`

| Opcode | Mnemonic | Schema | Effect |
|--------|----------|--------|--------|
| `0x30` | `push`   | `Imm16` | sp ← sp - 2; mem[sp] ← imm |
| `0x31` | `push`   | `Reg`   | sp ← sp - 2; mem[sp] ← reg |
| `0x32` | `pop`    | `Reg`   | reg ← mem[sp]; sp ← sp + 2 |

### 5.4 Arithmetic — `0x4X`

All arithmetic ops set `Z`, `N`, `C`, `V` flags (with the documented
exceptions for `inc` / `dec`). Implicit-`acu` short forms save 1 byte
over the `Reg, Reg` form. `sext` is the only single-operand op
beyond `inc` / `dec` / `neg` — sign-extends `reg.lo` into `reg.hi`.

| Opcode | Mnemonic | Schema | Effect |
|--------|----------|--------|--------|
| `0x40` | `add`    | `Imm16, Reg`  | reg ← reg + imm |
| `0x41` | `add`    | `Reg, Reg`    | dst ← dst + src |
| `0x42` | `add`    | `Reg`         | acu ← acu + reg |
| `0x43` | `sub`    | `Imm16, Reg`  | reg ← reg - imm |
| `0x44` | `sub`    | `Reg, Reg`    | dst ← dst - src |
| `0x45` | `sub`    | `Reg`         | acu ← acu - reg |
| `0x46` | `mul`    | `Imm16, Reg`  | acu:reg ← reg × imm (32-bit unsigned result, high half in acu) |
| `0x47` | `mul`    | `Reg, Reg`    | acu:dst ← dst × src (32-bit unsigned) |
| `0x48` | `inc`    | `Reg`         | reg ← reg + 1 (sets Z, N, V; **leaves C intact**) |
| `0x49` | `dec`    | `Reg`         | reg ← reg - 1 (sets Z, N, V; **leaves C intact**) |
| `0x4A` | `neg`    | `Reg`         | reg ← -reg (sets Z, N, C, V) |
| `0x4B` | `div`    | `Imm16, Reg`  | unsigned 32÷16: acu:reg ÷ imm → quotient in reg, remainder in acu |
| `0x4C` | `div`    | `Reg, Reg`    | unsigned 32÷16: acu:dst ÷ src → quotient in dst, remainder in acu |
| `0x4D` | `divs`   | `Imm16, Reg`  | signed 32÷16, same shape as `div` |
| `0x4E` | `divs`   | `Reg, Reg`    | signed 32÷16, same shape as `div` |
| `0x4F` | `sext`   | `Reg`         | sign-extend `reg.lo` into `reg.hi`. If `reg.lo & 0x80`, `reg.hi ← 0xFF`; else `reg.hi ← 0x00`. Companion to the `mov8` family (which always zero-extends). Doesn't touch flags. |

`div` / `divs` faults:
- Divisor is 0 → vector `0x03` (division by zero).
- Quotient overflows 16 bits → vector `0x05` (arithmetic overflow).

Both vectors fault via the standard interrupt mechanism (§6); if the
vector address is `0x0000`, the VM halts with a host-visible error.

#### 5.4.1 Fixed-point and saturating arithmetic — no native ops

The ISA deliberately has **no native fixed-point** (`fmul`, `fdiv`)
or **saturating** (`qadd`, `qsub`) ops, despite Gero shipping a
`fixed` 8.8 type.

Rationale:

- **Fixed-point add / sub** is identical to integer add / sub —
  the binary point is preserved by alignment. Use `add` / `sub`.
- **Fixed-point mul** = `mul` + `shr 8` (renormalize the binary
  point). 2 ops, ~4 bytes — same cycle count a hypothetical native
  `fmul` would cost (the multiplier hardware doesn't care about the
  binary point).
- **Fixed-point div** = `shl 8` + `div` (pre-scale the dividend).
  Same trade-off.
- **Saturating arithmetic** (clamp to ±max instead of wrap) didn't
  exist on 6502 / Z80 / 8086 / 68000 — it's a post-1990 feature
  (ARMv6, MMX/SSE). Software-emulate via `cmp` + branch + `mov MAX`
  (4-6 bytes), or rely on the Gero compiler to lower
  `clamp(a + b, lo, hi)` patterns to that sequence.

The Gero compiler emits the fixed-point op sequences
automatically — users write `let x: fixed = a * b` and never see
the verbose form. Saturating clamps are a stdlib `math.clamp`
call. No friction at the source level.

If profiling later shows fixed-point or saturating math is a real
hot path, native ops can be added later as an additive minor
version bump (existing code keeps working).

### 5.5 Arithmetic extensions (`adc`, `sbc`, `muls`) — `0x5X`

Add/subtract with carry (the canonical 6502 / Z80 / 8086 primitive
for arithmetic wider than the native register width), plus signed
multiply for languages that need a correct signed-overflow
detector.

| Opcode | Mnemonic | Schema | Effect |
|--------|----------|--------|--------|
| `0x50` | `adc`    | `Imm16, Reg`  | reg ← reg + imm + C (add with carry — multi-precision arithmetic) |
| `0x51` | `adc`    | `Reg, Reg`    | dst ← dst + src + C |
| `0x52` | `sbc`    | `Imm16, Reg`  | reg ← reg - imm - C (sub with borrow — multi-precision arithmetic) |
| `0x53` | `sbc`    | `Reg, Reg`    | dst ← dst - src - C |
| `0x54` | `muls`   | `Imm16, Reg`  | signed mul: `acu:reg ← reg ×s imm` (operands reinterpreted as `i16`; 32-bit signed product, high half in acu) |
| `0x55` | `muls`   | `Reg, Reg`    | signed mul: `acu:dst ← dst ×s src` |

A 32-bit add via two 16-bit registers:

```asm
add  r1, r3      ; low half ; sets C if overflow
adc  r2, r4      ; high half + carry-from-low ✨
```

Same for 32-bit subtraction with `sub` + `sbc`. Without these,
multi-precision math requires explicit branch-on-carry sequences
(slower, larger code).

`muls` complements `mul` — both produce the same 16-bit low half
(modulo two's complement), but their flag semantics differ:

- `mul` sets `V` and `C` when the *unsigned* product doesn't fit
  in 16 bits (`high != 0`). Right for unsigned overflow detection;
  false-positives on legitimate signed products like `(-1) * 5 = -5`
  (where the unsigned interpretation gives `0xFFFF × 0x0005 = 0x0004FFFB`).
- `muls` sets `V` and `C` when the *signed* product doesn't fit
  in `i16` (range `-32768..32767`). Use this when the language
  needs a one-instruction signed overflow detector — the lang's
  debug-mode overflow trap on `*` is the canonical consumer.

### 5.6 Bitwise — `0x6X`

Word-level logical ops set `Z` and `N`, clear `C` and `V`. Single-bit
ops (`btest` / `bset` / `bclr`) operate on bit positions 0..15 (`imm`
is masked to 4 bits) — `bset` / `bclr` don't touch flags, `btest`
sets `Z` / `N` and clears `C` / `V`.

| Opcode | Mnemonic | Schema | Effect |
|--------|----------|--------|--------|
| `0x60` | `and`    | `Imm16, Reg`  | reg ← reg & imm |
| `0x61` | `and`    | `Reg, Reg`    | dst ← dst & src |
| `0x62` | `or`     | `Imm16, Reg`  | reg ← reg \| imm |
| `0x63` | `or`     | `Reg, Reg`    | dst ← dst \| src |
| `0x64` | `xor`    | `Imm16, Reg`  | reg ← reg ^ imm |
| `0x65` | `xor`    | `Reg, Reg`    | dst ← dst ^ src |
| `0x66` | `not`    | `Reg`         | reg ← ~reg |
| `0x67` | `btest`  | `Reg, Imm8`   | flags ← bit-test: Z = !(reg & (1 << imm)), N = bit value, C/V cleared. Register untouched. |
| `0x68` | `bset`   | `Reg, Imm8`   | reg ← reg \| (1 << (imm & 0x0F)). Sets a single bit; imm masked to 0..15. Doesn't touch flags. |
| `0x69` | `bclr`   | `Reg, Imm8`   | reg ← reg & ~(1 << (imm & 0x0F)). Clears a single bit; imm masked to 0..15. Doesn't touch flags. |

### 5.7 Shifts and rotates — `0x7X`

Logical shifts: `C` receives the last bit shifted out; `Z`, `N` set
on result. Arithmetic shift right (`asr`) replicates the sign bit
into the high bit on each step — equivalent to signed integer / 2.
Rotates cycle bits **through `C`** (the standard 6502 / Z80 / 8086
behavior — `C` is both source for the bit shifted in and destination
for the bit shifted out, so a 17-bit chain).

| Opcode | Mnemonic | Schema | Effect |
|--------|----------|--------|--------|
| `0x70` | `shl`    | `Reg, Imm8` | reg ← reg << imm (shift left) |
| `0x71` | `shl`    | `Reg, Reg`  | dst ← dst << src |
| `0x72` | `shr`    | `Reg, Imm8` | reg ← reg >> imm (logical shift right; high bit zero-filled) |
| `0x73` | `shr`    | `Reg, Reg`  | dst ← dst >> src |
| `0x74` | `asr`    | `Reg, Imm8` | arithmetic shift right — sign bit replicated on each step. Sets Z/N/C; clears V. |
| `0x75` | `asr`    | `Reg, Reg`  | arithmetic shift right with shift count in second reg. |
| `0x76` | `rol`    | `Reg, Imm8` | rotate left through C (bit_out → C → bit_in) |
| `0x77` | `rol`    | `Reg, Reg`  | same with src as count |
| `0x78` | `ror`    | `Reg, Imm8` | rotate right through C (bit_out → C → bit_in) |
| `0x79` | `ror`    | `Reg, Reg`  | same with src as count |

Rotates are the natural primitive for bit-twiddling (sprite flag
packing, hash steps, simple permutations). Without them, equivalent
must be open-coded as `shl` + `shr` + `or` (3 ops vs 1 native rotate).

### 5.8 Compare and test — `0x8X`

`cmp` computes `dst - src`, sets flags, **discards the result**.
`tst` computes `dst & src`, sets `Z` and `N`, **discards the result**.

| Opcode | Mnemonic | Schema | Effect |
|--------|----------|--------|--------|
| `0x80` | `cmp`    | `Reg, Imm16` | flags ← (reg - imm) |
| `0x81` | `cmp`    | `Reg, Reg`   | flags ← (dst - src) |
| `0x82` | `tst`    | `Reg, Imm16` | flags ← (reg & imm) |
| `0x83` | `tst`    | `Reg, Reg`   | flags ← (dst & src) |

### 5.9 Branches — `0x9X`

Jumps and branches read flags (set by the most recent `cmp` / `tst`
or any flag-affecting ALU op). The 16 slots are exactly filled.

| Opcode | Mnemonic | Schema | Branch when |
|--------|----------|--------|-------------|
| `0x90` | `jmp`    | `Addr` | always |
| `0x91` | `jmp`    | `Reg`  | always — `ip ← reg` |
| `0x92` | `jeq`    | `Addr` | `Z = 1` (equal) |
| `0x93` | `jne`    | `Addr` | `Z = 0` (not equal) |
| `0x94` | `jlt`    | `Addr` | `N ≠ V` (signed less-than) |
| `0x95` | `jle`    | `Addr` | `Z = 1 ∨ N ≠ V` (signed less-or-equal) |
| `0x96` | `jgt`    | `Addr` | `Z = 0 ∧ N = V` (signed greater) |
| `0x97` | `jge`    | `Addr` | `N = V` (signed greater-or-equal) |
| `0x98` | `jcc`    | `Addr` | `C = 0` (unsigned less / no carry) |
| `0x99` | `jcs`    | `Addr` | `C = 1` (unsigned greater-or-equal / carry set) |
| `0x9A` | `jvc`    | `Addr` | `V = 0` |
| `0x9B` | `jvs`    | `Addr` | `V = 1` |
| `0x9C` | `jz`     | `Addr` | `Z = 1` (alias for `jeq`) |
| `0x9D` | `jnz`    | `Addr` | `Z = 0` (alias for `jne`) |
| `0x9E` | `djnz`   | `Reg, Addr` | `reg ← reg - 1`; if `reg ≠ 0` then `ip ← addr`. Z80 classic loop primitive. |
| `0x9F` | `jr`     | `Imm8`      | relative jump: `ip ← ip + signed(imm)` (range −128..+127 from current `ip`). Saves 1 byte vs `jmp Addr` for tight branches. |

### 5.10 Subroutines — `0xAX`

| Opcode | Mnemonic | Schema | Effect |
|--------|----------|--------|--------|
| `0xA0` | `call`   | `Addr` | push fp; push (ip after-instruction); fp ← sp; ip ← addr |
| `0xA1` | `call`   | `Reg`  | same as above with `ip ← reg` |
| `0xA2` | `ret`    | (none) | sp ← fp; pop ip; pop fp |

### 5.11 Flag manipulation — `0xBX`

Single-byte ops to toggle individual flag bits — saves the
`mov flg, r1` + `or r1, mask` + `mov r1, flg` dance (5 bytes → 1).

| Opcode | Mnemonic | Schema | Effect |
|--------|----------|--------|--------|
| `0xB0` | `clc`    | (none) | clear carry: `flg.C ← 0` |
| `0xB1` | `sec`    | (none) | set carry: `flg.C ← 1` |
| `0xB2` | `cli`    | (none) | clear interrupt-disable: `flg.I ← 0` (enables IRQs globally) |
| `0xB3` | `sei`    | (none) | set interrupt-disable: `flg.I ← 1` (blocks IRQs globally) |
| `0xB4` | `clv`    | (none) | clear overflow: `flg.V ← 0` |

Direct 6502 / 8086 lineage. `cli` / `sei` are essential for ISR
critical sections; `clc` / `sec` for setting up `adc` / `sbc`
sequences.

### 5.12 Misc — `0xCX`

| Opcode | Mnemonic | Schema | Effect |
|--------|----------|--------|--------|
| `0xC0` | `swap`   | `Reg, Reg` | atomic swap of two registers |
| `0xC1` | `nop`    | (none)     | no operation; advance `ip` by 1 |

### 5.13 System — `0xFX`

| Opcode | Mnemonic | Schema | Effect |
|--------|----------|--------|--------|
| `0xFB` | `sys`    | `Imm8` | host-callback syscall — dispatches to a fixed handler in the VM (not user bytecode). See §5.13.1 for the registered syscall numbers and register conventions. |
| `0xFC` | `int`    | `Imm8` | software interrupt — push state, jump via vector table at `0x1000 + 2 * imm`. By convention `int 0x21` = "flush SRAM to disk now" (§3.2.1). |
| `0xFD` | `rti`    | (none) | return from interrupt — restore state, resume |
| `0xFE` | `brk`    | (none) | breakpoint — VM raises `Break` event for the host (debugger). Distinct from `hlt`: execution can resume. |
| `0xFF` | `hlt`    | (none) | halt — VM raises `Halt` event for the host. Execution does not resume; program is done. |

#### 5.13.1 `sys` syscalls

`sys` dispatches the `Imm8` operand to a fixed VM handler. Output
syscalls write to the host-provided `Host.out` writer (see VM
embedding API); when no writer is installed the syscalls become
silent no-ops. Unknown syscall numbers raise the
**invalid-opcode** fault.

| ID    | Name            | Register convention                            |
|-------|-----------------|------------------------------------------------|
| `0x01`| `print_str`            | `acu` = address of a null-terminated byte string in memory. Bytes (without the trailing `\0`) are written to `Host.out`. |
| `0x02`| `print_int`            | `acu` = signed 16-bit value. Written as decimal to `Host.out`. |
| `0x03`| `print_char`           | low byte of `acu` written directly. |
| `0x04`| `print_newline`        | writes a single `\n` byte. |
| `0x05`| `print_fixed`          | `acu` = Q8.8 fixed-point value. Formats as `<int>.<3-digit-frac>` decimal — e.g. value `384` (1.5 in Q8.8) prints `1.500`. Negative values get a leading `-`. |
| `0x06`| `print_uint`           | `acu` = unsigned 16-bit value. Written as decimal to `Host.out`. (Unsigned counterpart of `print_int`.) |
| `0x10`| `format_str_to_buf`    | `acu` = source str address (null-terminated). `r1` = dst cursor. Copies the bytes (excluding the trailing null) from `[acu]` to `[r1]`, then advances `r1` past the copy. |
| `0x11`| `format_int_to_buf`    | `acu` = i16 value. `r1` = dst cursor. Appends the signed-decimal representation of `acu` at `[r1]`, then advances `r1`. |
| `0x12`| `format_char_to_buf`   | `acu` = char value (low byte). `r1` = dst cursor. Writes the low byte to `[r1]`, advances `r1` by 1. |
| `0x13`| `format_fixed_to_buf`  | `acu` = Q8.8 value. `r1` = dst cursor. Appends the same `<int>.<3-digit-frac>` formatting as `print_fixed` at `[r1]`, then advances `r1`. |
| `0x14`| `format_terminate_buf` | `r1` = dst cursor. Writes a single null byte at `[r1]` and advances `r1` by 1 (so chained terminators don't stomp the same slot). |
| `0x15`| `format_uint_to_buf`   | `acu` = u16 value. `r1` = dst cursor. Appends the unsigned-decimal representation of `acu` at `[r1]`, then advances `r1`. (Unsigned counterpart of `format_int_to_buf`.) |
| `0x17`| `format_runtime`       | `acu` = format string (null-terminated). `r1` = dst cursor. `r2` = base of the `args` words. `r3` = count (bits 0–7) \| element default type (bits 8–10, the `format_spec_to_buf` type codes) \| element-signed (bit 11). Backs `str.format(fmt, args)` (§3.2.2): walks `fmt`, copies literal bytes, and replaces each `{N}` / `{N:spec}` positional placeholder with `args[N]` formatted per the (runtime-parsed) spec (`{{` / `}}` are literal braces). An out-of-range / digit-less placeholder is dropped. |
| `0x16`| `format_spec_to_buf`   | `acu` = value (or str byte-pointer for the `str` type). `r1` = dst cursor. `r2` = width (bits 0–7) \| fill char (bits 8–15). `r3` = type (bits 0–2: `0` dec, `1` hex-lower, `2` hex-upper, `3` bin, `4` oct, `5` str, `6` char, `7` fixed) \| align (bits 3–4: `0` type-default, `1` left, `2` right, `3` center) \| signed (bit 5) \| zero-pad (bit 6) \| has-precision (bit 7) \| precision (bits 8–15). Appends `acu` formatted per the Gero §3.2.2 format spec at `[r1]`, then advances `r1`. Numeric types render in the requested radix; zero-padding of a negative is sign-aware (`-042`). |
| `0x20`| `alloc`                | bump-allocate `acu` bytes on the heap. On success, sets `acu` to the address of the freshly-allocated block and advances the VM's heap cursor by the requested size. On exhaustion (cursor + size would collide with the stack or fall outside the program's heap region), raises the **heap-exhausted** fault (vector `0x04`). Faults if `heap_base = 0` (program declared no heap). |
| `0x30`| `trap`                 | Raise the **trap** fault (vector `0x06`). No arguments. A program calls it to give up deliberately — Gero emits it after a failed `test.assert_*`, `panic`, `unreachable`, or `todo` has printed. With no handler installed the VM stops with `halted_on_fault`, which a host can distinguish from the `halted` a clean `hlt` produces. |

Writer failures (host stdout closed, OOM in the writer's buffer)
raise the **invalid-opcode** fault as well. The `sys` mechanism is
intentionally narrow — it's the embedding boundary, not a general
syscall surface. Add new syscall numbers conservatively.

---

## 6. Interrupts

### 6.1 Vectors

The interrupt vector table lives at `0x1000` and holds **256 entries**
of 2 bytes each (`u16le` address). Vector `N` lives at
`0x1000 + 2 * N`, so the table spans `0x1000..0x11FF`.

The count follows from the encoding: `int` takes an `Imm8` (§5.13), so
every one of the 256 byte values is a legal vector and every one needs
a slot. A smaller table would leave part of the operand's range
addressing memory outside it.

Reserved vectors:

| Vector | Trigger |
|--------|---------|
| `0x00` | Reset (executed at boot if entry-point address is `0`). |
| `0x01` | Invalid opcode fault. |
| `0x02` | Invalid register fault. |
| `0x03` | Division by zero (`div` / `divs` with divisor = 0). |
| `0x04` | Heap exhausted (`sys alloc` with cursor + size colliding with the stack, exceeding the heap budget, or `heap_base = 0`). |
| `0x05` | Arithmetic overflow. VM raises this on `div` / `divs` when the quotient exceeds 16 bits. Languages targeting gero may also software-raise it (via `int 5`) when their own overflow checks fire — Gero does so for `+` / `-` / `*` in debug builds. |
| `0x06` | Program-initiated trap. Raised by `sys trap` when a program gives up deliberately — Gero emits it after a failed `test.assert_*`, `panic`, `unreachable`, or `todo` has printed its message. Distinct from `hlt` so a host can tell a program that gave up from one that finished. |
| `0x07..0x1F` | Reserved (host-defined). gtx-16 uses `0x07` for its vblank IRQ. |
| `0x20..0xFF` | Software interrupts (`int N`). |

### 6.2 Entry sequence

When an interrupt fires (and is not masked — see §6.4):

1. Push `ip`, `fp`, `flg` onto the stack (in that order — top-of-stack
   is `flg`).
2. Set `flg.I = 1` to block further interrupts globally by default.
   The ISR can clear `I` itself if it wants nested-IRQ behavior.
3. Set `ip ← mem[0x1000 + 2 * vector]`.
4. Continue dispatch.

Only `ip`, `fp`, and `flg` are saved. General-purpose registers
(`acu`, `r1`–`r6`) and the bank selector `mb` are **not** preserved — a
handler must save and restore any it clobbers (6502 `pha`/`pla`
discipline).

`mb` matters as much as the general registers in a banked program: a
handler that selects a bank returns with a different 16 KB mapped
through `0xBE00..0xFDFF`, so the interrupted code resumes reading the
wrong memory. The cross-bank call trampoline (§3.2) restores `mb` on
its own, so a plain call into a banked def is safe; an explicit switch
is not.

The Gero compiler does this automatically for `@interrupt`
handlers — the general registers always, and `mb` whenever the program
declares banked defs.

### 6.3 Exit sequence (`rti`)

1. Pop `flg`, `fp`, `ip` (reverse order).
2. Resume execution. `flg.I` is restored to its pre-ISR state by the
   pop, so nested vs flat ISR control is automatic.

### 6.4 Masking

Two layers, by design — global on/off vs per-vector mask:

- **`flg.I`** (bit 4 of `flg`) is the **global** interrupt-disable.
  When set, no interrupts fire regardless of `im`. Set automatically
  on ISR entry, restored on `rti`. Software can `mov ... flg` to
  toggle.
- **`im`** is a 16-bit per-vector mask: bit N enables vector N
  (vectors `0x00..0x0F` only — fine-grained masking for the fault
  range). Vectors `0x10..0xFF` are always enabled if `flg.I = 0`;
  finer masking is the program's job.
- At boot: `flg.I = 0` (interrupts globally enabled), `im = 0xFFFF`
  (every maskable vector enabled).

This split mirrors 6502 (the `I` flag in `P` plus an external IRQ
controller for per-line masking) and 8086 (the `IF` flag in `FLAGS`
plus the PIC's `IMR`).

---

## 7. Bytecode file format (`.gx`)

Binary file, little-endian throughout. Magic bytes mark a valid gero
executable; the version field gates ISA evolution.

`.gx` files contain **bytecode only** — pure executable image, no
assets. A fantasy-console cart format (e.g. gtx-16's future format)
wraps a `.gx` file alongside sprite / audio / map data and console
metadata.

### 7.1 Header (16 bytes)

| Offset | Field          | Size | Notes |
|--------|----------------|------|-------|
| `0x00` | magic          | 4    | `'G' 'E' 'R' 'O'` (`0x47 0x45 0x52 0x4F`) |
| `0x04` | version        | 2    | u16le format version — major in the high byte, minor in the low. Currently `0x0100`. Every producer stamps this same value: the header describes the file, not which front-end wrote it. |
| `0x06` | flags          | 2    | u16le bitfield (see below) |
| `0x08` | entry_point    | 2    | u16le address `ip` is set to at boot |
| `0x0A` | image_size     | 2    | u16le base-image size in bytes (`0..65535`; max 65535-byte image — programs needing more use banks) |
| `0x0C` | bank_count     | 1    | total number of 16KB banks (0..255) |
| `0x0D` | sram_bank_count| 1    | how many of the **last** banks are battery-backed SRAM (0..255, must be `<= bank_count`); 0 ⇒ no save support |
| `0x0E` | heap_base      | 2    | u16le address where the bump allocator's heap starts. `0x0000` ⇒ no heap (programs that call `sys alloc` will fault). Otherwise it **must be at or above `image_size`**, and in a banked program (`bank_count > 0`) **below the bank window at `0xBE00`** — a heap inside the image would hand out addresses over live code or data, and one inside the window would lose every allocation on the next `mb` write. The base image is refused on the same ground: in a banked program it may not reach into the window either, since every read there routes to a bank and those bytes could never be read back. `sys alloc` only bounds the top of the heap, so none of this is caught at run time; a loader rejects a file that violates any of it. Added in version `0x0002`; files declaring version `0x0001` always read `0x0000` here. |

#### Flags bitfield

| Bit | Meaning |
|-----|---------|
| 0   | banked  — file contains `bank_count` × 16384 bytes after the base image |
| 1   | has-debug-symbols — debug section follows the image / banks |
| 2-15| reserved — a writer must set them to `0`, and a reader **must reject** a file with any set. Rejecting rather than ignoring is what lets a future flag be additive: an older VM refuses a program it cannot honor instead of running it with the flag's meaning silently dropped. |

### 7.2 Layout

```
[Header — 16 bytes]
[Base image — image_size bytes]   (loaded at 0x0000 in RAM at boot)
[Banks — bank_count × 16384 bytes] (only if flag bit 0)
[Debug symbols — variable]         (only if flag bit 1)
```

### 7.3 Debug section (optional)

Present when flag bit 1 is set. A sequence of chunks, each framed:

```
[u8 kind]
[u32le payload_len]
[payload_len bytes]
```

Chunks run to the end of the section; there is no chunk count. A
reader **must skip a `kind` it does not recognize** rather than
failing — that is what lets a later table be added without another
format break, and it is the property this section is designed around.

| `kind` | Chunk | Payload |
|--------|-------|---------|
| `0x01` | symbols | `address → name` |
| `0x02` | files   | source paths a line table indexes into |
| `0x03` | lines   | `address range → (file, line, column)` |
| other  | reserved | skip |

A chunk carrying no rows is omitted entirely. A section with no
chunks is not written at all, and flag bit 1 stays clear.

#### `0x01` — symbols

```
[u16le symbol_count]
For each symbol:
  [u16le address]
  [u8 kind]                 — 0 = label (code), 1 = data
  [u8 name_len]
  [name_len bytes — UTF-8 symbol name]
```

`kind` lets the disassembler tell apart code labels and `data8`/
`data16` blocks. A label produces `call <name>` / `jmp <name>`
substitutions in the disasm; a data symbol switches the
disassembler into data mode at that address, emitting
`data8 <name> = $XX, $YY, ...` until the next symbol (or end of
section). Unknown `kind` values reserved for future use are
treated as `label` (fail-safe — the bytes still try to decode as
instructions).

Used by the disassembler to annotate addresses and by debuggers to
resolve names. Stripped from release builds.

#### `0x02` — files

```
[u16le file_count]
For each file:
  [u16le path_len]
  [path_len bytes — UTF-8 source path]
```

Paths take a 16-bit length because an absolute path can exceed the
255 bytes a symbol name is capped at. The order is the index space
the `lines` chunk refers to: file `0` is the entry file.

#### `0x03` — lines

```
[u16le row_count]
For each row:
  [u16le start_addr]
  [u16le end_addr]          — exclusive
  [u16le file]              — index into the files chunk
  [u16le line]              — 1-based, clamped at 0xFFFF
  [u16le column]            — 1-based, clamped at 0xFFFF
```

Maps a machine address back to the source position that produced it,
for source-level stepping, a current-line highlight, and setting a
breakpoint by clicking a line rather than typing an address.

Rows are ascending by `start_addr`. Ranges are **explicit rather than
implied by the next row's start**, so an address in a gap — a
prologue, padding, a jump table — resolves to no row instead of
silently borrowing the previous statement's position.

Rows **nest** wherever source statements do: an address inside an `if`
body is covered by both the body's row and the enclosing `if`'s. A
reader resolving an address wants the **narrowest** covering row —
the innermost statement actually executing.

A `lines` chunk requires a `files` chunk; a producer that cannot
attribute files (no include/import map available) emits neither.

---

## 8. Boot sequence

1. Allocate 64KB RAM (zero-initialized).
2. Read program file header. Validate magic + version. Fault on mismatch.
3. Load base image bytes `0..image_size` into RAM `0x0000..image_size`.
4. If banked: bind the `bank_count` × 16KB bank pool. Set `mb = 0`.
   - If `sram_bank_count > 0`: load the last `sram_bank_count` banks
     from the host's save store (file, NVRAM, etc.). If no save
     exists, zero-initialize those banks. The remaining
     `bank_count - sram_bank_count` banks come from the program file
     image and are ROM-style.
5. Initialize registers:
   - `ip ← entry_point`
   - `sp ← 0x7FFE`  (top of user RAM — see below)
   - `fp ← 0x7FFE`
   - `mb ← 0`
   - `im ← 0xFFFF`
   - `flg ← 0x0000`
   - `acu`, `r1..r8` ← 0
6. Begin fetch-decode-execute loop.

`sp` boots at the top of **user RAM**, not the top of memory. Three
constraints meet there and only user RAM satisfies all of them: the
region must be flat, or the stack writes into peripherals and then into
whatever `mb` selects; it must sit above the heap, because `sys alloc`
refuses to grow past `sp`; and it needs room to descend, which the
distance from the image to `0x7FFE` provides. A program is still free to
move `sp` wherever it likes as its first instruction.

---

## 9. Faults

The VM raises a fault to the host via the interrupt mechanism, through
the vectors §6.1 reserves. If the corresponding vector address is `0`,
the VM halts with a host-visible error code.

| Vector | Cause |
|--------|-------|
| `0x01` | Invalid opcode (byte read at `ip` is not in the opcode table) |
| `0x02` | Invalid register (operand register index `>= 0x0F`) |
| `0x03` | Division by zero (`div` / `divs` with divisor = 0) |
| `0x04` | Heap exhausted (`sys alloc` overflows past the available heap region) |
| `0x05` | Arithmetic overflow (`div` / `divs` quotient > 16 bits) |
| `0x06` | Program-initiated trap (`sys trap` — failed assertion, `panic`, `unreachable`, `todo`) |

`mb >= bank_count` and stack over/underflow are **not** faults — they
behave permissively (read `0xFF`, write dropped; stack wraps).

---

## 10. Versioning

This document specifies version `0x0100` — format major **1**, minor
**0**. Which concrete edits are additive and which are breaking, with
worked examples from this repository's own history, is settled in
[`versioning.md`](versioning.md).

**The format is frozen at 1.0.** From here, a change that would make a
VM accept a file and do the wrong thing requires a major bump, and a
major bump is a deliberate, documented event rather than a side effect
of a refactor. The promise is about what a `.gx` means; it does not
wait on any particular package version, and `gero` being at `0.x` says
nothing about it.

Future ISA changes:

- **Patch-level edits to this doc** (clarifying ambiguous behavior,
  fixing typos, documenting reserved bits) do not bump the version.
- **Backwards-compatible additions** (new opcodes in unused ranges,
  new flag bits, new vector reservations) bump the **minor** field (low
  byte): `0x0101` and `0x0100` run on each other.
- **Breaking changes** (changing existing opcode semantics, changing
  encoding, repurposing a register, moving a region of the memory map)
  bump the **major** field — a future `0x0200` — and require migration
  tooling.

That last list ends where it does deliberately. Major 1 exists because
the memory map moved: the bank window, the IO page and the boot stack
(§3.1, §8). None of that is encoded in a `.gx` header, and a `0.x`
archive is perfectly well-formed — its *instructions* simply address a
machine that no longer exists. The version field is a promise about
execution, not about the bytes of the container.

The VM and assembler embed the version they target. A file from any
other major is refused in **both** directions, naming both versions: a
higher one means rules this build does not know, a lower one means
rules it no longer follows.

---

## 11. Settled questions

Nothing in this document is left open. What follows is the record of
what the audit against the implementation settled, so a reader meeting
an unusual choice can see it was a choice:

- `mul` produces 32-bit `acu:dst` (8086 / 68000 lineage). §5.4.
- `inc` / `dec` set Z, N, V and leave C intact (6502 / Z80 / 8086 /
  ARM consensus), so `cmp` and a loop counter can coexist. §2.1, §5.4.
- Interrupt re-entry is `flg.I` plus the `im` per-vector mask (the
  6502 / 8086 split), with no separate "in-ISR" bit. §2.1, §6.4.
- `div` / `divs` fault at vectors `0x03` (divide by zero) and `0x05`
  (quotient wider than 16 bits). §5.4, §6.1, §9.
- `image_size` is a plain `u16le` over `0..65535`, with no overload
  and no flag bit. A program needing more uses banks. §7.1.
- The vector table holds 256 entries spanning `0x1000..0x11FF`, one
  per value of `int`'s `Imm8` operand. §3.1, §6.1.
- `0x00-0x0F` is permanently unassigned, distinct from the reserved
  `0xD0-0xEF` range, so zeroed memory faults instead of executing. §5.
- Reserved `flg` bits read as `0` and are masked on write. §2.1.
- Reserved header flag bits are rejected rather than ignored, so an
  older VM refuses a program it cannot honor. §7.1.
- The bank window is exactly one bank wide and sits below the IO page,
  so every bank byte is addressable and no host register can be banked
  away. §3.1, §3.2.
- `sp` boots at the top of user RAM: flat memory, above the heap, with
  room to descend. §8.

Each of these is reserved in the sense §10 uses: a future **minor**
version may assign a meaning, and doing so is additive because the
current version guarantees nothing can depend on the reserved state.
