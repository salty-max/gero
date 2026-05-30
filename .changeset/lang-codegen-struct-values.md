---
bump: minor
---

Struct literals now lower as values — `Foo { ... }` constructs, and
struct-typed bindings carry full value semantics (§3.4).

A struct value lives inline as contiguous frame bytes; a struct-typed
expression evaluates to that base address. Construction writes each
field at its offset (recursing into nested struct fields), and
assignment copies the bytes, so `let b = a; b.x = 1` leaves `a`
untouched. Field read/write, nested structs (`o.n.v`), and byte-packed
layouts (`u8` fields take one byte) all work.

Structs cross call boundaries by value:

- **Pass-by-value** — a struct argument is copied onto the stack at its
  full (2-aligned) width, so a callee mutating its parameter never
  affects the caller. Works for free functions, class methods (incl.
  `super.method` and constructor `init` args), and `@inline` callees.
- **Return-by-value** — a struct-returning function receives a hidden
  destination pointer (sret) and copies its result there; the caller
  reads it from a per-frame scratch buffer. Interrupt-safe (no reliance
  on a freed callee frame). Covers free functions, methods (via vtable
  dispatch), and `@inline` callees.

Structs are also usable as inline class fields (`let pos: P` stores the
struct's bytes inside the instance) with by-value field read/write.

A pre-existing bug surfaced and fixed along the way: `@inline` call
arguments were evaluated after the caller's locals went out of scope,
so a local passed to an inlined function failed to resolve. Inline args
now materialize in the caller's scope before the body splice.

Closes #307.
