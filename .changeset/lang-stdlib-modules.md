---
bump: minor
---

`math`, `bank`, and `test` stdlib modules now lower (§5.3), generalizing
the compiler's module-call dispatch beyond `mem`.

`math` is numeric-polymorphic over `i16` / `u16` / `fixed`: `abs`, `min`,
`max`, `clamp`; `wrap_add` / `wrap_sub` / `wrap_mul` (wrap on overflow,
skipping the debug trap); `sat_add` / `sat_sub` / `sat_mul` (clamp to the
integer type's bounds); `sqrt_fixed` (Q8.8 square root); `fixed_sin`
(Bhaskara I, degrees → Q8.8 sine); and `rng()` (deterministic 16-bit
Galois LFSR). Every `math.*` function also evaluates at compile time
inside `bake` bodies — the canonical way to precompute tables such as
sine LUTs — matching the runtime bit-for-bit (the typechecker's types
thread into the bake evaluator so signedness agrees).

`bank.switch_to(n)` / `bank.current()` read and write the bank selector
directly (distinct from the automatic `@bank` cross-bank-call
trampoline). `test.assert_eq(a, b)` / `test.assert_ne(a, b)` compare
register scalars in `@test` functions, printing a diagnostic and halting
the VM on a failed assertion.

All three modules are fully type-checked — calls resolve to concrete
signatures rather than coming back untyped.
