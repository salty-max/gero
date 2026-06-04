---
bump: minor
---

Class methods can now be variadic (`def m(self, …, args: ...)`, §4.6.2).
A variadic method type-checks once against `args: (T, …, T)` and
monomorphizes per call-site arity — `args.N` indexing and
`str.format(fmt, args)` forwarding work in a method body, on direct,
`self`, `super`, and reference receivers, including inherited methods.

A variadic method is **non-virtual**: per-arity specialization needs a
distinct address per arity, which a single vtable slot can't hold, so it
is statically dispatched to its declaring class and gets no vtable entry.
It therefore can't be `@override` / `@abstract` (new `E_VAR_VIRTUAL`),
and a class can't redefine an ancestor method with a variadic one or
vice versa (new `E_VAR_OVERRIDE`).

Adversarial review surfaced four soundness holes (some pre-existing on
the free-`def` variadic path), all now closed:

- An inline-aggregate variadic element — struct / tuple / array / `Vec`,
  or a scalar `T?` — was accepted then miscompiled (pushed by value,
  read back as one word). It's now rejected with `E_VAR_AGGREGATE`; pass
  aggregate data through an explicit parameter or by reference.
- A variadic body called only with zero varargs skipped all of its body
  type-checking while still emitting an arity-0 specialization; the body
  is now checked against an empty `args` tuple.
- A non-`@static` method declared without `self` was accepted but the
  receiver aliased its first parameter (silent corruption, and a
  compiler panic on the variadic path). Such a method is now rejected
  with `E_METHOD_NO_SELF`.
