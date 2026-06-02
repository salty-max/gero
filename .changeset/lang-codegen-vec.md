---
bump: minor
---

`Vec(T)` — the growable dynamic array (§3.4.3) — is now implemented. The
value is a 6-byte `(ptr, len, cap)` header stored inline like a struct;
the backing buffer lives on the heap (`sys alloc`).

Constructors: `Vec.new()` (empty), `Vec.with_capacity(n)`, and
`Vec.from([a, b, c])` (copied from a fixed array). Operations: `push`
(doubles capacity when full — growth allocates a new buffer and copies),
`len`, `cap`, `at(i)` (bounds-trapped to `$02` in debug), `set(i, x)`,
`v[i]` / `v[i] = x` (sugar for `at` / `set`), `clear` (keeps the buffer),
and `slice(a, b)` (a borrowed view aliasing the parent — mutating the
slice mutates the parent). Binding a Vec copies its header; element type
`T` can be scalar or aggregate.

Method binders are typed from the receiver's element type (`v.at(i)`
yields `T`, `v.len()` yields `u16`), and `Vec.new` / `with_capacity`
infer `T` from the binding's annotation.

`pop()` and `get(i)` return `T?`. To make them work for scalar elements,
`T?` now extends to scalars: a scalar `T?` is a tagged 4-byte
`{present, value}` value (pointer-like `T?` stays a single nullable word).
`if let n = opt` unwraps an optional (binds `n` to the value when present,
runs `else` when nil), and `opt == nil` / `!= nil` test the tag.

`Vec.from` parses now that a name after `.` accepts the `from` keyword
(otherwise reserved for `use … from`).

The heap is a bump allocator with no free, so a growing `push` leaks the
old buffer (the documented cost on a 16-bit target).
