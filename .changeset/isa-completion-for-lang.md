---
bump: minor
breaking: true
---

ISA completion sprint — 4 features that gero-lang's compiler will
need for clean signed-integer + bitfield + frame-local codegen.
Pre-1.0 cleanup that frees the lang work from compiler-side
multi-op workarounds.

## New opcodes

| Opcode | Mnemonic | Form | Closes |
|--------|----------|------|--------|
| 0x1C | `mov` | `[Reg + Imm8], Reg` | #185 |
| 0x1D | `mov` | `Reg, [Reg + Imm8]` | #185 |
| 0x2E | `sext` | `Reg` | #182 |
| 0x68 | `bset` | `Reg, Imm8` | #184 |
| 0x69 | `bclr` | `Reg, Imm8` | #184 |
| 0x6A | `btest` | `Reg, Imm8` | #184 |
| 0x6B | `asr` | `Reg, Imm8` | #183 |
| 0x6C | `asr` | `Reg, Reg` | #183 |

## Breaking change — `bset` semantic renamed

The previous 0x28 opcode was named `bset` but its actual
semantics are block byte-fill (memset). The name was a footgun
for anyone reading the ISA expecting bit-set. Pre-1.0 is the
right moment to fix this.

- 0x28 renamed: **`bset` → `bfill`** (semantics unchanged).
- 0x68 is the new **`bset`** — single-bit set.

The block-fill operand shape (Reg, Reg, Reg) is incompatible with
the single-bit shape (Reg, Imm8), so any miscompiled call to the
old `bset` raises E003 (operand type mismatch) at parse time —
fail-fast, no silent corruption.

The only `.gas` file using the old `bset` was
`docs/examples/syntax_overview.gas` — migrated to `bfill` +
added new bset/bclr/btest examples.

## Feature details

### `sext` (sign extension)

`mov8` family always zero-extends. `sext reg` propagates `reg.lo`
bit 7 into `reg.hi` — one-byte instruction replacing the
multi-op workaround for `i8 → i16` promotion.

### `asr` (arithmetic shift right)

`shr` is logical (zero-fill); wrong for signed division by powers
of 2. `asr` replicates the sign bit on each step. Both reg-imm
and reg-reg variants ship.

### Single-bit ops: `bset` / `bclr` / `btest`

Replace mask-and-branch sequences for flag-bit access. `bset` /
`bclr` modify the register without touching flags; `btest` sets
Z + N from the bit value without touching the register. Imm
masked to 0..15 so out-of-range values wrap (no fault).

### `[reg + imm]` addressing

New operand form `[reg + offset]` / `[reg - offset]` for stack-
frame locals. Offset is a signed byte (−128..+127). One
4-byte instruction replaces the 3-instruction (8-byte)
workaround. Disasm renders the sign explicitly:
`[fp - $04]` / `[r1 + $10]`. Round-trips through `gero fmt`.

## Why pre-1.0

Each gap above forces gero-lang codegen to emit multi-op
sequences for common patterns (signed promotion on every
i8 load, flag-bit check on every conditional, frame-local read
on every function call). Shipping these now means the lang
compiler hits clean codegen paths from day one rather than
needing optimizer follow-ups.

The opcode space had ~150 unused slots, so adding 8 opcodes
costs no architectural room. The one renamed opcode (`bset` →
`bfill`) is the only breaking change.

## Editor surface follow-up

Tree-sitter and VS Code TextMate need:
- `sext`, `asr`, `bset`, `bclr`, `btest`, `bfill` added to
  mnemonic lists
- `[reg + imm]` operand form supported in the bracket parser

Both ship as separate submodule PRs alongside this one.
