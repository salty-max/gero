---
bump: minor
---

`bank_call <label>` / `bank_jump <label>` pseudo-instructions
ship — the assembler looks up which bank the target lives in
and emits the equivalent `mov $bank, mb` + `call`/`jmp <addr>`
pair automatically.

```asm
; Before — hand-track the bank
mov $01, mb
call render_sprite

; After — assembler tracks it for you
bank_call render_sprite
bank_jump cleanup_path
```

## Why

Cross-bank calls are the dominant footgun in multi-bank asm —
write `mov $0X, mb` with the wrong constant and you call into
garbage, which the VM faults on at runtime. With these pseudos,
the assembler resolves the bank statically; rename / move a
label across banks and every call site follows.

## Semantics

- 7 bytes per pseudo: 4 for `mov imm16, mb` + 3 for
  `call`/`jmp <addr>`. Bytecode-identical to the hand-written
  pair.
- The redundant `mov $bank, mb` is emitted even when the target
  lives in the same bank as the call site — consistent behavior,
  no surprise omission.
- Round-trip is one-way at source level: `gero disasm` emits the
  two real instructions (not `bank_call`). Bytecode round-trips
  identically.
- Target must be a `label` or `data8`/`data16` symbol (those
  carry bank-of-definition via `Symbol.bank`). Pointing at a
  `const` raises `E003` (operand type mismatch).
- Undefined target raises `E004` (undefined symbol).

## Internal — Symbol gains a `bank` field

`asm.symtab.Symbol` adds `bank: ?u8 = null` so the codegen can
resolve label → bank at emit time. Populated by the layout pass
for `.label` and `.data` kinds; `.const_value` and `.struct_field`
stay `null` (they're not bank-positioned). Feature-additive —
existing callsites still compile because the new field has a
default.

## Editor surfaces — follow-up

Tree-sitter and VS Code TextMate need `bank_call` / `bank_jump`
added to their mnemonic lists for proper highlighting. Tracked
separately in the submodule repos; the next submodule pin bump
in gero will pick up both.
