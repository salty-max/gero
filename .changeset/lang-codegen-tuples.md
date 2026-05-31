---
bump: minor
---

Tuple values now construct, lower, and support `.N` element access
(§3.4).

A tuple is an anonymous positional aggregate stored inline as
contiguous, byte-packed slots — the same value model as a struct. `t.0`
/ `t.1` element access parses (the selector is an ordinal, not an
ident) and type-checks to the element's type, and codegen lowers:

- **Construction** — `(1, "x")` writes each element at its slot offset.
- **`.N` access** — loads the element (an `i8` sign-extends).
- **Value semantics** — `let b = a` / `b = a` copy the bytes;
  pass-by-value (a tuple param is copied onto the stack) and
  return-by-value (the multi-return `def f() -> (i16, i16)` shape, via
  the same sret convention as struct returns), including through an
  `@inline` parameter.

Tuple elements are register-width (scalar / `char` / `fixed` / `str` /
enum / class / reference). Combinations not yet lowered are a clean
`E_CODEGEN_UNSUPPORTED` rather than a wrong result: tuple `==` / `!=`,
whole-tuple `print`, a nested struct/tuple element, tuple element store
(`t.0 = x`), and a tuple return from an `@inline` function.

A tuple's max of 4 elements (§3.4) is now enforced — a 5+-element tuple
literal or type annotation is rejected (previously accepted silently).

New diagnostics: `E_TYPE_NOT_A_TUPLE` (`.N` on a non-tuple),
`E_TYPE_TUPLE_INDEX_OOR` (index past the arity), and
`E_TYPE_TUPLE_TOO_MANY` (more than 4 elements).

Closes #305.
