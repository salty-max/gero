---
bump: minor
---

`str.format(fmt, args…)` (§3.2.2) now lowers — programmatic formatting
for a non-literal format string. Positional `{N}` / `{N:spec}`
placeholders are parsed at runtime by the new `format_runtime` syscall
(`{{` / `}}` escape a literal brace), reusing the same spec engine as
compile-time interpolation. Each call allocates a fresh heap buffer and
returns it as a `str`.

Variadic functions (`def f(…, args: ...)`, §4.6.2) are fully realized.
A variadic body type-checks once against `args: (T, …, T)`, where `T` is
the single element type unified across every call site and the arity is
the smallest seen — so `args.N` is rejected when the smallest call can't
supply it. Codegen monomorphizes: one `name$N` specialization per
distinct call-site arity, sharing the body, with the `args` slot laid
out word-strided so both `args.N` indexing and `format(fmt, args)`
forwarding read it directly. `format(fmt, args)` forwards a variadic
(or plain) tuple positionally.

New diagnostics: `E_VAR_INCONSISTENT_TYPE` (two call sites pass different
element types) and `E_VAR_INLINE` (a variadic `def` can't be `@inline` —
it already specializes per call-site arity).
