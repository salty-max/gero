---
bump: minor
---

Fixed-size arrays `[T; N]` now lower end-to-end in the gero-lang
compiler: array literals `[a, b, c]`, repeat literals `[value; count]`,
and indexed read/write `arr[i]` / `arr[i] = x`.

Element `T` is any type — a scalar (`i8` / `u8` / `i16` / `u16`, sign-
extending an `i8` on load) or an aggregate (`struct`, tuple, or nested
`[T; N]`), laid out inline at `i * elem_width`. Arrays are value types:
binding, passing, and returning one copies its bytes; a repeat literal
constructs the value once and replicates it into each independent slot.

Indexing carries the same bounds contract as the arithmetic-overflow
trap. A constant out-of-range index is a compile error
(`E_TYPE_INDEX_OOR`); a runtime out-of-range index faults to vector
`$02` in debug builds and is unchecked in release / size. A non-integer
index is rejected (`E_TYPE_MISMATCH`). The typechecker now resolves
`arr[i]` to the element type instead of leaving it untyped.

Aggregate literals store directly into an lvalue — `arr[i] = Pos { x: 1,
y: 2 }`, `ts[i] = (3, 4)`, `grid[i] = [5, 6]` — with no temporary
binding. The destination address is parked on the stack while the
literal's fields evaluate, so the value materializes in place. The same
mechanism fixes assigning an aggregate literal into a struct field
(`obj.field = Pos { ... }`) and adds tuple-field stores (`obj.pair = (a,
b)`), which previously required spelling the value into a `let` first.
