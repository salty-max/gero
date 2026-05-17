---
bump: minor
---

Closures — `lambda () ... end` and short-form `|args| expr`
compile end-to-end. Closes #259.

**Value model.** A closure value is a 2-byte pointer to a heap
tuple `(fn_ptr: u16, capture_0: u16, capture_1: u16, ...)`.
`fn_ptr` is the address of the lambda body, emitted as a
regular def with a mangled `__lambda_<fn>_<n>` label and a
hidden first param `env_ptr`. Captures live at `env_ptr + 2 +
N*2`.

**Capture analysis** (`src/lang/codegen/lambda.zig`). For each
fn body the codegen emits, a pre-pass walks the body to find:

- All let / const / param bindings (the "promotion candidates").
- All lambda expressions + their free variables (idents used in
  the lambda body but declared in the parent scope).
- Which captured bindings are mutated (assigned in the parent
  or inside another lambda over the same binding).
- Which lambdas escape (operand of a `return`).

A binding is **promoted** to a heap cell when it's captured AND
(mutated OR captured by an escaping lambda). Promoted bindings
allocate a 2-byte cell via `sys alloc` at `let` time, the slot
holds the cell pointer, and every read / write goes through cell
deref / store. Closures over a promoted binding capture the cell
pointer — shared state across all closures + the parent.
Non-promoted captures get a by-value copy at closure-creation
time.

**Call site.** `f(args)` where `f` is either:

- a let-binding initialized with a lambda (detected via
  `closure_bindings` from the analysis pass), or
- a local / param whose inferred type is `function` (covers
  `let c = make_counter()` where `make_counter` returns a
  lambda — escape across fn boundaries).

…dispatches via `call_reg`: load fn_ptr from tuple, push closure
ptr as hidden first arg + user args right-to-left, call_reg.

**Typecheck** now returns a function type for lambda expressions
instead of `null` — drives the closure-call detection at sites
where the closure flowed in from another fn. The lambda body's
`return` checks against the lambda's own return type (not the
enclosing fn's).

**`@no_capture` enforcement** stays exactly as #220 shipped —
the typechecker errors on captured-and-mutated bindings inside a
`@no_capture` def body before codegen ever sees the mutation, so
no auto-promotion happens for those.

**Out of scope** (known limits, follow-ups if they materialize):

- Nested-lambda capture flow (an inner lambda's captures don't
  propagate through the outer lambda's env).
- Fn-typed globals (gero has no fn-typed globals today; the
  closure-call dispatch only inspects locals + params for the
  function-type check).

Seven new codegen tests cover the AC end-to-end: zero-capture
lambda, AC1 read-only capture, AC2 mutated capture shared state,
AC3 two closures consistent state, short-lambda `|x|`,
multi-capture mixed, and AC4 returned closure with escape.
