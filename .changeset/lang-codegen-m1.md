---
bump: minor
---

Closes #194 + #258. **M1 milestone (Core codegen walking-skeleton)** —
the typed AST now lowers to real `.gx` bytecode that the VM
boots, runs, and prints from.

**Deliverable**

```
def add(a: i16, b: i16) -> i16
  return a + b
end

def main()
  let r: i16 = add(5, 3)
  print r
end
```

Compiles → boots VM → prints `8\n` → halts.

**Instruction selection (#194)**

`src/lang/codegen.zig` grows an `Emitter` with bytecode primitives
(`movImmToReg`, `addRegToAcu`, `pushReg`, etc.) and walks the
typed AST emitting bytes directly. Coverage:

- Statements: `let` / `const`, `return`, `print` (multi-arg with
  space separators + trailing newline per spec §4.9), expression
  statements + `_ = expr` discards.
- Expressions: `int_lit` (with bit-cast for negatives),
  `bool_lit`, `nil_lit`, `char_lit`, `paren`, `ident` (load from
  local or param slot), unary `-x`, binary `+ - * /` via the
  stack-machine pattern (eval RHS / push / eval LHS / pop r1 /
  apply op).
- `mul` and `divs` go via `r2` (their VM semantics put the high
  word into `acu`, so `mul X, acu` would clobber the low result).

**Stack frame model**

Locals + params live in fp-relative stack slots. For the entry
def, sp starts at `fp_boot` and the prologue is `sub
local_bytes, sp`; epilogue is `hlt`. For free fns, the VM's
`call` opcode already pushes `fp` + `ret_ip` then sets
`fp = sp`, so the codegen only emits `sub local_bytes, sp` at
entry and `ret` at exit — the VM unwinds in `ret`.

**Free-function calling convention (#258)**

- Caller pushes args **right-to-left** so callee sees param 0
  at `[fp + 4]`, param 1 at `[fp + 6]`, … (skip the ret_ip +
  old_fp slots).
- Caller emits `call <addr>` with a forward-reference placeholder.
- After return, caller `add (2 * N), sp` to drop the args
  (caller-cleans-up).
- Return value in `acu`.

`emitProgram` lays out every top-level `def` in the base image
(entry first at `code_base = 0x1100`, rest in source order),
recording each fn's address. A patching pass at the end rewrites
every call's 2-byte address slot. Forward references resolve
cleanly.

**Public surface**

No new public types. The existing `gero.lang.compile` /
`Compiled` / `CompileOptions` surfaces stay stable — the work
all lives inside `src/lang/codegen.zig`.

**Tests**

19 codegen tests (5 → 19, +14):
- Instruction selection: let with int-lit init, binary add /
  sub / mul / div, unary neg, ident load across slots, nested
  precedence (`2 * (3 + 4) = 14`), print of int literal / multi-
  arg / let-bound value.
- Calling convention: nullary fn call returning to acu, binary
  fn (`add(a, b)`), call result stored into local, param order
  (`sub 10, 3 == 7`), nested calls (`twice(twice(2)) == 8`).

**Out of scope (separate issues)**

- Memory-placement annotations (`@bank` / `@addr` / `@zero_page`
  / `@volatile` / `@align`) — #261 stays open for these; will be
  split into atomic per-annotation issues since each carries its
  own emission machinery (bank routing, zp allocator, alignment
  padding, etc.).
- Recursion + mutual recursion (the address-patching already
  supports forward refs; needs a test).
- Multi-return tuples / closures / class methods — M3.
- Control flow (`if` / `while` / `for` / `match`) + defer — M2.
