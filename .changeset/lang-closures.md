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

**Nested lambdas.** Free vars of an inner lambda that aren't
local to the enclosing lambda flow transitively into the
enclosing lambda's capture list. At closure-creation time the
inner closure's env slot is populated by re-reading the slot
from the enclosing env — for promoted (cell-pointer) captures
the pointer propagates as-is so all nesting levels share state;
for by-value captures the value re-copies. Per-lambda scope
analysis tracks each lambda's own promoted bindings and
closure-init let bindings, swapped in while the body emits so
nested `let x = lambda ... end` dispatch routes correctly.

**Call site.** `f(args)` where `f` is either:

- a let-binding initialized with a lambda (detected via
  `closure_bindings` from the analysis pass), or
- a local / param / capture whose inferred type is `function`
  (covers `let c = make_counter()` where `make_counter` returns
  a lambda — escape across fn boundaries — and the nested case
  where the function-typed ident is re-read from the env).

…dispatches via `call_reg`: load fn_ptr from tuple, push closure
ptr as hidden first arg + user args right-to-left, call_reg.

**Typecheck** now returns a function type for lambda expressions
instead of `null` — drives the closure-call detection at sites
where the closure flowed in from another fn. The lambda body's
`return` checks against the lambda's own return type (not the
enclosing fn's). Bidirectional hint flow lets a short-form
lambda assigned to a fn-typed binding (`let f: fn() -> i16 = ||
99`) pick up param + return types from the binding annotation.

**`@no_capture` enforcement** stays exactly as #220 shipped —
the typechecker errors on captured-and-mutated bindings inside a
`@no_capture` def body before codegen ever sees the mutation, so
no auto-promotion happens for those.

Ten codegen tests cover the AC + nested cases end-to-end:
zero-capture lambda, AC1 read-only capture, AC2 mutated capture
shared state, AC3 two closures consistent state, short-lambda
`|x|`, multi-capture mixed, AC4 returned closure with escape,
nested lambda reading through outer's env, nested mutation
sharing a cell across levels, and short-lambda inferring its
shape from a fn-typed binding hint.
