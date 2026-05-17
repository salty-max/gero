---
bump: minor
---

Closes #222 + nullary half of #195. Advances #216. **M3a
milestone (codegen foundations)** — adds enum codegen for
nullary variants, the `mem.*` stdlib (typed peek/poke +
memcpy/memset + addr_of), and the typed-reference (`&T`)
codegen. The class-vtable + closure pieces ride in M3b
alongside the shared heap allocator.

**Enum codegen (nullary variants — full payload variants are
M3b)**

- Typecheck: `resolveEnumVariant` recognizes `EnumName.Variant`
  field expressions on receivers matching a registered enum.
  Nullary variants resolve directly to the enum's `Named` type;
  payload-bearing variants synthesize a `fn(payload) -> Enum`
  signature for the wrapping `CallExpr`. Unknown variant names
  emit `E_TYPE_UNDEFINED_VARIANT`.
- Codegen: `collectEnumDecls` pre-pass indexes every top-level
  enum by name. `variantTag` resolves names to their
  declaration-order tag index (matches spec §3.6 — `Sword=0,
  Potion=1, Key=2`). `emitFieldExpr` lowers a nullary
  `EnumName.Variant` to `mov tag, acu`. `emitIsTest` lowers
  `expr is EnumName.Variant` to evaluate-LHS + `cmp` +
  materialize-bool. `emitPatternTest` grows a `.variant_pattern`
  arm — `cmp acu, tag; jne skip` per arm. Composes with the
  existing OR-dedup / range / guard machinery.

**`mem` stdlib (#222 — every typed read/write + memcpy/memset
+ addr_of + peek/poke)**

- Typecheck: `mem` is a compiler-recognized module rather than
  a source module. The receiver-`mem` shape on field
  expressions + method calls dispatches through
  `resolveMemBuiltin` / `checkMemMethodCall`, which validates
  arity + per-arg types against the builtin's declared
  signature and synthesizes a function type so the wrapping
  call flows through the regular type-check path.
- Codegen: `emitMethodCall` intercepts `mem.X(args)` shapes and
  dispatches per builtin:
  - `read_u8`, `peek` → `mov8 [r1], acu` (zero-extend byte
    load).
  - `read_u16`, `read_i16` → `mov [r1], acu` (word load).
  - `read_i8` → `mov8 [r1], acu; shl 8 acu; asr 8 acu` (sign-
    extend byte to i16).
  - `write_u8`, `write_i8`, `poke` → `mov8 acu, [r1]` (byte
    store).
  - `write_u16`, `write_i16` → `mov [r1], acu` (word store).
  - `memcpy(dst, src, n)` → `bcpy r1, r2, r3` (opcode 0x2C).
  - `memset(dst, v, n)` → `bfill r1, r3, r2` (opcode 0x2D).
  - `addr_of(x)` → ident-only for M3a; emits `mov fp, acu`
    + `add/sub ofs, acu` for locals / params, `mov global_addr,
    acu` for static-data bindings.

**Reference codegen (#216 — `&x` expression, type tracking)**

- `&local` / `&param` / `&global` lowers to the address-
  computation the codegen reuses for `mem.addr_of(x)`. The
  reference's runtime representation is a 16-bit address.
- Type-level: `checkRefOf` already rejects `&temp`, `&(a+b)`,
  `&&T`, and `return &local`. M3a doesn't add new typecheck
  rules — it wires up the codegen path.
- Auto-deref on field / method access lands with M3b's
  struct + class layout. M3a's references are useful for
  passing addresses around (paired with `mem.write_*` /
  `mem.read_*`); compound-type field access waits.

**Codegen surface cleanups**

- `MethodCallExpr` (parser shape for `recv.method(args)`) now
  has a codegen arm — previously fell through to
  "unsupported expression form". M3a only handles the
  `mem.X` receiver; class methods land in M3b.
- `CastExpr` (`x as T`) lowers as a no-op for same-width
  primitives (the bit pattern is identical between the
  primitive width set M3a supports). Narrowing / fixed-point
  conversions stay typecheck-only until ISA-level widening
  ops land.
- `Compiled.diag_arena` — codegen diagnostics now allocate
  their message strings on an arena that lives past the
  `compile` call. Pre-existing dangling-pointer bug;
  surfaced by the new tests that print diagnostic messages.

**Tests**

15 new codegen tests (71 → 86, +15):

- Nullary enum constructor stores tag byte.
- `is` test fires on the matching variant.
- 3-arm match on nullary enum dispatches by tag.
- `mem.write_u8` + `mem.read_u8` round-trip.
- `mem.write_u16` + `mem.read_u16` preserve little-endian
  byte order.
- `mem.read_i8` sign-extends `255` to `-1`.
- `mem.poke` + `mem.peek` aliases work identically.
- `mem.memcpy` copies 3 bytes between data slots.
- `mem.memset` fills 3 bytes with one value.
- `mem.addr_of(local)` returns the stack-slot address.
- `mem.addr_of(global)` returns the static address.
- `&x` produces the same address as `mem.addr_of(x)`.
- `&(a + b)` is rejected by typecheck.
- Undefined `mem.X` surfaces `E_TYPE_UNDEFINED_METHOD`.
- Undefined enum variant in `is` rhs surfaces
  `E_CODEGEN_UNDEFINED_VARIANT`.

**Out of scope (M3b follow-up PR)**

- Enum payload variants + payload destructuring in `match`.
- Class vtables, virtual dispatch, `self` / `super`.
- Closures + capture analysis + heap-promoted cells.
- VM bump allocator (shared by classes + closures).
- Auto-deref on `r.field` / `r.method()` (rides with struct
  + class field codegen).
