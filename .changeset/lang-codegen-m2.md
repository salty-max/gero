---
bump: minor
---

Closes #214. Advances #195. **M2 milestone** — control flow lowers
to real bytecode. The codegen now consumes `if / else if / else`,
`while`, `for x in a..b [step N]`, `repeat … until`, `match`,
`break [:label]` / `continue [:label]`, and `defer` — alongside
the rest of the operator set (comparisons, short-circuit
`and` / `or`, `not`, bitwise / shift / mod).

**New emit primitives**

- `cmp reg, imm16` (0x80) + `cmp dst, src` (0x81) — drive the
  conditional-jump flags without materializing a 0 / 1.
- `jmp`, `jeq`, `jne`, `jlt`, `jle`, `jgt`, `jge` (0x90..0x97) —
  forward jumps emit a 0 placeholder + record a `JumpPatch`
  for resolution at the matching `end`-of-construct offset.
- `and / or / xor / not / shl / shr` (0x61 / 0x63 / 0x65 / 0x66
  / 0x71 / 0x73) — used for both bitwise expression ops and
  the materialized-bool sequences that drive `&&` / `||` /
  `!` at expression position.
- `currentBufferBase()` → `code_base` (base image) or
  `bank_window_base` (banked def). Jump targets resolve against
  the buffer the patch lives in so `@bank` defs branch
  correctly inside their 16 KiB window.

**Block + loop stacks**

The emitter grows two stacks:

- `block_stack: ArrayList(Block)` — pushed for every lexical
  scope (function body, `do…end`, `if`-arm body, loop body,
  `match`-arm body). Each `Block` owns the LIFO list of
  `defer` statements registered inside it. `popBlockWithDefers`
  emits the defers at the normal fall-through exit; `return` /
  `break` / `continue` re-emit the defers along their jump
  paths via `unwindAllDefersForReturn` / `unwindDefersDownTo`.
- `loop_stack: ArrayList(LoopFrame)` — innermost-first. Each
  frame carries the loop's optional label, the index of its
  body block (so jumps know what to unwind), and forward-patch
  lists for `break` / `continue`. Labels match by string
  equality against `:label` suffixes on the loop head.

**Comparison + condition fast-path**

`emitCondBranch` peels off top-level comparisons and short-
circuit operators so an `if a < b` lowers to a direct
`cmp acu, r1 ; jeq skip` pair instead of going through a
materialized 0 / 1. Comparison ops used at expression position
(e.g. `let cmp = a < b`) still materialize via `cmp + jXX +
mov 0/1 + jmp end`.

Short-circuit `and` / `or` jump out the moment one side
decides the result — the RHS evaluation is skipped on the
short-circuit path.

**Control-flow lowering**

- `if cond1 / else if cond2 / else …` — each arm tests + jumps
  past the body on false. Successful arms forward-jump to a
  shared `end`-of-chain target that's patched after the else
  body emits.
- `while cond` (and `while let pat = expr [when guard]` for
  ident binders) — top-test loop. `continue` lands at the
  cond test; `break` lands past the back-edge.
- `for x in start..end [step N]` — range special case per spec
  §4.5.3. Reserves a hidden `__for_end` slot in the frame, then
  loops with the loop variable as a real local. Step defaults
  to `+1` for `..` / `..=`; explicit `step N` accepts any
  integer expression (int-literal fast-path emits `add imm`).
  Inclusive ranges (`..=`) exit on `cur > end`, exclusive (`..`)
  exit on `cur >= end`.
- `repeat body until cond` — bottom-test loop. `continue` lands
  at the trailing `until` test; the loop back-edges to the top
  when `cond` is falsy, exits when truthy.
- `break [:label]` / `continue [:label]` — `findLoopFrame` walks
  the loop stack innermost-outward (or matching the label),
  unwinds every block above the target loop's body, then emits
  a placeholder `jmp` that lands on the target frame's
  `break_patches` / `continue_patches` list.
- `match scrutinee case pat [when guard] => body … end` — pure
  decision tree (sequential `cmp` + branch). Scrutinee is
  bound to a scratch slot when it isn't already an ident so
  arms don't re-evaluate side effects. OR-patterns dedup onto
  one shared body label (each alt emits its own cmp + a forward
  jump to the body; non-matches fall through to the next alt).
  Range patterns lower to one low+high cmp pair instead of a
  per-value chain. `when` guards eval after the bind and route
  to the same arm-skip path as a failed pattern.

**Defer lowering**

`defer stmt` registers the body pointer on the innermost
block. `popBlockWithDefers` (normal fall-through),
`unwindAllDefersForReturn` (early `return`), and
`unwindDefersDownTo(body_block_idx)` (early `break` /
`continue`) all re-emit the body in LIFO order at the
appropriate offset. The cleanup sequence is wrapped in
`push acu` / `pop acu` so the return value survives the
defer body. Spec §4.10 rejections fire in the typechecker
per the codes registered in `docs/lang-diagnostics.md`
§5.11: `defer return / break / continue` →
`E_DEFER_CONTROL_FLOW`, `defer defer …` → `E_DEFER_NESTED`.

**Operator extensions**

`emitBinary` now lowers `eq / neq / lt / lte / gt / gte`,
`log_and / log_or`, `bit_and / bit_or / bit_xor`, `shl /
shr`, and `mod` (the `divs` remainder). `emitUnary` now
covers `log_not` (cmp + materialize) and `bit_not` (`not
reg`). The condition fast-path keeps short-circuit and
comparison lowering branch-only when consumed as a
condition.

