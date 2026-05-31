---
bump: minor
---

`print` now renders structs and enums by value, payload-carrying enums
compare structurally, and a set of pre-existing lang gaps surfaced
alongside are closed (§3, §3.2.1, §3.6, §4.9, ISA §syscalls).

**Default rendering.** A struct prints as `Name { field: value, … }` and
an enum as `Enum.Variant` (or `Enum.Variant(a, b)` with a payload).
Fields and payloads render recursively, so a struct holding an enum
prints the variant in place (`Slot { qty: 2, it: Item.Potion(5) }`).
Types with no default rendering — array / tuple / `Vec` / class /
reference, a struct enum payload, or a recursive type — are a clean
compile error rather than a printed address or a compiler crash.

**Enum equality.** `==` / `!=` on a payload-carrying enum compares the
value, not the pointer: tag first, then the matching variant's payload
field-by-field (`str` by content per §3.2.1, a nested enum recursively,
scalars by value). Structs with an enum field compare through it. A
recursive enum is rejected (no finite structural compare).

**Enum-construction typing.** `Item.Potion(20)` now infers the enum type
(it parses as a method call), so `let x = Item.Potion(20)` is typed
`Item` and the payload args are checked — surfacing arity, unknown
variant, and arg-type errors that were previously accepted silently.

**`str` concatenation + ordering.** `a + b` on `str` allocates a fresh
buffer and copies both operands (§3.2.1) instead of adding the two
pointers as integers; the heap now starts above the interned string pool
so a long concat can't alias its own source. `<` / `<=` / `>` / `>=` on
`str` compare lexicographically (byte content) rather than the operand
addresses.

**Guarded match arms.** A `when`-guarded arm no longer marks a later
unguarded same-variant arm unreachable, nor discharges its variant for
exhaustiveness — so the guarded-arm-then-fallback idiom (§4.8.4) checks
correctly.

**Unsigned printing.** A `u16` (bare, struct field, enum payload, or
interpolated) now prints its unsigned magnitude via the new `print_uint`
/ `format_uint_to_buf` syscalls, instead of being formatted as a signed
`i16`. A signed `i8` enum payload is sign-extended on match-bind and
print so a negative value keeps its sign.

**Module-level initializers.** A top-level `const` / `let` initializer is
now evaluated and stored into its slot at entry startup (declaration
order, so a later one can read an earlier one); previously the slot read
back zero for everything but `bake`-backed consts.

**Boolean conditions.** `if` / `elif` / `while` / `repeat`-`until`
conditions and `when` guards must be `bool` — there is no implicit
truthiness (§3). A non-`bool` condition is `E_TYPE_MISMATCH`.

**Recursive structs.** A struct that contains itself by value (directly
or through a struct / array / tuple field) is rejected with the new
`E_TYPE_RECURSIVE_STRUCT` — it has infinite size; previously it crashed
the compiler. Use `Vec(T)` / `&T` for a recursive shape.

**Frame-size diagnostic.** A function frame past the `[fp+imm8]`
addressing limit reports `E_CODEGEN_FRAME_TOO_LARGE` instead of
panicking the compiler.

Closes #323.
