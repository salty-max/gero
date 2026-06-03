---
bump: minor
---

`for x in <iterable>` now lowers over every iterable shape, not just
ranges. The loop variable is typed from the iterable's element type
(strong-typing: it's never left untyped).

**Iterables**

- `[T; N]` / `Vec(T)` — a direct `0..count` index loop over the
  element buffer (the array's base address, or the Vec's
  snapshotted heap pointer + length). Scalar elements load their
  value; aggregate elements (struct / array / tuple) bind by value,
  address-valued like any inline-aggregate binding.
- `str` — a null-terminated byte walk; the loop variable is `char`.
- A class with `next(self) -> T?` — the iterator protocol (§4.5.3):
  the iterable is evaluated once into a hidden slot (iteration is
  destructive — the instance's own cursor advances), then each pass
  calls `it.next()`, binds the loop variable to a present value, and
  exits on `nil`.

`break` / `continue` / `:label` work across all of them. The loop
variable's type flows into the body, so misusing it (e.g. binding an
`i16` element where `str` is expected) is a type error.

**Scalar-optional return ABI**

Optional-returning calls now materialize correctly. A scalar `T?`
(the 4-byte `{present, value}`) rides the sret convention like a
struct — methods and free functions reserve a per-frame scratch
buffer, `return` materializes the optional there, and the call site
reads it back. A pointer-like `T?` returns its nullable word in the
accumulator. This fixes `if let x = call()` / `let x: T? = call()`
for any optional-returning method or function (previously only
`Vec.pop` / `Vec.get` materialized correctly), and a present inner
value now implicitly wraps (`let x: i16? = 5`).

**Diagnostics**

- `E_TYPE_NOT_ITERABLE` — `for x in e` where `e` isn't a range,
  `[T; N]`, `Vec(T)`, `str`, or a class with `next(self) -> T?`.