**Frame allocation**

`countLocalsInBody` recurses through every M2 construct so
the function prologue still reserves the right amount of
stack space up front. The pre-pass counts:

- `let` / `const` declarations at any nesting depth.
- The ident binder of `if let` / `while let` / `match` arms.
- A hidden `__for_end` slot per range-based `for` loop.
- A hidden `__match` slot per `match` with a non-ident
  scrutinee.

**M1 self-review backfill**

Re-reading the closed M1 issue ACs (#194 / #258 / #261) surfaced
gaps that this PR also closes:

- **`print "hi"`** (M1 #194 AC) — codegen now lays out an interned
  string pool at the end of the base image. `print "hi"` resolves
  to `mov str_addr, acu; sys print_str`. Dedups on byte content.
  Single-literal strings are supported; interpolation
  (`"$(expr)"`) waits on a VM-side format syscall and emits
  `E_CODEGEN_UNSUPPORTED` until that lands.
- **Fixed-point arithmetic** (M1 #194 AC) — `fixed_lit` lowers to
  the Q8.8 immediate, `fixed * fixed` to `mul + shr 8` /
  `shl 8 + or` (combine the 32-bit product back into Q8.8),
  `fixed / fixed` to `shl 8 + asr 8 + divs` per ISA §5.4.1.
  Type-driven dispatch via the new `CheckedProgram.expr_types`
  map — the typechecker now records every inferred expression
  type so codegen can pick the right lowering. Pure-positive
  Q8.8 round-trip `(a * b) / c` matches the expected result.
- **`print` dispatch by type** (M1 #194 AC) — `print` now picks
  `print_char` / `print_str` / `print_int` from the inferred
  type instead of the AST shape, so `let s = "hi"; print s`
  works as well as `print "hi"`.
- **Zero-page overflow diagnostic** (M1 #261 AC) — `zp_cursor`
  widens to u16 so the bounds check fires cleanly on the 257th
  byte without a safe-mode integer-overflow panic. Test covers
  130 `@zero_page u16` globals → `E_CODEGEN_ZP_OVERFLOW`.

**Not yet (M3 follow-ups)**

- **String interpolation** — needs a VM-side format syscall
  (printf-style `%d / %s / %c` from a template + args) that
  doesn't ship yet. Single-literal strings work; `"$(expr)"`
  emits `E_CODEGEN_UNSUPPORTED` until the syscall lands.
- Enum-variant patterns + jump-table dispatch in `match`
  (need M3 enum tag layout — the codegen emits
  `E_CODEGEN_UNSUPPORTED` on a variant pattern today; the
  typechecker's exhaustiveness check already runs for
  enum scrutinees).
- `for x in iterable` over user-defined types — requires
  method-call codegen (`__it.next()`), which lands with
  classes in M3. Range-based `for` works in full.
- `if let` / `while let` patterns other than a bare ident
  (destructuring patterns ride with enum / struct codegen).

**Tests**

37 new codegen tests (29 → 66, +37) + 4 new typecheck tests:

Codegen:

- if-then / if-else / if-elif-else chain.
- All six comparison ops (`== != < <= > >=`) drive the right
  branches.
- Short-circuit `and` / `or` chains and `not` inversion.
- `while` loop iteration and termination.
- `break` exits innermost loop; `continue` skips the rest
  of the iteration.
- Labeled break exits the outer loop in a nested pair.
- `for` range exclusive / inclusive / step / break.
- `repeat … until` runs body at least once and exits on the
  trailing test.
- Match dispatches literal arms, wildcard fallback, OR
  patterns, range patterns, and guarded ident binders.
- Defer LIFO order at normal block end.
- Defer fires on early `return` (cross-fn cleanup).
- Defer fires on `break` (one per surviving iteration).
- Defer fires on `continue` before the next iteration.
- Defer in nested `do…end` fires inner-first.

M1 backfill (this PR's self-review pass on M1 ACs):

- `print "hi"` outputs `hi` via the string pool + `print_str`.
- Dedup: two `print "hi"` sites share one pool entry.
- String escape sequences decode at codegen time (`\t`, `\n`,
  `\\`, `\"`, `\0`).
- Fixed-point `a * b` round-trips through `mul + shr 8 +
  shl 8 + or` (Q8.8 → Q8.8 within 16-bit range).
- Fixed-point `a / b` round-trips through `shl 8 + asr 8 +
  divs` (24-bit scaled dividend).
- `(a * b) / c` over Q8.8 matches expected.
- Recursive `fib(10) == 55`.
- Nullary call returning a literal.
- 3-arg + 4-arg call shapes preserve param order.
- Caller-saves invariant — local survives a clobbering call.
- Zero-page overflow at the 257th `@zero_page` byte →
  `E_CODEGEN_ZP_OVERFLOW`.

Typecheck (defer-shape rejections per spec §4.10 +
`docs/lang-diagnostics.md` §5.11):

- `defer return` → `E_DEFER_CONTROL_FLOW`.
- `defer break` → `E_DEFER_CONTROL_FLOW`.
- `defer continue` → `E_DEFER_CONTROL_FLOW`.
- `defer defer` → `E_DEFER_NESTED`.
