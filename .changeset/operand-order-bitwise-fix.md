---
bump: minor
breaking: true
---

`and` / `or` / `xor` reg-imm variants now follow gero's canonical
`(src, dst)` operand-order convention.

**Breaking change** for the asm source surface (bytecode shape
unchanged):

```asm
; before
and r1, $0F                  ; (dst, src) — Intel-style, the wart
or  r1, $80
xor r1, $FF

; after
and $0F, r1                  ; (src, dst) — matches every other store/arith op
or  $80, r1
xor $FF, r1
```

## Why

While auditing `isa.md` for #125, found that `and`/`or`/`xor` had
**different operand-order conventions across their own variants**:

- `or r1, r2` (reg-reg) → `r2 = r2 | r1` — `(src, dst)` ✅ canonical
- `or r1, $FF` (reg-imm) → `r1 = r1 | $FF` — `(dst, src)` ❌ Intel wart

Same wart for `and` / `xor`. The reg-imm forms accidentally drifted
to Intel-style ordering at some point in early gero (PR #36-era);
the reg-reg forms always followed AT&T (matching `mov` / `add` /
`sub` / `mul` / etc).

`cmp` and `tst` are unchanged — they use `(subject, value)` because
they have no destination operand (test ops, flags-only).

## Migration

Search for `\b(and|or|xor)\s+r\d+,\s*\$` in your `.gas` sources
and swap the two operands. The only such call site inside the
gero repo was `examples/asm/fib.gas:30` (`and r1, $0F` →
`and $0F, r1`), now migrated.

## Why now

Per the v0.2 = "asm complete" philosophy: leaving operand-order
inconsistent across variants of the same mnemonic was unprofessional.
Gero has 0 external users today — the right moment to fix the wart.
