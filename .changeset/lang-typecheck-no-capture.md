---
bump: patch
---

Closes #220. Implements `@no_capture` enforcement in the
typechecker per `docs/gero-lang.md` §3.7.2.

When a `def` is annotated `@no_capture`, the typechecker walks
its body and tracks lambdas it contains. Inside each lambda body,
any assignment / compound `op=` / `++` / `--` target that
resolves to a name *not* declared locally in the lambda
(parameter or `let` inside the lambda body) is treated as a
capture-and-mutate and emits `E_ANN_CAPTURE_VIOLATION`. Read-only
captures stay accepted (they don't trigger heap promotion per
§4.7.2). Without `@no_capture`, the same code compiles.

**Implementation**

Two new fields on `Checker`:

- `in_no_capture: bool` — true when walking the body of a
  `@no_capture` def (nested defs inherit).
- `lambda_locals: ?StringHashMapUnmanaged(void)` — non-null when
  inside a lambda body that's being capture-checked. Populated
  via `registerName` for every param and local `let`.

`checkAssign` and `checkIncDec` call a new
`checkNoCaptureMutation(target)` helper that bails fast outside
the no-capture context and emits the diagnostic otherwise.

**Public surface**

No new public types or functions. The diagnostic code
`E_ANN_CAPTURE_VIOLATION` is already documented in
`docs/lang-diagnostics.md`.

**Tests**

7 new tests in `tests/lang/typecheck.test.zig` (155 total):
- Captured-mutation rejected (`=`, `+=`, `++`).
- Read-only capture accepted.
- No-capture lambda accepted.
- Mutation of lambda-local accepted.
- Without `@no_capture`, capture-mutation compiles.
