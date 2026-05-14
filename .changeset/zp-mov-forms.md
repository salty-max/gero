---
bump: minor
---

Zero-page mov forms — automatic 1-byte address downgrade.

Opcodes `0x19` (`mov Reg, ZP`), `0x1A` (`mov ZP, Reg`), and `0x1B`
(`mov Imm16, ZP`) now live. The assembler classifies any `&XX`
literal whose value fits in `0..0xFF` as `.zp`, and the resolver
picks the matching 1-byte-address form. Saves 1 byte per access
vs. the regular `&XXXX` Addr form.

```asm
; before — both emit the regular Addr forms (0x12 / 0x13 / 0x14)
mov r1, &0042              ; 4 bytes
mov &0042, r1              ; 4 bytes
mov $1234, &0080           ; 5 bytes

; after — same source, automatically downgraded to ZP at codegen
;          (no asm syntax change; opt-out is impossible because
;          the bytecode is semantically equivalent)
mov r1, &0042              ; 3 bytes — opcode 0x19
mov &0042, r1              ; 3 bytes — opcode 0x1A
mov $1234, &0080           ; 4 bytes — opcode 0x1B
```

## Why now

The ZP opcode bytes were "reserved" in the v0.1 ISA spec since
PR #36 with a deferred-implementation comment in
`opcode_resolver.zig`. Realized during the Phase 8 doc cleanup
that `gtx-16` (gero's primary downstream consumer) benefits
significantly — frame counters, scroll positions, sprite indices,
palette state all live in zero page and get hit hundreds of times
per frame. The "leave for later" cut from v0.1 stopped making
sense once gtx-16 was on the v1.0 roadmap.

Aligns with the v0.2 philosophy: "asm complete, no half-features".
Removes the only opcode-table zombie.

## Round-trip safety

`gero disasm` emits ZP operands as `&XX` (1-2 hex digit address
literal) so round-trip-asm picks up the same ZP form again. The
previous `$XX` rendering would have re-parsed as `imm8` and broken
the byte-for-byte round trip — fixed in the same patch.

## Scope

Full mov-family ZP coverage in v0.2:

| Opcode | Form | Saves |
|---|---|---|
| `0x19` | `mov Reg, ZP` | 1 byte vs `0x12 mov Reg, Addr` |
| `0x1A` | `mov ZP, Reg` | 1 byte vs `0x13 mov Addr, Reg` |
| `0x1B` | `mov Imm16, ZP` | 1 byte vs `0x14 mov Imm16, Addr` |
| `0x2A` | `mov8 Imm8, ZP` | 1 byte vs `0x20 mov8 Imm8, Addr` |
| `0x2B` | `mov8 ZP, Reg` | 1 byte vs `0x22 mov8 Addr, Reg` |
| `0x2C` | `movh Reg, ZP` | 1 byte vs `0x25 movh Reg, Addr` |
| `0x2D` | `movl Reg, ZP` | 1 byte vs `0x26 movl Reg, Addr` |

Byte-mov variants cover the patterns that matter most for gtx-16:
per-frame counters / scroll positions / palette indices live in
zero page and get hit via `mov8` and `movh`/`movl` constantly.

Jumps don't need ZP variants — zero page is data territory, not
code territory. The resolver Pass 3 (`.zp → .addr` widening)
handles `jmp &XX` / `jeq &XX` / `call &XX` cleanly by falling
back to the regular Addr encoding (no penalty, no extra opcodes).

Bitwise / arith ZP variants are out of scope (the access pattern
"AND r1 with a zero-page-resident mask" is rare).

The resolver Pass 3 (`.zp → .addr` widening) catches any mnemonic
that doesn't have a ZP variant — `jmp &XX`, `jeq &XX`, `call &XX`
etc. fall back to the regular Addr encoding cleanly.

## Files

- `src/asm/opcode_resolver.zig` — 3 new shape entries + resolver
  Pass 3 fallback + `classify` returns `.zp` for small `addr_lit`
- `src/asm/codegen.zig` — emit honors `res.kinds[op_idx] == .zp`
  for 1-byte addr_lit width
- `src/vm/handlers/mov.zig` — 3 word-mov stubs fleshed out;
  4 new byte-mov ZP handlers (`mov8Imm8Zp` / `mov8ZpReg` /
  `movhRegZp` / `movlRegZp`)
- `src/vm/dispatch.zig` — wired 0x2A-0x2D
- `src/vm/opcodes.zig` — disasm operand shapes for 0x2A-0x2D
- `src/disasm/printer.zig` — `.zp` operand renders as `&XX` (not
  `$XX`) for round-trip safety
- `docs/isa.md` §4 + §5.1 — ZP entry promoted to live; opcode
  table rows now describe the real semantics
- `tests/asm/codegen.test.zig` — 10 new tests covering the
  downgrade behavior (word + byte families) + jmp fallback case
- `tests/vm/opcodes.test.zig` — 93 → 97 named-entries count
