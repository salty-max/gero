# Gero Asm Cookbook

Short, working recipes for common asm patterns on the gero VM.
Each recipe stands alone — copy the snippet, save as `<name>.gas`,
run through the standard build path:

```bash
gero asm <name>.gas
gero run <name>.gx
```

Companion to [`asm.md`](./asm.md) (full language reference) and
[`isa.md`](./isa.md) (opcode + memory map). When a recipe lifts a
pattern from a worked example, the example is linked at the
bottom of the section.

---

## Contents

1. [Counted loops](#1-counted-loops)
2. [Indexed memory access](#2-indexed-memory-access)
3. [Function call + return](#3-function-call--return)
4. [Banking — `mb` register](#4-banking--mb-register)
5. [SRAM persistence](#5-sram-persistence)
6. [IRQ handler skeleton](#6-irq-handler-skeleton)
7. [Fixed-point arithmetic (Q8.8)](#7-fixed-point-arithmetic-q88)
8. [Include guards](#8-include-guards)

---

## 1. Counted loops

The canonical flag-driven loop: increment a counter, compare
against a sentinel, branch back. The flags are set as a side
effect of `cmp` — `jne` reads them, no explicit flag manipulation.

```asm
; loop.gas — print digits 0..9 then halt.

const PRINT = $10

main:
  mov '0', r1                ; current digit char
.loop:
  int PRINT
  inc r1
  cmp r1, $3A                ; '9' + 1 = $3A → done
  jne .loop
  hlt
```

**Expected**: `0123456789` (no trailing newline)

**See also**: [`examples/asm/counter.gas`](../examples/asm/counter.gas) — same loop, extended to print `0..F` (hex digits) by jumping over the `$3A..$40` gap to land on `'A'`.

---

## 2. Indexed memory access

Use a register as an index into a `data8` array. `mov8` reads one
byte at a time; the `[@SYM + reg]` form computes the address at
load time.

```asm
; indexed.gas — print the contents of a NUL-terminated string.

const PRINT = $10

main:
  mov $00, r3                ; index = 0
.loop:
  mov8 [@TEXT + r3], r1
  cmp r1, $00
  jeq .done
  int PRINT
  inc r3
  jmp .loop
.done:
  hlt

data8 TEXT = "Hello!", $00
```

**Expected**: `Hello!`

The `mov8` opcode reads a single byte; pair with `mov` (`mov16`)
when iterating over a `data16` array of words.

**See also**: [`examples/asm/hello.gas`](../examples/asm/hello.gas) — the same idiom over a longer string.

---

## 3. Function call + return

`call` pushes `ip` and jumps; `ret` pops `ip` and resumes. Stack
discipline is the caller's responsibility — push any registers you
want preserved across the call, pop them on return.

```asm
; call.gas — define a routine that prints r1 twice.

const PRINT = $10

main:
  mov 'A', r1
  call print_twice
  mov 'B', r1
  call print_twice
  hlt

print_twice:
  int PRINT
  int PRINT
  ret
```

**Expected**: `AABB`

For recursion or deep call chains, `push` / `pop` the registers
you'll touch:

```asm
my_func:
  push r1                     ; save caller's r1
  push r2
  ; ... do work, freely use r1 / r2 ...
  pop r2                      ; restore in reverse order
  pop r1
  ret
```

**See also**: [`examples/asm/fib.gas`](../examples/asm/fib.gas) — recursive Fibonacci using `push` / `pop` discipline across ~89 nested calls.

---

## 4. Banking — `mb` register

Banks let a cart hold more than 16 KB of code by mapping different
slots into the `$C000..$FFFF` window. The `mb` register picks which
bank is currently visible.

```asm
; banking.gas — base image calls into bank 0, then halts.

const PRINT = $10

main:
  mov $00, mb                ; window = bank 0
  call greet
  hlt

bank $00                     ; everything below is in bank 0

greet:
  mov 'B', r1
  int PRINT
  ret
```

**Expected**: `B`

The `bank $00` directive is sticky — every statement after it
lands in bank 0's segment until another `bank N` or EOF. The
linker resolves `greet`'s address to `$C000` (the bank-window
base), and the assembler emits the bank's bytes into the
appropriate slot of the `.gx` file.

**Sugar**: `bank_call <label>` and `bank_jump <label>` desugar to
`mov $bank, mb` + `call`/`jmp <addr>`. The assembler looks up
which bank the target lives in, so callers don't have to
hand-track bank IDs across the codebase:

```asm
main:
  bank_call greet              ; assembler emits: mov $00, mb + call greet
  hlt

bank $00
greet:
  mov 'B', r1
  int PRINT
  ret
```

Same bytecode as the manual version — just less error-prone. If
the target moves to another bank (`bank $01 greet:`), the sugar
follows; the manual form would silently call into the wrong bank.

**See also**: [`examples/asm/banks/`](../examples/asm/banks/) — full multi-bank cart with cross-bank calls via two `bank $XX` files glued together by `include`.

---

## 5. SRAM persistence

SRAM banks are the cart's persistent state — battery-backed in
real hardware, snapshotted to a `.sav` file by the gero VM. Write
to them like any bank, then `int $21` to flush.

```asm
; sram.gas — write "OK" to SRAM and flush.

const PRINT     = $10
const FLUSH_SRAM = $21

sram_banks $01               ; declare 1 SRAM-backed bank

main:
  mov $00, mb                ; bank 0 is the SRAM bank
  mov 'O', r1
  mov r1, &C000              ; store at SRAM[0x0000]
  mov 'K', r1
  mov r1, &C001
  int FLUSH_SRAM             ; persist to <name>.sav
  mov 'O', r1
  int PRINT
  mov 'K', r1
  int PRINT
  hlt

; Empty bank 0 — exists only so the cart has a bank slot for
; `sram_banks $01` to adopt. Required by the loader's invariant
; "SRAM count ≤ declared bank count".
bank $00
```

**Expected**: `OK` (plus a `sram.sav` file on disk with `'O' 'K'` at offset 0)

Re-running `gero run sram.gx` picks the `.sav` back up
automatically — the host restores SRAM at boot if a matching
`.sav` exists alongside the `.gx`.

**See also**: [`examples/asm/save.gas`](../examples/asm/save.gas) — same flow, with "SAV\0" written for clarity in a hex-dump.

---

## 6. IRQ handler skeleton

Software interrupts are installed by writing the handler address
to the IVT at `0x1000 + 2 * vector_id`. Vectors `0x20..0x3F` are
user-defined; vectors `0x06..0x1F` are reserved for host-provided
syscalls (`int $10` print, `int $21` flush SRAM, etc.).

```asm
; irq.gas — install a custom ISR on int $30, trigger it.

const PRINT = $10

main:
  mov @my_isr, r1            ; address of the ISR (imm16)
  mov r1, &1060              ; vector $30 lives at 0x1000 + 2*$30 = $1060
  int $30                    ; trigger — pushes ip/fp/flg, jumps to my_isr
  hlt

my_isr:
  mov '!', r1
  int PRINT
  rti                        ; pops flg/fp/ip, resumes after the int $30
```

**Expected**: `!`

On `int $30`, the VM pushes `ip` / `fp` / `flg` (in that order),
sets `flg.I = 1` to block re-entry, then jumps to whatever address
sits at `0x1060`. The `rti` mnemonic pops the state in reverse,
restoring `flg.I` to its pre-ISR value automatically (so flat vs
nested ISR control comes for free).

For hardware-style IRQs (when the host gains the capability),
the same pattern applies — just install at `0x1000 + 2 * <hw_vec>`
and the routine runs whenever the device asserts.

**See also**: [`docs/isa.md`](./isa.md) §6 — full interrupt model + masking via `flg.I` + `im`.

---

## 7. Fixed-point arithmetic (Q8.8)

The VM is 16-bit integer-only — no float opcodes. Q8.8 fixed-point
gives you fractional math by reserving the low byte for the
fractional part: a Q8.8 value of `$0180` represents `1.5`
(`1 * 256 + 128`). Multiplication needs a `shr 8` to bring the
product back into the Q8.8 range (since `Qm.n × Qm.n → Q(2m).(2n)`).

```asm
; fixed.gas — multiply 1.5 × 2.0 in Q8.8.

const PRINT = $10

main:
  mov $0180, r1              ; 1.5 in Q8.8 ($0180 = 384 = 1*256 + 128)
  mov $0200, r2              ; 2.0 in Q8.8 ($0200 = 512)
  mul r1, r2                 ; r2 = r1 * r2 = $30000 (low 16: $0000, high in acu)
  ; for an in-range product we just need the low word + a single shr:
  shr r2, $08                ; r2 = $0300 = 3.0 in Q8.8 (low byte zeroed)
  hlt
```

**Expected**: VM halts cleanly with `r2 = $0300` (= 3.0 in Q8.8).
Use `gero info` after `gero asm fixed.gas` to confirm the image
shape; for live verification add `int PRINT` lines that emit
selected bytes of `r2`.

The same trick works for division (Q8.8 quotient = `(num << 8) / den`),
addition / subtraction (no scaling needed), and angle math via a
Q1.15 sin/cos lookup table in `data16`.

---

## 8. Include guards

Multi-file projects share headers — register definitions, struct
layouts, software-interrupt vector numbers — that risk being
`include`'d from several ancestors. Without protection, the second
include re-emits every `const` and `data8` inside, producing a
duplicate-define cascade.

`ifndef` / `endif` wraps the body so the second include becomes a
no-op:

```asm
; hardware.gas — included from main.gas, sprite.gas, audio.gas, ...
ifndef HARDWARE_INCLUDED
const HARDWARE_INCLUDED = $01

; MMIO map
const PPU_CTRL = &2000
const PPU_MASK = &2001
const APU_STATUS = &4015

; Shared data layouts
struct Sprite { x: u8, y: u8, tile: u8, attr: u8 }
struct Tile   { id: u8, attr: u8 }

endif
```

Every other source file just includes it:

```asm
; sprite.gas
include "hardware.gas"

draw_sprite:
  mov &Sprite, r1    ; uses Sprite from hardware.gas — guard
  ; ...              ; ensures one definition even if main.gas
  ret                ; already pulled hardware.gas in.
```

Notes:

- The check only inspects `const` names, not labels or `data8`.
  The `const HARDWARE_INCLUDED = $01` line right after the
  `ifndef` is what flips the condition for subsequent re-includes.
- Order matters — `ifndef X` placed **before** `const X` is true;
  placed **after**, false. Same rule as NASM `%ifdef`.
- Nested `ifdef` / `ifndef` inside a true outer branch evaluates
  its own condition normally. Nested inside a false outer branch,
  the body is suppressed regardless (and `endif` still pops the
  right frame).

**See also**: [`asm.md` §2.2 `ifdef` / `ifndef` / `endif`](./asm.md).

---

## Where next

- Full asm reference: [`asm.md`](./asm.md)
- Opcode + memory layout reference: [`isa.md`](./isa.md)
- CLI subcommands: [`cli.md`](./cli.md)
- All-in-one syntax tour: [`docs/examples/syntax_overview.gas`](./examples/syntax_overview.gas)
- Worked end-to-end programs: [`examples/asm/`](../examples/asm/)
