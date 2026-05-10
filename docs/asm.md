# Gero Assembler — Language Spec v0.1

The assembly language that targets the [Gero ISA](./isa.md). Source
file extension `.gas`. Output is a `.gx` bytecode file ready for the
VM.

This spec describes **syntax** — what the assembler accepts as input.
For semantics (what each mnemonic does at runtime), see `isa.md` §5.

> **Source of truth for the formal grammar:** the
> [tree-sitter-gero-asm](https://github.com/salty-max/tree-sitter-gero-asm)
> grammar. This document is the human-readable companion.

---

## 1. Lexical structure

### 1.1 Whitespace

Spaces and tabs are insignificant **within** a line. **Newlines are
significant** — they terminate statements. CRLF and LF are both
accepted; classic-Mac CR is not.

### 1.2 Comments

Semicolon to end-of-line, never crossing newline:

```asm
mov #1, r1     ; load 1 into r1
; full-line comment
```

No multi-line / block comments — keep it 6502-clean.

### 1.3 Identifiers

`[A-Za-z_][A-Za-z0-9_]*`. Case-sensitive. Used for label names,
directive names, variable names.

### 1.4 Numeric literals

| Form | Example | Width | Notes |
|------|---------|-------|-------|
| Hex | `$FFFF` | 1..4 hex digits | Unsigned. `$FF` = 255, `$FFFF` = 65535. |
| Address | `&FFFF` | 1..4 hex digits | Same shape as hex but typed as `Addr`. Distinguishes "this is a memory address" from "this is a literal". |

Decimal and binary literals are **not** in v0.1 — only hex. Old-school
asm convention; if you find yourself wanting decimal, use `$0064` for
100 and move on.

### 1.5 Symbol references

| Form | Example | Meaning |
|------|---------|---------|
| Bang-prefixed | `!hasFrameEnded` | Reference to a symbol declared elsewhere (data or label). Resolves at link time. |
| Bare identifier | `start` | When used as an operand: a label / forward reference. |
| Register pointer | `&r1` | "Address held in r1" — the indirect addressing form. |

---

## 2. Statements

A line is one of: blank, comment-only, label, directive, or
instruction. Multiple labels can stack on consecutive lines before
an instruction or directive.

```asm
; A line with comment only
start:                  ; label
const FRAME_RATE = $3C  ; directive
mov #1, r1              ; instruction
```

### 2.1 Labels

```
<identifier>:
```

A label binds the current address (the byte offset of the next emitted
instruction or data) to the identifier. Labels are case-sensitive,
file-scoped, and must be unique within a file.

```asm
start:
  mov #0, r1
loop:
  inc r1
  cmp r1, $10
  jne loop
  hlt
```

### 2.2 Directives

```
[+] <directive_keyword> <args...>
```

The optional leading `+` marks the symbol as **exported** (visible to
other files when linking). Currently four directives:

| Keyword | Form | Effect |
|---------|------|--------|
| `const` | `const NAME = <value>` | Compile-time constant. Substituted inline at use sites. |
| `data8` | `data8 NAME = { byte, byte, ... }` | Reserve and initialize bytes at the current address. |
| `data16`| `data16 NAME = { word, word, ... }` | Same, in 16-bit words (little-endian). |
| `struct` | `struct NAME { field: TYPE, ... }` | Compile-time struct layout for `<Type>` casts. Generates field offsets but emits no bytes. |

#### `const`

```asm
const VECTOR_KEYDOWN = $0020      ; software-int vector for keydown
const SCREEN_W = $0100            ; 256
+const VRAM_BASE = &8000          ; exported address constant
```

Constants are pure substitution — no runtime cost.

#### `data8` / `data16`

```asm
data8 hasFrameEnded = { $00 }
data8 greeting     = { $48, $65, $6C, $6C, $6F, $00 }   ; "Hello\0"
data16 frameTimes  = { $0000, $0000, $0000, $0000 }
```

The address of the data is bound to the symbol (so `!hasFrameEnded`
in an operand resolves to where the bytes live). Sized by the
directive — `data16` packs each value as a 16-bit LE word.

Each value can be a hex literal, a `!symbol` reference, an address
literal, or a parenthesized arithmetic expression of these.

#### `struct`

```asm
struct Player {
  hp: u16,
  mp: u16,
  level: u8,
  pad: u8,
}
```

Defines a layout — no bytes emitted. The fields produce compile-time
offset constants (e.g. `Player.hp = 0`, `Player.mp = 2`,
`Player.level = 4`, `Player.pad = 5`) usable in cast expressions
(§3.4).

### 2.3 Instructions

```
<mnemonic> [operand[, operand]*]
```

Mnemonics are exactly the keywords listed in `isa.md` §5. The
assembler picks the right opcode encoding based on the operand types.
For example, `mov` resolves to one of `0x10..0x1B` depending on
whether the source / destination is a register, an immediate, an
address, a pointer, or a zero-page address.

```asm
mov $1234, r1     ; 0x10 — Imm16 → Reg
mov r1, r2        ; 0x11 — Reg → Reg
mov r1, &2620     ; 0x12 — Reg → Addr (mem store)
mov &2620, r1     ; 0x13 — Addr → Reg (mem load)
mov $42, &00FF    ; 0x14 — Imm16 → Addr
mov [r1], r2      ; 0x15 — indirect load
mov r1, [r2]      ; 0x16 — indirect store
mov &2620, r1, r2 ; 0x17 — indexed: mem[addr + r1] → r2
mov $42, [r1]     ; 0x18 — Imm16 → ptr
mov r1, $80       ; 0x19 — zero-page store
mov $80, r1       ; 0x1A — zero-page load
```

The assembler rejects invalid combinations (`mov &addr, &addr` has no
opcode) at assembly time, not link time.

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

### 3.2 Register pointers

The address held in a register, denoted by `&` prefix:

```asm
mov &r1, r2     ; load mem[r1] into r2
mov r2, &r1     ; store r2 into mem[r1]
```

### 3.3 Immediate values and addresses

Two distinct prefixes — `$` for "value", `&` for "address":

```asm
mov $1234, r1   ; load the literal 0x1234 into r1
mov &1234, r1   ; load the contents of mem[0x1234] into r1
```

### 3.4 Address expressions and casts

Compile-time arithmetic on symbols, in `&[ ]`:

```asm
data16 player = { $0064, $003C, $0001, $0000 }   ; hp, mp, level, pad

mov &[!player + 2], acu          ; load player.mp into acu
mov acu, &[!player + Player.mp]  ; equivalent, with cast offset
```

Cast syntax `<Type> obj.prop` looks up the field offset from a `struct`
declaration and combines it with the symbol address.

### 3.5 Parenthesized expressions

Grouping for arithmetic precedence inside `&[ ]`:

```asm
const STRIDE = $0010
mov &[!table + (r1 * STRIDE)], acu
```

Operators in v0.1: `+`, `-`, `*`. Division and bitwise ops not yet
spec'd at the assembler level — emit instructions for those.

---

## 4. Sections (TBD)

v0.1 emits a flat image — every directive and instruction goes into
a single output stream starting at offset `0x0000`, padded as
appropriate. There are **no** explicit section directives
(`.text`, `.data`, `.rodata`).

For programs that need to control layout (banked carts, IVT placement,
SRAM region), use `org` directive (see §6 — TBD for v0.1, planned for
v0.2).

---

## 5. Banking

Banked programs need two assembler features beyond v0.1's flat output:

- `bank N` — declares that the following statements emit into bank
  number `N` (rather than the base image)
- `bank_call`, `bank_jump` — pseudo-instructions that wrap
  `mov #N, mb; call addr` (or jmp) for cross-bank calls

These are **not in v0.1**. Until they land, banked carts must be
hand-stitched (assemble each bank as a separate file, concatenate at
the cart-build step). v0.2 will introduce them as the lang compiler
will need them.

---

## 6. Roadmap (post-v0.1)

| Feature | Why |
|---------|-----|
| `org $ADDR` | Place subsequent emit at a specific address (IVT setup, SRAM header alignment). |
| `bank N` | Bank-aware emit for the multi-bank cart workflow. |
| `bank_call` / `bank_jump` | Sugar for cross-bank calls. |
| `include "file.gas"` | Multi-file programs. |
| Macros | Parametric pseudo-instructions (`def macro NAME(args) { ... }`). |
| Decimal & binary literals | `100`, `%10101010`. |
| String literals as `data8` shorthand | `data8 msg = "Hello, World"`. |
| `equ` as alias for `const` | Old-school 6502 spelling. |

These land as the VM and lang compilers exercise the gaps. Each
addition bumps the assembler's minor version; the bytecode they emit
remains ISA v0.1 — assembler evolution is independent of ISA
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

Assembled output (annotated; addresses assume `image starts at 0x0000`):

```
0x0000  10 00 00 02      mov $0000, r1     ; r1 = 0  (Imm16 → Reg)
0x0004  48 02            inc r1             ; loop:
0x0006  60 02 10 00      cmp r1, $0010
0x000A  73 04 00         jne &0004
0x000D  FF               hlt
```

14 bytes. Single-pass assembler can resolve the forward reference
`loop` because `cmp` + `jne` come after the label is bound.

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

Errors print with caret-style snippets (knit's `formatParseErrorPretty`).
