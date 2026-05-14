# Gero Assembler — Language Spec v0.1

The assembly language that targets the [Gero ISA](./isa.md). Source
file extension `.gas`. Output is a `.gx` bytecode file ready for the
VM.

This spec describes **syntax** — what the assembler accepts as input.
For semantics (what each mnemonic does at runtime), see `isa.md` §5.

> **Source of truth for the formal grammar:** the
> [tree-sitter-gero-asm](https://github.com/salty-max/tree-sitter-gero-asm)
> grammar. This document is the human-readable companion.

> **All-in-one syntax tour:** [`docs/examples/syntax_overview.gas`](./examples/syntax_overview.gas)
> exercises every construct in one file — useful when verifying
> editor highlighting or skim-reading the surface.

---

## 1. Lexical structure

### 1.1 Whitespace

Spaces and tabs are insignificant **within** a line. **Newlines are
significant** — they terminate statements. CRLF and LF are both
accepted; classic-Mac CR is not.

### 1.2 Comments

Semicolon to end-of-line, never crossing newline:

```asm
mov $01, r1     ; load 1 into r1
; full-line comment
```

No multi-line / block comments — keep it 6502-clean.

### 1.3 Identifiers

`[A-Za-z_][A-Za-z0-9_]*`. Case-sensitive. Used for label names,
variable names, and field names.

**Mnemonics and directive keywords are lowercase only.** `mov` is
valid, `MOV` is rejected with `E001` (unknown mnemonic). Register
names (`r1`, `acu`, `flg`, …) and reserved keywords (`const`,
`data8`, `data16`, `struct`, `org`, `include`, `reserve`, type
names `u8` / `u16`) are also lowercase-only.

### 1.4 Numeric literals

| Form | Example | Width | Notes |
|------|---------|-------|-------|
| Hex value | `$FFFF` | 1..4 hex digits | Unsigned. `$FF` = 255, `$FFFF` = 65535. |
| Address  | `&FFFF` | 1..4 hex digits | Same shape as hex but typed as `Addr`. Distinguishes "this is a memory address" from "this is a literal value". |
| Char     | `'A'`   | single byte     | Single-quoted ASCII byte. Same C-style escapes as string literals (§1.5). `'A'` = `$41`, `'\n'` = `$0A`. Always a `u8` value. |

Decimal and binary literals are **not** in v0.1 — only hex. Old-school
asm convention; if you find yourself wanting decimal, use `$0064` for
100 and move on.

Char literals are sugar for hex: `cmp r1, 'A'` and `cmp r1, $41` emit
identical bytecode. The advantage is readability for character
comparisons and ASCII-table arithmetic.

### 1.5 String literals

Double-quoted, single-line, with C-style escapes. Used inside
`data8` bodies (see §2.2). Each byte of the string lands in memory
in order, no automatic trailing NUL — write `\0` explicitly when
you want one.

| Escape | Byte |
|--------|------|
| `\0`   | 0x00 |
| `\n`   | 0x0A |
| `\r`   | 0x0D |
| `\t`   | 0x09 |
| `\\`   | 0x5C |
| `\"`   | 0x22 |

Examples:

```asm
data8 hello   = "Hello, gero!\n\0"
data8 prompt  = "name? \0"
data8 quote   = "\"verbatim\"\0"
```

Hex bytes can be mixed with strings inside a `data8` value list
(see §2.2) when a string isn't sufficient — e.g., embedding control
codes the escape table doesn't cover.

### 1.6 Symbol references

| Form | Example | Meaning |
|------|---------|---------|
| `@`-prefixed | `@hasFrameEnded` | Reference to a symbol declared elsewhere (data, label, const). Resolves at assemble time. |
| Bare identifier in operand position | `start` | A label / forward reference. Resolves at assemble time. |
| Indirect via register | `[r1]` | The mem location whose address sits in `r1`. See §3.2. |

`@` (not `!`) marks an explicit symbol reference — distinguishes from
register names, mnemonic keywords, and identifiers used in directive
parameters.

### 1.7 Operators

Compile-time expressions inside `&[ ]` (see §3.4) and on the right-
hand side of `const` (see §2.2) accept the following operators on
constant `u16` values. **Precedence is C-style** (highest first):

| Precedence | Operators | Associativity | Notes |
|------------|-----------|---------------|-------|
| 1 | unary `~` `-` | right | Bitwise NOT, two's-complement negation. |
| 2 | `*` `/` `%` | left | Unsigned multiply, divide, modulo (`/` and `%` on a zero divisor → `E009`). |
| 3 | `+` `-` | left | Binary add / subtract. |
| 4 | `<<` `>>` | left | Logical shift (zero-fill on right shift). |
| 5 | `&` | left | Bitwise AND. |
| 6 | `^` | left | Bitwise XOR. |
| 7 | `\|` | left | Bitwise OR. |

Parentheses override precedence (`&[(@p + 2) * 4]`).

Examples:

```asm
const FLAGS    = (1 << 0) | (1 << 2) | (1 << 5)     ; 0x25
const MASK_LOW = $FF00 >> 8                          ; 0x00FF
const HALF_W   = SCREEN_W / 2                        ; SCREEN_W = $0100 -> $0080
const PADDED   = (SIZE + 7) & ~7                     ; round up to nearest 8
const SIGNED   = -$0001                              ; 0xFFFF
```

Operators are **compile-time only** — they fold constants before
emit. They never produce extra instructions. To compute the same
expression at runtime (with values held in registers), use the
runtime opcodes (`add`, `mul`, `div`, `shl`, `and`, etc.) directly.

---

## 2. Statements

A line is one of: blank, comment-only, label, directive, or
instruction. Multiple labels can stack on consecutive lines before
an instruction or directive.

```asm
; A line with comment only
start:                  ; label
const FRAME_RATE = $3C  ; directive
mov $01, r1             ; instruction
```

### 2.1 Labels

```
<identifier>:
```

A label binds the current address (the byte offset of the next emitted
instruction or data) to the identifier. Labels are case-sensitive,
**image-scoped** (every label is visible across every `include`d
file — same model as 6502 / z80 assemblers), and must be unique
across the entire compilation unit. Use a naming-convention prefix
(`gfx_init`, `snd_step`) to avoid collisions across files.

```asm
start:
  mov $00, r1
loop:
  inc r1
  cmp r1, $10
  jne loop
  hlt
```

### 2.2 Directives

```
<directive_keyword> <args...>
```

Six directives in v0.1:

| Keyword   | Form                                   | Effect |
|-----------|----------------------------------------|--------|
| `const`   | `const NAME = <expr>`                  | Compile-time constant. Substituted inline at use sites. |
| `data8`   | `data8 NAME = value, ...`              | Reserve + initialize bytes at the current address. |
| `data16`  | `data16 NAME = value, ...`             | Same, in 16-bit little-endian words. |
| `struct`  | `struct NAME { field: TYPE, ... }`     | Compile-time struct layout (offsets only, no bytes emitted). |
| `org`     | `org $ADDR`                            | Set the current emit address. Subsequent statements emit starting at `$ADDR`. |
| `include` | `include "path.gas"`                   | Textually splice another `.gas` file at this point (6502 / z80 style). |

#### `const`

```asm
const VECTOR_KEYDOWN = $0020         ; software-int vector for keydown
const SCREEN_W       = $0100         ; 256
const VRAM_BASE      = &8000         ; address constant
const FLAGS_ALL      = (1 << 8) - 1  ; full operator set
```

Constants are pure substitution — no runtime cost.

#### `data8` / `data16`

A `data8` / `data16` directive takes a **comma-separated list of
values** on a single line. No braces — the `=` opens the list and
the newline closes it (newlines are statement terminators per §1.1,
same rule as instructions). Style matches NASM's `db` / `dw`.

```asm
data8  hasFrameEnded = $00
data8  greeting      = "Hello, gero!\n\0"            ; string literal
data8  mixed         = "RST", $00, "FRAME", $00      ; string + bytes
data16 frameTimes    = $0000, $0000, $0000, $0000
```

The address of the data is bound to the symbol (so `@hasFrameEnded`
in an operand resolves to where the bytes live). Sized by the
directive — `data16` packs each value as a 16-bit LE word.

Each value in a `data8` body may be:

- a hex literal (`$48`)
- a char literal (`'H'`) — `data8` only, single byte
- an address literal (`&1000`)
- a `@`-prefixed symbol reference (`@other_data`)
- a string literal (`"Hi"`) — only in `data8`
- a reservation form `reserve N` — see below
- a parenthesized expression of these (see §1.7)

`data16` accepts the same forms minus string literals; each value
ends up as a 16-bit LE word.

Braces (`{ }`) are reserved for multi-line blocks — `struct` (§2.2
below). Single-line value lists never use them.

##### `reserve N`

```asm
data8  scratch  = reserve 256                  ; 256 zero bytes
data16 ringbuf  = reserve 16                   ; 16 zero words (32 bytes)
data8  packet   = $AA, $55, reserve 14, $FF    ; framed header + body + tail
```

`reserve N` emits **N zero-initialized units** at this position
inside a `data8` / `data16` value list — N bytes in `data8`, N
little-endian words in `data16`. It can be mixed with other value
forms inside the same statement (NASM `db`/`resb` mix). `N` is a
compile-time `u16`; runtime values are rejected with `E003`.

Use `reserve` for work buffers, ring buffers, scratch space, or any
region you intend to fill at runtime. Without it, the only way to
declare a 256-byte buffer would be to type 256 `$00`s, which is
exactly the kind of thing the spec is supposed to spare you.

#### `struct`

```asm
struct Player {
  hp:    u16,
  mp:    u16,
  level: u8,
  pad:   u8,
}
```

Defines a layout — no bytes emitted. The fields produce compile-time
offset constants (`Player.hp = 0`, `Player.mp = 2`, `Player.level = 4`,
`Player.pad = 5`) usable in `<Type>` casts (§3.4) and in `const`
expressions.

Supported field types: `u8` (1 byte) and `u16` (2 bytes). Layout is
packed — no padding. Offsets always start at zero for the first
field.

#### `org`

```asm
org $1000               ; IVT lives here per ISA §3.1
data16 ivt_keydown = @on_keydown
data16 ivt_timer   = @on_timer

org $1100               ; user code starts here
start:
  mov $00, r1
  ; ...
```

Sets the **current emit address** for subsequent statements. Required
for any program that needs to place data at a fixed location — most
notably IVT entries (forced to `$1000` by `isa.md` §3.1). `org` does
not emit any bytes itself; it just moves the assembler's emit cursor.

Rules:

- Address must be a compile-time `u16`.
- Backward `org` (target < current emit address) is `E014` —
  overlapping emit is rejected, no silent overwrite.
- Forward `org` leaves an unused gap; the gap is zero-padded in the
  output image so the file size always matches `image_size` in the
  `.gx` header (isa.md §7.1).

#### `include`

```asm
include "graphics.gas"
include "sound.gas"
include "level1.gas"
```

Resolves another `.gas` file at this point and inlines its tokens
**textually** — same model as NASM `%include`, ca65 `.include`,
6502 / z80 assemblers. Path is relative to the including file.

Rules:

- All labels and `const`s from included files share the same global
  namespace as the including file (§2.1 "image-scoped"). Use a
  prefix convention to avoid collisions.
- Cycles are forbidden — including a file that (transitively)
  includes the current file is `E012`.
- Include depth is capped at 32 to bound recursion (`E013`).
- Paths are resolved relative to the directory of the `.gas` file
  doing the include. No search path / no system include directory
  in v0.1.

**Re-include semantics:** every `include` directive splices in
the target's tokens, every time. If two files both `include
"utils.gas"`, the bytes from `utils.gas` are emitted twice. This
matches the asm tradition and gives hand-writers a way to repeat
parametric blocks before macros (post-v0.1) land.

When you want a header to appear at most once, wrap it in an
include guard at the top of the file — same pattern as NASM:

```asm
; ----- utils.gas -----
;ifndef UTILS_GAS    ; (planned syntax — TBD)
;  ... shared definitions here ...
;endif
```

(Conditional assembly is post-v0.1; until it lands, hand-writers
either control the include graph manually or accept the duplicate
emission for repeated sections.)

### 2.3 Instructions

```
<mnemonic> [operand[, operand]*]
```

Mnemonics are the exact lowercase keywords listed in `isa.md` §5.
The assembler picks the right opcode encoding based on the operand
types. For example, `mov` resolves to one of `0x10..0x1B` depending
on whether the source / destination is a register, an immediate,
an address, a register-indirect, an indexed expression, or a
zero-page address.

```asm
mov $1234, r1          ; 0x10 — Imm16 -> Reg
mov r1, r2             ; 0x11 — Reg -> Reg
mov r1, &2620          ; 0x12 — Reg -> Addr (mem store)
mov &2620, r1          ; 0x13 — Addr -> Reg (mem load)
mov $42, &00FF         ; 0x14 — Imm16 -> Addr
mov [r1], r2           ; 0x15 — indirect load
mov r1, [r2]           ; 0x16 — indirect store
mov [&2620 + r1], r2   ; 0x17 — indexed: mem[2620 + r1] -> r2
mov $42, [r1]          ; 0x18 — Imm16 -> ptr
mov r1, $80            ; 0x19 — zero-page store
mov $80, r1            ; 0x1A — zero-page load
```

The assembler rejects invalid combinations (`mov &addr, &addr` has
no opcode) at assembly time with `E003`.

### 2.4 Operand order convention

Every binary instruction reads as **`<op> src, dst`** — the first
operand is the source, the second is the destination (modified
in-place). This is the AT&T-style ordering and it is uniform
across every form: immediate-to-register, register-to-register,
register-to-memory, memory-to-register, etc.

```asm
mov $1234, r1          ; r1 ← $1234           (src=$1234, dst=r1)
mov r1, r2             ; r2 ← r1              (src=r1, dst=r2)
mov &2620, r1          ; r1 ← mem[$2620]      (src=mem, dst=r1)
mov r1, &2620          ; mem[$2620] ← r1      (src=r1, dst=mem)

add $10, r1            ; r1 ← r1 + $10        (src=$10, dst=r1)
add r2, r1             ; r1 ← r1 + r2         (src=r2, dst=r1)
sub r2, r1             ; r1 ← r1 - r2         (src=r2, dst=r1)
and r2, r1             ; r1 ← r1 & r2         (src=r2, dst=r1)
```

Two families are intentionally different:

- **`cmp` and `tst`** — both operands are inputs (no destination),
  the result is just the flags. `cmp r1, $10` reads naturally as
  *"compare r1 to $10"*: it sets flags from `r1 - $10` so that
  `jlt` jumps when `r1 < $10`. The first operand is the value
  being inspected.
- **Shift / rotate (`shl`, `shr`, `rol`, `ror`)** — the first
  operand is the target register being shifted in-place, the
  second is the shift count. `shl r1, $03` shifts r1 by 3.
  Modify-in-place shape, no separate source register.

The 3-operand block ops (`bcpy`, `bset`) keep `(dst, src, len)` /
`(dst, len, val)` — they mirror the C standard library shape.

---

## 3. Operands

### 3.1 Registers

The 15 names from `isa.md` §2: `ip`, `acu`, `r1`–`r8`, `sp`, `fp`,
`mb`, `im`, `flg`. Lowercase only.

```asm
add r1, r2
push acu
mov fp, sp
```

### 3.2 Indirect via register

The mem location whose address sits in a register, denoted by
square brackets:

```asm
mov [r1], r2     ; load mem[r1] into r2 (indirect load)
mov r2, [r1]     ; store r2 into mem[r1] (indirect store)
```

Brackets distinguish "the value held in r1" (use `r1`) from
"the byte at address r1" (use `[r1]`).

### 3.3 Immediate values and addresses

Two distinct prefixes — `$` for "this is a value", `&` for "this
is an address":

```asm
mov $1234, r1    ; load the literal 0x1234 into r1
mov &1234, r1    ; load the contents of mem[0x1234] into r1
```

The two are distinct token kinds for the assembler — `$` always
produces a `u16` value, `&` always produces an `Addr`. Mixing them
where the opcode expects one or the other is `E003`.

### 3.4 Address expressions

Compile-time arithmetic and indexed addressing share one syntax:
square brackets containing an expression. Two forms:

```asm
; (a) compile-time-only address expression — no register involved
mov &[@player + 2], acu              ; load player.mp into acu
mov acu, &[@player + Player.mp]      ; same, with a struct-cast offset

; (b) indexed addressing — at most one register addend, opcode 0x17
mov [@table + r1], acu               ; acu <- mem[table + r1]
mov r2, [@table + r1]                ; mem[table + r1] <- r2
```

The two are distinguished by whether the expression contains a
register. Form **(a)** is pure compile-time arithmetic — the
assembler folds `@player + 2` to a single 16-bit address at emit
time, producing an `Addr` operand the regular mov-with-Addr opcodes
(`0x12` / `0x13` / `0x14`) consume.

Form **(b)** keeps the register addend at runtime — the assembler
checks that the rest is a compile-time-resolvable `Addr` and emits
opcode `0x17` (`mov Addr, Reg, Reg`) with the runtime addend wired
to the register index.

#### Casts

`<Type> @symbol.field` is sugar for `&[@symbol + Type.field]`:

```asm
struct Player { hp: u16, mp: u16 }
data8 player = $64, $00, $3C, $00     ; hp=$0064 (LE), mp=$003C (LE)

mov acu, <Player> @player.hp          ; same as &[@player + Player.hp]
mov $00, <Player> @player.mp          ; same as &[@player + Player.mp]
```

The cast desugars before emit — same bytecode as the longhand. No
runtime cost.

### 3.5 Operator precedence and grouping

Inside `&[ ]` (form a) and inside `const` expressions, the full
operator set from §1.7 applies. Parentheses group as expected.
Form (b) — the indexed-addressing path — restricts the expression to
`<Addr-expr> + <Reg>` where the register addend appears at exactly
one position. Anything else (two registers, register on the right,
register inside a sub-expression that touches operators other than
the outer `+`) is `E003`.

---

## 4. Sections (TBD)

v0.1 emits a flat image — every directive and instruction goes into
a single output stream. There are **no** explicit section directives
(`.text`, `.data`, `.rodata`). Programs that need to control layout
(IVT placement at `$1000`, SRAM region alignment) use the `org`
directive (§2.2).

---

## 5. Banking

Banked programs use two directives:

- `bank N` — sticky directive. Every subsequent statement is
  emitted into bank slot `N` (0-based) until the next `bank`
  directive or EOF. Bank slots are accessed at runtime by setting
  the `mb` register: `mov $N, mb` makes the bank window at
  `$C000..$FEFF` mirror bank `N`.
- `sram_banks N` — declares N battery-backed SRAM banks per ISA
  §5. SRAM banks are the **last** `N` of the cart's banks (they
  share the slot space with ROM banks; the loader treats the
  trailing N as SRAM). The host persists their contents via
  `int $21` and restores them at boot if a matching `.sav` file
  exists.

Both directives accept a hex literal: `bank $01`, `sram_banks $02`.
Decimal isn't part of v0.1 (asm spec §1.4).

### Layout

Each bank's content lives at CPU addresses `$C000..$FEFF` when the
window is mapped to it. Labels declared inside `bank N` resolve to
their bank-window address, so `call <label>` and `jmp <label>`
target the right CPU address — provided `mb` is set to `N` first.

```asm
main:                          ; base image — RAM 0x0000+
  mov $00, mb                  ; window now mirrors bank 0
  call greet                   ; greet is at $C000
  hlt

bank $00
greet:                         ; bank 0, offset 0 → CPU $C000
  mov 'H', r1
  int $10
  ret
```

### Multi-file convention

The `bank N` directive is sticky, so its effect persists across
file boundaries (an `include`d file that ends in `bank $01` leaves
the includer in bank 1 too). The recommended layout for non-trivial
carts is **one file per bank**, with the bank includes at the
**bottom** of the root file:

```
src/
├── main.gas         # base image — must come BEFORE the bank includes
├── bank0_audio.gas  # opens with `bank $00`
└── bank1_sprites.gas# opens with `bank $01`
```

```asm
; main.gas

main:
  ; ... base-image code ...
  hlt

; Bank includes after the base-image hlt — the sticky `bank N`
; directives inside each include don't bleed back into main.
include "bank0_audio.gas"
include "bank1_sprites.gas"
```

See `examples/asm/banks/` for a working three-file demo.

### Cross-bank calls

A cross-bank call is two instructions: switch `mb`, then call /
jmp. The asm has no sugar for this in v0.1 — write the pair
explicitly:

```asm
mov $01, mb
call <label_in_bank_1>
```

A `bank_call` / `bank_jump` pseudo-instruction that desugars to
this pair is a candidate for a future asm minor release (the parser
would need to know which bank `<label>` lives in).

---

## 6. Roadmap (future asm versions)

Note: gero **v0.2 is the high-level language**, not an asm bump. The
assembler is versioned independently — these features land in future
asm minor releases as the VM and lang compilers exercise the gaps.

| Feature | Why |
|---------|-----|
| `bank_call` / `bank_jump` | Sugar for cross-bank calls. |
| Macros | Parametric pseudo-instructions (`def macro NAME(args) { ... }`). |
| Export / import markers | Only relevant if a linker model lands later. v0.1 uses textual `include` with a single global namespace (6502 / z80 tradition). |

Each addition bumps the assembler's minor version; the bytecode they
emit remains ISA v0.1 — assembler evolution is independent of ISA
evolution as long as no new opcode is generated.

---

## 7. Worked example

A minimal program that counts up to 16, then halts:

```asm
; Count up to 16 in r1, then halt.

const TARGET = $10

start:
  mov $00, r1
loop:
  inc r1
  cmp r1, TARGET
  jne loop
  hlt
```

Assembled output (annotated; addresses assume image starts at `0x0000`):

```
0x0000  10 00 00 02      mov $0000, r1     ; r1 = 0  (Imm16 -> Reg)
0x0004  48 02            inc r1             ; loop:
0x0006  60 02 10 00      cmp r1, $0010
0x000A  73 04 00         jne &0004
0x000D  FF               hlt
```

14 bytes. Single-pass assembler can resolve the forward reference
`loop` because `cmp` + `jne` come after the label is bound.

A worked-example with the full feature surface (strings, struct,
cast, operators):

```asm
; ----- compile-time constants -----
const SCREEN_W = $0100
const BUF_LEN  = SCREEN_W / 4              ; division
const MASK_LO  = $FFFF & ($FF00 >> 8)      ; bitwise + shift
const FLAGS    = (1 << 0) | (1 << 5)       ; bitfield

; ----- struct layout -----
struct Player {
  hp:    u16,
  mp:    u16,
  level: u8,
  pad:   u8,
}

; ----- data -----
data8 banner = "Hello, gero!\n\0"
; Player layout = hp(u16), mp(u16), level(u8), pad(u8) = 6 bytes.
; data8 lays bytes in source order, LE for the u16 fields.
data8 player = $64, $00, $3C, $00, $01, $00         ; hp=100 mp=60 lvl=1 pad=0

; ----- code -----
start:
  ; load player.hp into acu via cast
  mov acu, <Player> @player.hp
  ; index into banner via runtime register
  mov $00, r1
banner_loop:
  mov [&banner + r1], r2     ; r2 <- banner[r1]
  cmp r2, $00                ; null terminator?
  jeq end
  ; ... emit r2 to stdout via host syscall here
  inc r1
  jmp banner_loop
end:
  hlt
```

---

## 8. Errors

The assembler emits structured `ParseError`s via `knit`:

```
<file>:<line>:<col>: <message>
  ^^^^ <expected> got <actual>
  context: <inContext labels>
```

Common errors:

| Code | Message |
|------|---------|
| `E001` | Unknown mnemonic |
| `E002` | Operand count mismatch (mnemonic accepts N operands, got M) |
| `E003` | Operand type mismatch (no opcode for this combination) |
| `E004` | Undefined symbol |
| `E005` | Duplicate label |
| `E006` | Hex literal out of range |
| `E007` | Address out of range (would emit > 0xFFFF) |
| `E008` | Reserved opcode used (placeholder for future ISA additions; no opcode is currently reserved-but-unimplemented in v0.1) |
| `E009` | Division by zero in a compile-time expression |
| `E010` | Unknown escape sequence in string or char literal |
| `E011` | Unterminated string literal (newline or EOF before closing `"`) |
| `E012` | `include` cycle detected |
| `E013` | `include` depth exceeds 32 |
| `E014` | Backward `org` would overlap already-emitted bytes |
| `E015` | `include` target file not found |
| `E016` | Char literal must be exactly one byte (empty `''` or multi-char) |

Errors print with caret-style snippets (knit's `formatParseErrorPretty`).
