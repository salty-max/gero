---
bump: minor
---

Closes #261. **Finishes M1** — memory-placement annotation
lowering (`@bank`, `@addr`, `@zero_page`, `@volatile`, `@align`)
on top-level `let` / `const` / `def`.

**What lands**

- **Globals table** — every top-level `let` / `const` resolves to
  a `Global { address, width, placement }` during a pre-pass over
  `program.statements`. `inferExpr.ident` and the new
  `emitStatement.assign` consult the table after locals + params
  so globals participate in normal name lookup.
- **`@addr $XXXX`** — pins the binding's address. The codegen
  emits the matching `mov` opcode family (`mov addr, reg` for
  loads, `mov reg, addr` for stores; the byte variants when the
  declared type is `u8` / `i8` / `bool` / `char`). Canonical use:
  MMIO bindings (`@addr $FE40; @volatile; let DISPCTL: u8 = 0`).
- **`@volatile`** — recognized as a marker annotation. The lang
  codegen doesn't register-cache globals today, so the annotation
  is structurally honored without an extra emit pass.
- **`@zero_page`** — auto-allocates from `zp_cursor` starting at
  `$0000`. Uses the `mov zp, reg` / `mov reg, zp` family (1 byte
  cheaper per access than `mov addr`). Page overflow emits
  `E_CODEGEN_ZP_OVERFLOW`.
- **`@align(N)`** — rounds the current placement cursor up to the
  next multiple of `N` before assigning the address. Works for
  both the zero-page allocator and the dynamic data region. The
  typechecker already enforced that `N` is a power of two
  (slice 7).
- **`@bank N`** — routes the annotated `def`'s bytecode into a
  per-bank emit buffer. The `.gx` archive layout grows: header
  declares `bank_count = max_bank + 1` with the `banked` flag bit
  set, and each bank's 16 KiB buffer follows the base image
  (zero-padded for banks the user didn't touch). Cross-bank calls
  route through a `__call_bank` trampoline that the codegen emits
  at the end of the base image when needed:
  ```
  __call_bank:
    push mb         ; save caller's bank
    mov r2, mb      ; switch to target bank
    call r1         ; jump to target
    pop mb          ; restore caller's bank
    ret
  ```
  Same-bank calls keep the direct-call shape (3 bytes vs the
  trampoline's 11). Pre-pass over `program.statements` populates
  `fn_banks` so `emitCall` decides direct vs trampoline without
  needing the target's address yet (forward-ref-safe).

**Byte-width global stores use `movl`**

A `@addr`-pinned `let DISPCTL: u8 = 0; DISPCTL = 1` lowers to
`movl acu, $FE40` (0x27) — a 1-byte store that leaves the
neighboring byte untouched. Critical for MMIO where adjacent
addresses are independent registers. Word-width globals keep the
`mov reg, addr` (0x12) shape. The `mov_reg_to_zp` companion
(`movl reg, zp`, 0x2B) covers zero-page byte stores symmetrically.

**Assignment statement lowering**

`emitStatement.assign` now handles `target = value` for ident
targets resolving to a local, param, or global. Compound `op=`
forms (`+=`, etc.) stay on the unsupported path — they're sugar
that lowers via the binary-op chain and lands in M2 alongside the
rest of control flow.

**Public surface**

No new exports. The diagnostic codes `E_CODEGEN_UNSUPPORTED`,
`E_CODEGEN_UNDEFINED_FN`, and `E_CODEGEN_ZP_OVERFLOW` surface in
the existing `Compiled.diagnostics` slice — not in the
`docs/lang-diagnostics.md` registry yet because codegen
diagnostics are an unstable surface until the rendering pipeline
flows them.

**Tests**

10 new codegen tests (19 → 29, +10):

- `@addr` read + write + read-modify-write (MMIO loop).
- `@volatile` accepted as no-op.
- `@zero_page` allocates from byte 0 upward.
- Globals in data region land at `data_base` (`$2000`).
- `@align(16)` pads placement to a 16-byte boundary.
- `@bank N` routes bytecode into bank N (verified via .gx header
  flags + the bank buffer's first bytes).
- Cross-bank call through `__call_bank` trampoline executes end
  to end and returns the right value.
- Byte-store through `@addr` (via `movl`) leaves the neighboring
  byte untouched (sentinel-check on adjacent address).
