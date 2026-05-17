---
bump: minor
---

**Closes out the two limitations carried forward from the memory-
placement annotation PR** — cross-bank calls now auto-route through
a `__call_bank` trampoline, and byte-width global stores lower to
`movl` so MMIO writes no longer clobber the neighboring byte.

**Cross-bank call trampoline**

A pre-pass over `program.statements` populates `fn_banks: StringHash
MapUnmanaged([]const u8, ?u8)` so `emitCall` can decide direct vs
trampoline without needing the target's address yet (forward-ref-
safe). When the caller's bank differs from the callee's, the codegen
emits the call sequence:

```
mov target_addr, r1   ; address of target fn
mov target_bank, r2   ; target bank
call __call_bank
```

and `__call_bank` (11 bytes, emitted once at the end of the base
image when at least one cross-bank call exists) saves the caller's
bank, switches `mb`, calls the target, and restores `mb` on return:

```
__call_bank:
  push mb         ; save caller's bank
  mov r2, mb      ; switch to target bank
  call r1         ; jump to target
  pop mb          ; restore caller's bank
  ret
```

Same-bank calls keep the direct-call shape (3 bytes vs the
trampoline path's setup overhead). The `CallPatch.target` union grows
a `.trampoline` variant so the address-patching pass at the end of
codegen resolves trampoline call sites against the `__call_bank`
emit address.

**Byte-width global stores via `movl`**

`@addr`-pinned bindings of byte-width types (`u8` / `i8` / `bool` /
`char`) now lower assignment stores to `movl acu, $XXXX` (0x27) — a
1-byte store that leaves the neighboring byte untouched. The mirror
case `movl reg, zp` (0x2B) covers `@zero_page` byte stores. Word-
width globals keep the `mov reg, addr` (0x12) shape unchanged.

This matters for MMIO: a `let DISPCTL: u8 = 0 @addr $FE40 @volatile;
DISPCTL = 1` lowering used to write a 16-bit word starting at
`$FE40`, clobbering `$FE41`. Adjacent MMIO addresses are usually
independent registers, so the clobber would corrupt a sibling
register on every write.

**Stop-and-ask, no half-features**

CLAUDE.md grows two new design-principle sections:

- **No half-features, no "David GoodEnough"** — forbids "it mostly
  works but doesn't handle case X — that's a follow-up" and "the VM
  has a gap, so I emit suboptimal bytecode. Documented." Either the
  feature ships complete, or it's explicitly out of scope.
- **Stop and ask, don't assume** — forbids silently working around a
  perceived VM gap or deferring a caveat to a follow-up. When a
  trade-off appears, surface it: "I see two ways to do X: A or B. A
  costs N lines, B costs M. Which one?"

**Tests**

2 new codegen tests (27 → 29, +2):

- Cross-bank call through `__call_bank` trampoline executes end to
  end and returns the right value.
- Byte-store through `@addr` (via `movl`) leaves the neighboring
  byte untouched (sentinel-check on adjacent address).
