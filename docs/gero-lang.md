# Gero Language — Spec

The high-level language that compiles to [Gero bytecode](./isa.md).
Source file extension `.gr`. Compiler is a Zig program in this repo
(`src/lang/`).

The language reads like Lua / BASIC, types at the variable + function
boundary, integer-only arithmetic, compiles to gero bytecode. Designed
for J-RPG-class games and similar carts; see §1 for the philosophy.

---

## 1. Philosophy

- **Reads like Lua / BASIC** — `let`, `do … end`, `if … end`,
  `print`. Familiar to anyone who's touched a teaching language.
- **No block keywords mid-statement** — no `then` after `if`, no `do`
  after `while` / `for`. The newline ends the head; the body starts
  on the next line. Less noise, fewer cumulative `end`s to read past.
- **No semicolons** — statement boundaries are newlines. Cheap to
  type, less visual noise. (Modern Lua, Go, Python convention.)
- **Mutable `let` by default** — `let x = 0` is mutable, `const X = 0`
  is immutable. Style follows Lua / JS / BASIC, not Rust / Swift.
  This is a deliberate choice for the teaching-language audience the
  syntax targets; the cost is a small friction for devs arriving from
  Rust/Swift where `let` means immutable.
- **Typed at the variable / function boundary** — every `let` /
  parameter / return type gets an annotation OR is inferred from
  context. Once compiled, types are erased — runtime is fully
  dynamic-feeling but the compiler enforces consistency.
- **Imports are first-class modules** — `use math`, files cleanly
  separated, functions exported by default.
- **Compiles to gero bytecode** — strings live in static data,
  functions become labels + `call` / `ret`, classes get vtables, all
  arithmetic is integer (16-bit by default).

The language exists to make J-RPG-class games (and similar) writable
without dropping to assembly. Everything in the spec answers to that
goal.

---

## 2. Lexical structure

### 2.1 Whitespace

Spaces and tabs are insignificant within a line. **Newlines terminate
statements** (no semicolons). Blank lines are allowed anywhere.

To continue a long expression onto the next line, wrap it in
parentheses:

```
let total = (
  player.hp +
  player.mp
)
```

Inside any open `( … )`, `[ … ]`, or `{ … }` group, newlines are
ignored — so multi-line argument lists, array / struct / tuple
literals, and parameter declarations wrap naturally. Outside those
groups, a newline ends the current statement; trailing-operator
continuation (`a +\n  b`) is **not** a line-continuation rule.

The one exception lives outside the bracket families: a `.` at the
start of the next line continues the postfix chain on the previous
expression (§4.6.3). That's the only newline-significant carve-out
in the otherwise strict newline-terminated grammar.

### 2.2 Comments

```
-- single-line comment to end of line
```

No block comments. (Lua-style.) Match the asm `;` family by spirit
but use Lua's `--` since we're in a high-level context.

### 2.3 Identifiers

`[A-Za-z_][A-Za-z0-9_]*`, case-sensitive.

Convention:
- `lowercase_with_underscores` for variables and functions
- `UPPERCASE` for constants
- `PascalCase` for types and classes

The compiler doesn't enforce — convention only.

### 2.4 Numeric literals

| Form | Example | Type |
|------|---------|------|
| Decimal | `42`, `1000` | `int` (= `i16`) by default |
| Hex | `$FF`, `$ABCD` | `int`. `$` prefix only — retro 6502/Z80 style. |
| Binary | `0b1010_0101` | `int`. Underscores allowed for readability. |
| Negative | `-1` | `int` (unary minus operator) |

No floating-point literals — gero VM is integer-only. For fractions
use the `fixed` type (8.8 fixed-point — see §3.3).

The lexer disambiguates `$FE40` (hex literal) from `$(expr)` (string
interpolation, §3.2.2) by lookahead: digit / hex-letter after `$` →
literal; `(` after `$` → interpolation marker.

### 2.5 String literals

```
let greeting = "Hello, world!"
let path = "level/town/intro"
```

Escape sequences: `\n` `\t` `\r` `\0` `\\` `\"` `\xHH`.

`\0` is the null byte — useful for emitting terminators inside
non-terminated buffers, or interop with C-style APIs.

Strings are stored as null-terminated byte arrays in static data;
the variable holds a 16-bit pointer to the start. Mutating a string
literal is undefined (it lives in ROM at runtime).

#### 2.5.1 Char literals

Single-quoted single-byte literals are sugar for their ASCII value:

```
let c: u8 = 'A'              -- $41
let nl: u8 = '\n'            -- $0A
if s.at(0) == 'A'            -- byte compare reads naturally
  ...
end
```

The token's type is `u8`. Same escape table as strings (`\n` `\t`
`\r` `\0` `\\` `\'` `\xHH`). `'A'` and `$41` compile to identical
bytecode — char literals exist purely for source readability. Mirrors
the asm spec's `'A'` (asm §1.4) so byte literals look the same across
both languages.

### 2.6 Keywords (reserved)

```
let const def lambda return
if else end
while for in step
match case when
class extends self super
enum is
use from as local
true false nil
and or not
break continue defer
print
asm bake
```

`then` after `if`/`elif` and `do` after `while`/`for` are **not**
keywords. The head expression ends at the newline; the body starts
on the next line. Writing `if cond then …` is a syntax error.

`asm` is a builtin statement (§4.11) for one-instruction inline
assembly. `bake` marks a `def` or `do`-block for compile-time
evaluation (§3.8).

`and`, `or`, `not` are the boolean operators (short-circuit). The
bitwise counterparts use symbolic operators `&` `|` `^` `<<` `>>`
`~` (§4.2.1).

### 2.7 Annotations

Identifiers prefixed with `@` are **compile-time annotations** on
the declaration that follows. They live separately from the keyword
namespace (so adding new ones doesn't break existing code).

See §3.7 for the canonical list.

---

## 3. Type system

### 3.1 Primitive types

| Type | Width | Range |
|------|-------|-------|
| `i8`  | 1 byte | -128..127 |
| `u8`  | 1 byte | 0..255 |
| `i16` (alias `int`) | 2 bytes | -32768..32767 |
| `u16` (alias `uint`) | 2 bytes | 0..65535 |
| `bool` | 1 byte | `false`=0, `true`=1 |
| `nil` | 0 bytes | unit type, the empty value |

`int` / `uint` are the defaults — `let x = 0` gives `int`.

### 3.2 String type

`str` — immutable, null-terminated, lives in static data. Variables
hold a 16-bit pointer.

```
let s: str = "hello"
```

Mutable byte buffers are `[u8; N]` (fixed size).

#### 3.2.1 String operations

| Form | Returns | Allocates? |
|------|---------|------------|
| `a + b`           | `str` (concatenation) | **Yes** — new buffer in `state.allocator` |
| `s.len`           | `u16` (byte count, excluding `\0`) | No |
| `s.at(i)`         | `u8` (byte at index `i`) | No. Bounds-check at runtime; out-of-bounds → fault vector `$02`. |
| `s == other`      | `bool` (lexicographic equality, byte-wise) | No |
| `s != other`      | `bool` | No |
| `s < other` etc.  | `bool` (lex ordering) | No |
| `s.slice(a, b)`   | `str` (substring view, exclusive end) | No — borrowed view; lifetime ≤ `s`'s. |

Allocation lives in the parse / runtime allocator (typically the
gero VM's general-purpose allocator). Long-lived dynamic strings
should be copied into a `[u8; N]` buffer if they need to outlive the
allocator's scope.

For string building in tight loops, prefer pre-sized `[u8; N]`
buffers + manual writes via `mem.poke` over `+` chains — `+`
allocates fresh on every concat.

#### 3.2.2 String interpolation & format specs

Embed expressions directly in string literals via `$(expr)` —
Lua/Kotlin-style interpolation with optional Python-style format
specs after `:`.

```
let s = "hello, $(name)"
let h = "hp = $(self.hp)/$(self.max_hp)"
let a = "addr = $(addr:04X)"             -- 4-char hex, uppercase, zero-padded
let r = "$(player.name) hits for $(damage:3d) damage"
let p = "$(percent:>3d)% complete"        -- right-aligned in 3 chars
```

**Substitution syntax:**
- `$(expr)` — embed `expr`'s value, formatted with the type's default
- `$(expr:fmt)` — embed with explicit format spec
- `$$` — literal `$` (escape)

**Format spec grammar** (subset of Python's spec):

```
[align][fill][width][.precision][type]
```

| Field | Values | Meaning |
|-------|--------|---------|
| `align` | `<` `>` `^` | Left / right / center align (default: right for numbers, left for strings) |
| `fill` | any char | Padding char (default: space; `0` after width means zero-pad numbers) |
| `width` | digits | Minimum field width |
| `precision` | `.N` digits | For fixed-point: fraction digits; for strings: max length |
| `type` | `d` `x` `X` `b` `o` `s` `c` | Integer decimal / hex (lower/upper) / binary / octal / string / single ASCII char |

Common idioms for old-school output:

```
"$(addr:04X)"   -- 04F2 (hex address, 4 digits, zero-padded, uppercase)
"$(n:3d)"       -- "  42" (decimal, padded to 3 chars right-aligned)
"$(n:03d)"      -- "042" (decimal, padded to 3 chars with zeros)
"$(s:10s)"      -- "hello     " (string, 10 chars, default left-align)
"$(b:08b)"      -- "10110100" (binary, 8 bits, zero-padded)
```

**Compilation:**
- The compiler parses interpolation strings at compile time.
- Static parts compile to literal byte runs.
- `$(expr)` calls a stdlib formatter for the type, writing into an
  output buffer.
- The whole interpolated string allocates **once** in
  `state.allocator` (vs the chain of allocs `+` would produce).
- For `print "$(x) is $(y)"` — no string allocation; the runtime
  prints each piece sequentially via the host syscall.

For full programmatic formatting (when the format string isn't a
literal), use `format(fmt: str, args...)` from the `str` stdlib —
same spec language, runtime-evaluated. Allocates the result.

### 3.3 Fixed-point type

`fixed` — 8.8 fixed-point (16-bit storage, 8 bits integer + 8 bits
fraction). Range ±127.99…, precision 1/256.

```
let v: fixed = 1.5    -- compiles to $0180
let dx: fixed = 0.125 -- compiles to $0020
```

Standard arithmetic operators work transparently:

- `+` / `-` compile to plain `add` / `sub` (binary point is
  preserved by alignment, no scaling needed)
- `*` compiles to `mul` followed by `shr 8` to renormalize the
  binary point
- `/` compiles to `shl 8` followed by `div`

The user never sees the scaling. Cycle count is the same as a
hypothetical native fixed-point op (a hardware multiplier doesn't
care about the binary point — the work is identical).

For clamping at fixed-point boundaries (e.g. don't let HP go
negative or exceed `MAX_HP`), use `math.clamp(value, lo, hi)`
from stdlib — compiles to `cmp` + branch sequence. The ISA has
no native saturating ops (deliberate; see ISA §5.4.1).

This is the canonical answer for "I need fractions" — same trick
PICO-8, Sonic, early Doom used.

### 3.4 Compound types

| Form | Example | Notes |
|------|---------|-------|
| Array (fixed-size) | `[u8; 64]` | N is comptime. Stack-allocated if local. |
| Dynamic array | `Vec(i16)` | Growable buffer with `push` / `pop` / `len` / `at`. See §3.4.3. |
| Tuple | `(i16, str)` | Anonymous heterogeneous pair / triple / etc. Max 4 elements (5+ → use a struct). Destructurable in `let` and `match`. Field access via `.0`, `.1`, …. |
| Optional | `T?` | Nullable pointer type — see §3.4.1. |
| Reference | `&T` | Borrowed reference, no arithmetic. See §3.4.4. |
| Function | `fn(i16, i16) -> i16` | First-class — assignable, passable. |
| Struct | `struct Foo a: i16, b: u8 end` | C-style POD. Fields contiguous in memory, no methods. See §3.4.2. Literal: `Foo { a: 1, b: 2 }`. |
| Class | `class Foo … end` | Vtable + fields, methods, single inheritance. See §6. |

#### 3.4.1 Nullable types `T?`

The `T?` annotation marks a binding as **nullable** — it may hold
the special value `nil` representing absence. Restricted to
**pointer-like types** (`str`, class instances, function pointers).
Numeric / value types use **sentinel constants** instead (the
6502/Z80 / Lua idiom).

```
let s: str?    = nil          -- nullable string, currently absent
let p: Player? = find_player()  -- may return nil
let n: i16     = 0            -- not nullable; use a sentinel for "absent"

const NOT_FOUND: i16 = -1     -- conventional sentinel for absent index
```

**Layout** = `sizeof(T)`. The value `$0000` is the canonical `nil`
representation (since pointer types use `$0000` as their natural
null), so no tag byte is needed.

**Testing for nil:**

```
if p != nil
  p.greet()           -- safe — flow analysis carries non-nil through
end

if p == nil
  return
end
p.greet()             -- safe here too
```

**Dereferencing a nullable.** Direct method/field access on a `T?`
value compiles with a runtime nil-check that faults via vector
`$02` if the value is `nil`. The compiler **statically requires
a nil-check** in obvious cases — uncheck-then-deref in straight-line
code is a compile error:

```
let p: Player? = find_player()
p.greet()             -- compile error: dereferencing nullable without nil-check
```

This is Lua-style with a small lift toward static safety. No `Option`
enum, no `Some` / `None` patterns, no `?` propagation operator —
just `nil` and explicit checks. Old-school authentic.

**Fallible operations** that need to surface an error reason use
**multi-return tuples** (Go-style) instead of a `Result` type:

```
def parse_int(s: str) -> (i16, str?)
  if s.len == 0
    return (0, "empty input")
  end
  -- ...
  return (value, nil)
end

let (n, err) = parse_int(input)
if err != nil
  log(err)
  return
end
use(n)        -- compiler tracks: on this path err was nil,
              -- so n came from the success arm and is valid
```

The `str?` second slot is the error message when present, `nil` on
success. Idiomatic in Lua, Go, and most pre-Rust runtimes.

**Flow analysis.** The compiler tracks the relationship between a
multi-return tuple's slots so that the success path doesn't pessimize
into the error path. Specifically, when the source has the shape

```
let (value, err) = produces_value_or_error()
if err != nil
  -- bail path (return / break / continue / @noreturn call)
end
-- here: err is statically nil, value came from the success arm
```

the compiler treats `value` as definitely valid after the bail
branch — no second check needed. The same applies to `if err ==
nil then …` (truthy branch sees the success path) and to `match`
with explicit `nil` / non-`nil` arms.

The analysis works on the **most-recent assignment** of `err`: if
the user reassigns `err` between the check and the use, the
guarantee evaporates. This is intentional — same shape as Go's
or Lua's idiom; no implicit linear typing.

#### 3.4.2 `struct` vs `class` — when to use which

Both define a compound type, but the cost and contract differ. Pick
based on **what the value represents**, not what feels like more
features.

| Aspect | `struct` | `class` |
|--------|----------|---------|
| Methods | None — pure data | Yes, dispatched via vtable |
| Inheritance | None | Single inheritance + `extends` |
| Memory cost | Sum of field bytes | 2-byte vtable pointer + sum of field bytes |
| Construction | Literal: `Stats { hp: 100, mp: 30, ... }` | Constructor call: `Player("Cecil")` (calls `init`) |
| Passing semantics | By value (copied at assignment / arg passing) | By reference (vtable pointer copied; instance shared) |
| Identity | None (structurally equal if fields equal) | Yes (two `Player` instances are distinct even with equal fields) |
| Use case | "value" — stats, position, range, span, color | "entity" — player, monster, scene, game-state |

**Rule of thumb:** if you write methods or use `extends`, it's a
`class`. Otherwise `struct`.

The cost difference matters on a 16-bit target — an array of 100
`Stats` structs is 600 bytes; the same as a class would be 800
bytes. Make this trade-off explicit at declaration so reviewers
can see the cost in the source.

```
-- 6-byte values, copy-on-pass, no behavior
struct Stats
  hp: i16
  mp: i16
  atk: u8
  def: u8
end

let s = Stats { hp: 100, mp: 30, atk: 12, def: 8 }   -- literal

-- 8+ byte instances (vtable + fields), shared by reference
class Player extends Entity
  let name: str

  def init(self, name: str)
    super.init(0, 0)
    self.name = name
  end

  def greet(self)
    print "hi, ", self.name
  end
end
```

**Struct definitions vs literals.** Definitions use `end`-style
delimiters consistent with the rest of the language; literal
construction uses `{ ... }` because it's an expression form (matches
how `Player(...)` is a class-constructor call):

```
-- Definition
struct Stats
  hp: i16
  mp: i16
  atk: u8
  def: u8
end

-- Literal construction (an expression)
let s = Stats { hp: 100, mp: 30, atk: 12, def: 8 }
```

Trailing comma after the last field is optional in both forms.

#### 3.4.3 `Vec(T)` — dynamic array

Fixed-size arrays (`[T; N]`) are stack-allocated and their length
is comptime. When the data is intrinsically variable-length — an
inventory that grows, an event queue, a scratch buffer — use
`Vec(T)` instead.

```
let inv: Vec(Item) = Vec.new()             -- empty, cap = 0
let buf: Vec(u8)   = Vec.with_capacity(64) -- empty, cap = 64
let xs: Vec(i16)   = Vec.from([1, 2, 3])   -- pre-filled from a fixed array
```

**Operations:**

| Form | Returns | Notes |
|------|---------|-------|
| `v.push(x)`        | `nil` | Append; grows the backing buffer (doubles cap) when full. Amortized O(1). |
| `v.pop()`          | `T?` | Remove + return the last element. `nil` when empty. |
| `v.len()`          | `u16` | Current element count. |
| `v.cap()`          | `u16` | Current backing capacity. |
| `v.at(i)`          | `T` | Bounds-checked. Out-of-range → fault vector `$02`. |
| `v.get(i)`         | `T?` | Safe variant — `nil` instead of fault. |
| `v.set(i, x)`      | `nil` | Bounds-checked write. |
| `v[i]` / `v[i] = x` | `T` / `nil` | Sugar for `at` / `set`. |
| `v.clear()`        | `nil` | `len ← 0`, keeps the backing buffer. |
| `v.slice(a, b)`    | `Vec(T)` | Borrowed view, lifetime ≤ `v`'s. Mutating the slice mutates the parent. |

`Vec(T)` participates in `for-in`:

```
for item in inv
  use(item)
end
```

**Layout** = 6 bytes per `Vec` value: `(ptr: *T, len: u16, cap: u16)`.
The backing buffer lives in the VM's general-purpose allocator. Reads
and writes on a moved-from `Vec` are undefined.

**Generics scope.** `Vec(T)` is a compiler-known built-in (same status
as `Range` and `[T; N]`) — there are no user-defined generic types
or functions. If you need a typed container beyond `Vec`, build a
class around `[T; N]` or `Vec(T)` with the right operations.

#### 3.4.4 References `&T`

A reference is a 16-bit address bound to a typed slot. References
exist for two reasons on a 16-bit cart target:

1. **Avoid copying compound values** at function-call boundaries.
   Passing a `Stats` struct (6 bytes) by value copies 6 bytes on every
   call. Passing `&Stats` copies 2 bytes (the address) and the callee
   mutates in place.
2. **Compose with the asm escape hatch and MMIO setup** — getting the
   address of a stack-local buffer to pass to a DMA register or an
   `asm "..."` block.

**Syntax.**

```
def apply_damage(stats: &Stats, dmg: i16)
  stats.hp = stats.hp - dmg     -- mutates the referenced struct
end

let s = Stats { hp: 100, mp: 50, atk: 10, def: 5 }
apply_damage(&s, 20)             -- prefix `&` to take a reference
print s.hp                       -- 80 (mutation visible)
```

The `&` prefix produces a reference; the callee's parameter type is
`&T`. References auto-deref for field access and method calls
(`stats.hp`, `stats.method()`) — no explicit `*` deref operator.

**Mutability.** A reference is always mutating through the binding.
There is no `&const T` / `&mut T` distinction (no borrow checker in
gero-lang). To document "read-only", pass by value (with the copy
cost) or follow a naming convention. The trade-off is intentional:
the borrow checker adds compile-time complexity that the target
audience doesn't need and the cart target doesn't reward.

**Lifetime.** A reference is valid as long as the binding it points
at is in scope. Returning `&local` from a function (where `local` is
a stack binding) is a compile error — the compiler tracks
stack-vs-static origin to reject the obvious cases:

```
def bad() -> &Stats
  let s = Stats { hp: 0, mp: 0, atk: 0, def: 0 }
  return &s          -- COMPILE ERROR: returns ref to stack-local
end

let static_s = Stats { ... }
def ok() -> &Stats
  return &static_s   -- OK: static binding outlives any caller
end
```

The compiler does **not** track cross-call lifetimes (no full borrow
checker). Storing a reference inside a class field and outliving the
referent is undefined behavior — discipline at the source level.

**Restrictions.**

- No reference arithmetic (`&x + 1` is a compile error).
- No `&&T` (reference-to-reference).
- No reference to a temporary (`&(a + b)` is a compile error — there
  is no addressable storage for the temporary).
- A reference parameter cannot be `nil` — use `&T` for "always
  present, mutate this", or use `T?` (nullable pointer) for "may be
  absent".

**Layout.** 2 bytes (a 16-bit pointer). Same runtime cost as a class
instance reference.

For raw byte-level address arithmetic (the rare cases where you
genuinely want a `u16` address value — DMA setup, manual MMIO setup,
`asm "..."` bridge), use `mem.addr_of(x) -> u16` (§5.3). That returns
the address as a plain integer; it's the explicit "I want bytes,
not a typed reference" escape hatch.

### 3.5 Inference

Type annotations are **optional everywhere** the compiler can deduce
them. Annotate when you want precision, public-API clarity, or
better error messages — skip when the type is obvious from context.

```
let x = 0          -- inferred int
let s = "hi"       -- inferred str
let p: i16? = nil  -- explicit because nil alone has no type

def greet(name)              -- params + return inferred from call sites
  print "hi, " + name
end

def precise(x: i16) -> i16   -- annotations available when useful
  return x * 2
end
```

Inference rules:

- **`let`** initializer's type is the binding's type. If only `let
  x: T` (no init), `T` is required.
- **Function params + return** are inferred from call sites and
  body usage. If a function is called with multiple incompatible
  types (one call passes `i16`, another passes `str`), the compiler
  errors with "ambiguous; add explicit annotation".
- **Recursive functions** must annotate the return type — the
  compiler can't infer through self-reference. Params can still
  be inferred from initial call sites.
- **Public-API functions** (exported, called from another module)
  benefit from explicit annotations — error messages at call sites
  point at named types instead of inferred-from-context.

Style convention: annotate functions in stdlib, public modules, and
anywhere the type's intent matters more than terseness. Skip in
private helpers and obvious cases.

#### 3.5.1 Type casts

When inference can't bridge a type gap — narrowing, widening, or
crossing the integer / `fixed` boundary — use `as` to force the
conversion:

```
let small: u8 = (raw & $FF) as u8
let wide:  i16 = byte_count as i16
let pixel: u8 = palette[i] as u8
let dx:    fixed = velocity as fixed     -- top byte = velocity, frac = 0
let vx:    i16 = (player.vx_fixed) as i16  -- truncate frac toward zero
```

**Conversion rules:**

| From → To | Behavior |
|-----------|----------|
| Narrower integer (`i16` → `u8`) | Two's-complement truncation — keep the low byte. |
| Signed wider (`i8` → `i16`) | Sign extension. |
| Unsigned wider (`u8` → `u16`) | Zero extension. |
| `bool` → integer | `false=0`, `true=1`. |
| Integer → `bool` | `0 → false`, anything-else → `true`. |
| `fixed` → integer | Round toward zero — truncate the fractional byte. |
| Integer → `fixed` | Top byte = integer value, fraction byte = 0. |
| `u8` ↔ char | No-op — same byte, just the type changes. |

**Not supported** (no syntax to express, compile error):

- Reference-type casts (`str` ↔ class, `Vec(i16)` ↔ `Vec(u16)`).
- Class ↔ class downcasts. Use `match` with the enum / class
  tag instead.
- Function-pointer reinterpret. Function types are opaque.

**Precedence** (§3.3): `as` binds tighter than `is` but looser than
unary prefix. `x + y as u8` parses as `x + (y as u8)`. `x as u8 + 1`
parses as `(x as u8) + 1`. Use parentheses when in doubt — the spec
won't get less surprising the longer you stare at it.

### 3.6 Enums (tagged unions)

Sum types — a value is exactly one of N variants, each variant
carrying its own optional payload. The compiler enforces
exhaustiveness at `match` sites.

```
enum Item
  case Sword
  case Potion(amount: i16)
  case Key(name: str, count: u8)
end
```

Instantiation (variant constructors are functions):

```
let s = Item.Sword
let p = Item.Potion(20)
let k = Item.Key("brass", 1)
```

Memory layout: 1-byte tag (discriminant) + payload bytes sized to the
**largest** variant. For `Item` above:
- `Sword` payload = 0 bytes
- `Potion(i16)` = 2 bytes
- `Key(str, u8)` = 3 bytes (2-byte ptr + 1 byte)
- Total slot size = 1 + max(0, 2, 3) = **4 bytes**

Tags numbered in declaration order (`Sword=0`, `Potion=1`, `Key=2`).
The compiler may re-order to pack better but the on-disk encoding is
documented per program.

Use `is` for variant-tag tests (binding-free):

```
if item is Item.Sword
  equip_basic()
end
```

For payload extraction, use `match` (§4.8).

### 3.7 Annotations

`@`-prefixed directives that decorate the declaration on the next
line. They're a controlled escape hatch into compiler / linker
behavior — small, declarative, no general-purpose macros.

Multiple annotations stack. Order matters only when explicitly noted.

#### 3.7.1 Memory placement

| Annotation | Applies to | Effect |
|------------|------------|--------|
| `@bank N` | `def`, `let`, `const`, **file** | Place compiled output in bank `N` (compiler emits cross-bank trampolines for calls — §7.3). See precedence note below. |
| `@zero_page` | `let` | Place this global in the zero-page region (`$0000..$00FF`) — 1-byte addressing mode, faster + smaller code. Slot pressure is high (256 bytes shared); compiler errors on overflow. |
| `@addr $1234` | `let` | Pin this global at the given absolute address. Use for binding to memory-mapped IO registers or fixed-position state. The compiler reserves no other RAM at that address. |
| `@volatile` | `let` | Treat every read of this binding as a real memory load (never cached in a register). Pair with `@addr` for memory-mapped IO registers whose value changes outside the compiler's view (vblank flag, input port, RNG tap). |
| `@align(N)` | `let`, `const`, `struct` | Force `N`-byte alignment of the placement. `N` must be a power of two (1, 2, 4, 8, 16, …). Necessary when the hardware demands aligned data — sprite sheets at 16-byte boundaries, tile maps at page boundaries (256), audio buffers at 4 bytes. |

**`@bank` precedence.** `@bank N` may appear at either:
- **File scope** — the first non-comment token in a `.gr` file.
  Applies to every declaration in the file unless overridden.
- **Declaration scope** — directly above a `def` / `let` / `const`.
  Applies to that declaration only.

Per-declaration `@bank` always wins over the file-level default. A
declaration inside a file with `@bank 5` at the top can opt out
back to the base image with `@bank 0`. Declarations that appear
without any `@bank` annotation (and no file-level default) land
in the base image (bank-less area before `$C000`).

```
@zero_page
let cursor_pos: u16 = 0      -- fast access, e.g. updated 60×/sec

@addr $FE40
@volatile
let DISPCTL: u8 = 0          -- bound to gtx-16 display-control IO register

@align(16)
@addr $C000
let sprite_sheet: [u8; 2048] -- aligned tile data, banked window

@bank 5
def town_intro_dialog() -> str
  return "Welcome to Mistwood..."
end
```

#### 3.7.2 Codegen control

| Annotation | Applies to | Effect |
|------------|------------|--------|
| `@inline` | `def` | Always inline at call sites. Compile error if the function is recursive or its lowered body exceeds **32 bytecode instructions**. |
| `@cold` | `def` | Mark the function as unlikely-called. Codegen emits all `@cold` functions of a module **after** every non-cold function, in source-declaration order. Bytecode placement is deterministic and reproducible across compiler versions. |
| `@no_capture` | `def` | Forbid this function from defining any closure that captures-and-mutates a binding from its lexical scope. See §4.7.2 (closures auto-promote to heap when they mutate captures; `@no_capture` forces a compile error instead so cycle-critical functions can't pay that cost by accident). |

```
@inline
def fast_clamp(x: i16, min: i16, max: i16) -> i16
  if x < min
    return min
  end
  if x > max
    return max
  end
  return x
end

@cold
def panic_oob(addr: u16) -> noreturn
  print "PANIC: out-of-bounds @ ", addr
  hlt
end

@no_capture
def hot_render_loop(state: &GameState)
  for sprite in state.sprites
    let draw = |s| blit(s)        -- read-only capture: OK
    draw(sprite)
  end
end
```

`@inline` attaches to named `def`s only. Lambdas already inline
when they don't escape (their body folds into the caller); when
they do escape they become first-class values and inlining would
defeat that — there's no useful middle ground to expose via
annotation. The 32-instruction limit is on the function body **after
lowering** (post-typecheck, pre-codegen). The limit is fixed across
compiler versions so source that compiles today keeps compiling.

`@cold` placement is deterministic: each module's compiled output is
laid out as `[hot fn 1, hot fn 2, …, cold fn A, cold fn B, …]`. The
relative order of hot functions matches source order; the relative
order of cold functions matches source order. Same input source →
same byte layout, every time, every compiler version. The cost is one
extra branch on the rare hot-to-cold call; the win is a denser hot
path.

`@no_capture` is a compile-time-only check. A function annotated with
it can still **define** closures, and those closures can still
capture read-only — the only thing rejected is capture-and-mutate
(which is what triggers the heap promotion). The check runs after
typechecking, before codegen. Useful on per-frame game loops and ISR
helpers where a hidden alloc is unacceptable.

#### 3.7.3 Diverging functions

| Annotation | Applies to | Effect |
|------------|------------|--------|
| `@noreturn` | `def` | Asserts the function never returns normally (it must `hlt`, infinite-loop, or call another `@noreturn`). The compiler treats calls as diverging — usable in `match` bail arms with otherwise non-exhaustive shape. The return type, if specified, must be `noreturn`. |

```
@noreturn
def panic(msg: str) -> noreturn
  print "PANIC: ", msg
  hlt
end

def use_potion(item: Action)
  match item
    case Action.Heal(n) => heal(n)
    case _              => panic("not a healing item")
  end
end
```

`noreturn` is a special return type — only `@noreturn` functions
may declare it. It's not a value type; you can't have a variable
of type `noreturn`.

Module-level visibility is controlled by the `local` keyword
(§5.1) — declarations are exported by default, prefix with
`local` to keep private. Class-member visibility uses `@private`
(§3.7.6).

#### 3.7.4 Interrupt handlers

| Annotation | Applies to | Effect |
|------------|------------|--------|
| `@interrupt N` | `def` | Bind this function as the handler for vector `N` (gero ISA §6.1). The compiler emits the `rti` epilogue automatically and writes the function address into `mem[$1000 + 2 * N]` at boot. The function body must take no parameters and return nothing. |

```
@interrupt $06              -- vblank
def on_vblank()
  frame_count += 1
end

@interrupt $21              -- save-flush convention
def on_save_request()
  flush_save_state()
end
```

#### 3.7.5 Test & bench markers

| Annotation | Applies to | Effect |
|------------|------------|--------|
| `@test` | `def` | Mark as a unit test. Excluded from release builds; collected and run by `gero test`. |
| `@bench` | `def` | Mark as a benchmark. Excluded from release builds; collected and run by `gero bench`. The runner executes the function N times (default 1000) and reports avg cycle count + min/max. Useful on a 16-bit target where every cycle on a hot path matters. |

```
@test
def damage_floor_is_one()
  let weak   = Stats { hp: 1, mp: 0, atk: 1, def: 100 }
  let strong = Stats { hp: 100, mp: 0, atk: 10, def: 0 }
  assert(damage(weak, strong, 0) == 1, "raw negative should clamp to 1")
end

@bench
def bench_damage_calc()
  let a = Stats { hp: 100, mp: 0, atk: 50, def: 10 }
  let t = Stats { hp: 100, mp: 0, atk: 5,  def: 30 }
  damage(a, t, 100)
end
```

Both annotations gate the function out of release builds — they're
only compiled in test or bench profile. No runtime cost in the
shipped `.gx`.

#### 3.7.6 Object-oriented design

OOP-specific annotations on classes and their members. Default
visibility is **public** — no `@public` needed.

| Annotation | Applies to | Effect |
|------------|------------|--------|
| `@override` | method `def` | Asserts this method overrides one in the parent class. Compile error if no parent declares it (catches name typos). |
| `@final` | `class`, method `def` | **Class:** can't be `extends`-ed. **Method:** can't be overridden in subclasses. Both enable devirtualization (the compiler can inline the call bypassing the vtable lookup). |
| `@abstract` | method `def`, `class` | **Method:** declared without a body; subclasses MUST implement it. **Class:** cannot be instantiated directly. A class containing any `@abstract` method is implicitly `@abstract`. |
| `@static` | method `def` | Class-level method — no `self` parameter, called as `Foo.bar()`. Compiles to a plain function (no vtable). |
| `@private` | method `def`, field `let` | Visible only inside the class body. Subclasses don't see it. |

Worked example:

```
@abstract
class Entity
  let x: i16
  let y: i16

  def init(self, x: i16, y: i16)
    self.x = x
    self.y = y
  end

  @abstract
  def update(self)

  @final
  def position(self) -> (i16, i16)
    return (self.x, self.y)
  end

  @static
  def from_origin() -> Entity
    return Entity(0, 0)
  end
end

@final
class Player extends Entity
  @private
  let _hp: i16

  def init(self, x: i16, y: i16, hp: i16)
    super.init(x, y)
    self._hp = hp
  end

  @override
  def update(self)
    handle_input(self)
  end
end
```

The compiler enforces:
- `Entity()` is rejected (abstract class)
- `class Boss extends Player` is rejected (Player is `@final`)
- `Player.position` calls inline directly (`@final` on the method)
- `player._hp` access from outside `Player` is rejected (`@private`)

#### 3.7.7 Inline assembly

Inline asm is not an annotation — see §4.11 for the `asm "..."`
statement form.

### 3.8 Compile-time evaluation (`bake`)

`bake` marks a `def` or `do`-block for **compile-time evaluation**.
The compiler runs the marked code at compile time and bakes the
result into static data — no runtime cost, no runtime code emitted
for the baked computation itself.

This is the canonical way to generate lookup tables (sin/cos,
palette ramps, RNG seeds, mip levels) without hand-encoding the
bytes, and without a separate build script that emits `.gr` files.

```
bake def make_sin_table() -> [i16; 256]
  let t: [i16; 256] = [0; 256]
  for i in 0..256
    t[i] = fixed_sin(i * 360 / 256)
  end
  return t
end

const SIN_TABLE = make_sin_table()
-- 512 bytes of static data; no runtime cost
```

`bake do` is the same idea inline, without a named function:

```
const PALETTE = bake do
  let p: [u8; 16] = [0; 16]
  for i in 0..16
    p[i] = ramp_to_palette(i)
  end
  p
end
```

**Restrictions on bake bodies.** The bake interpreter is a strict
subset of the runtime:

- **No MMIO access.** Reading or writing a binding annotated `@addr`
  is a compile error inside `bake` code. The hardware doesn't exist
  at compile time.
- **No `asm "..."` statements.** Same reason — no VM at compile time.
- **No `@interrupt` handlers triggered.** Bake runs in a pure
  evaluator with no scheduler.
- **No calls to non-`bake` functions** except a curated set of pure
  stdlib helpers (`math.*` arithmetic + fixed-point routines). The
  compiler errors on calls to functions it can't prove
  side-effect-free. Other `bake` functions can call each other freely.
- **No `mem.*` raw memory access** — `read_*`, `write_*`, `memcpy`,
  `memset`, `peek`, `poke`, `addr_of` all have no compile-time
  meaning. Bake code operates on language-level values only.
- **No `defer`, no `@volatile`.** Both are runtime-only concepts.
- **`const` references and literals** are readable freely.

The bake interpreter is finite: it has an instruction budget
(default: 100 million micro-steps) to prevent infinite loops at
compile time. Exceeding the budget is a compile error with a
diagnostic pointing at the source.

**Output types.** Any value that has a constant runtime
representation can be baked: `[T; N]`, tuples, structs containing
only bakeable fields, primitive integers, `bool`, `str` (interned in
static data). Classes are **not** bakeable — vtable pointers can't
be resolved until link time. `Vec(T)` is not bakeable either (heap
allocation has no compile-time meaning); use `[T; N]` instead.

**Lifetime.** A baked value is in static data, just like a string
literal. It lives in ROM at runtime and cannot be mutated. Assigning
to a `let` initialized from a `bake` result copies the bytes into a
mutable location:

```
const READONLY_TABLE = bake make_sin_table()      -- in ROM
let scratch_table = bake make_sin_table()         -- copied to mutable slot

READONLY_TABLE[0] = 1   -- COMPILE ERROR: bake result is const
scratch_table[0] = 1    -- OK
```

The `bake` keyword cannot be combined with `@cold`, `@inline`,
`@interrupt`, `@bank`, or `@no_capture` — those describe runtime
codegen and have no meaning for compile-time evaluation.

---

## 4. Statements

### 4.1 Variable declaration

```
let name = expr               -- mutable, inferred type
let name: T = expr            -- mutable, explicit type
const name = expr             -- immutable binding (compile-time inlined when possible)
```

**`let`** is a mutable binding. Reassign freely.

**`const`** is an **immutable binding**. Reassignment is a compile
error. Two flavors handled by the compiler:

- If the RHS is **comptime-evaluable** (literals + `const`-only
  arithmetic), the value is inlined at use sites with no runtime
  storage. This is the canonical case (`const MAX_HP = 100`).
- If the RHS depends on runtime values (`const player_name =
  read_input()`), the binding gets a stack/static slot but is
  read-only — you can't `player_name = "x"` later.

Same model as JavaScript / TypeScript `const`. Old-school BASIC's
`LET` was always mutable; we add `const` for the cases where intent
matters and the compiler can help catch reassignment bugs.

```
const PI_FIXED = $0324       -- comptime, inlined
const player_name = read_input()  -- runtime, but read-only
player_name = "x"             -- compile error: cannot reassign const
```

There is no `var` keyword and no `final let` — `let` mutable + `const`
immutable cover both ends without ambiguity.

#### 4.1.1 Destructuring let

The `let` binding accepts patterns on the left-hand side — same
patterns as `match` (§4.8.1):

```
let (x, y) = compute_position()
let Player { hp, mp } = active_player()
let Item.Potion(amount) = the_item    -- only valid if statically known to match
```

The pattern must be **infallible** for the type — destructuring an
enum variant in plain `let` is a compile error if the variant isn't
the only possibility. For fallible destructuring (you want to bail
out if the shape doesn't match), use `match` with an early-return:

```
match item
  case Item.Potion(n) => heal(n)
  case _              => return
end
```

### 4.2 Assignment

```
x = expr
x += expr   -- sugar for x = x + expr
x -= expr
x *= expr
x /= expr
x %= expr
x &= expr   -- bitwise AND
x |= expr   -- bitwise OR
x ^= expr   -- bitwise XOR
x <<= expr  -- shift left
x >>= expr  -- shift right

x++         -- statement only — sugar for x += 1
x--         -- statement only — sugar for x -= 1
```

**MMIO writes** — when `x` is a global annotated `@addr` (and
typically `@volatile`), assignment compiles to a real store at the
pinned address. No special syntax needed:

```
@addr $FE40
@volatile
let DISPCTL: u8 = 0

DISPCTL = $42        -- writes byte $42 to address $FE40
DISPCTL |= $80       -- read-modify-write through the pin
```

The `@volatile` annotation (§3.7.1) guarantees both reads and writes
are real memory operations (never cached in a register, never elided
by dead-store optimization).

`++` and `--` are **statements**, not expressions. They cannot be
nested inside another expression:

```
x++                    -- OK
items.count++          -- OK (works on any int field / index)

let y = x++            -- COMPILE ERROR: ++ is not an expression
foo(x++)               -- COMPILE ERROR: ++ is not an expression

let y = x; x += 1      -- write it like this if you need the prior value
```

The statement-only restriction avoids the C-style prefix-vs-postfix
ambiguity entirely — `++` always means "increment by 1 right here,
no value produced". Go uses the same rule.

#### 4.2.1 Operators (binary)

| Category | Operators | Notes |
|----------|-----------|-------|
| Arithmetic | `+` `-` `*` `/` `%` | `/` and `%` on signed → truncated toward zero. Overflow: trap in debug, wrap in release (see below). |
| Arithmetic (explicit wrap) | `+%` `-%` `*%` | Always wrap on overflow, in any build mode. Use when wrap is intentional (RNG step, hash mixing). |
| Arithmetic (saturate) | `+\|` `-\|` `*\|` | Clamp to the type's min/max on overflow, in any build mode. Use when saturation is the correct semantics (HP after damage, audio mix levels). |
| Comparison | `==` `!=` `<` `<=` `>` `>=` | All return `bool` |
| Logical | `and` `or` `not` | Short-circuit evaluation. `not` is unary. |
| Bitwise | `&` `\|` `^` `<<` `>>` `~` | Map directly to ISA `and` / `or` / `xor` / `shl` / `shr` / `not`. `~` is unary bitwise NOT. |
| Reference | `&` (prefix) | `&x` takes a typed reference to `x`. See §3.4.4. |
| Range | `..` `..=` | See §4.5. Produce range values (built-in special type). |
| Type test | `is` | `value is EnumVariant` — see §3.6. |
| Type cast | `as` | `value as T` converts between numeric types — see §3.5.1. |

**Overflow on plain arithmetic** (`+`, `-`, `*`):

- **Debug builds** (`gero build`, default): the compiler emits an
  overflow check. On overflow, the program traps via fault vector
  `$02` with a diagnostic pointing at the source location.
- **Release builds** (`gero build --release`): the check is elided
  and the operation wraps two's-complement. Use `+%` / `+|` to make
  the wrap or saturate intent explicit when the choice matters.

Saturating `+|` on signed types clamps to `[T::MIN, T::MAX]` of the
result type; on unsigned, clamps to `[0, T::MAX]`. The intermediate
computation uses one bit of extra width to detect the overflow cheaply
on the gero VM's add-with-carry.

**Precedence (highest to lowest):**

1. Unary prefix: `-` `not` `~` `&`
2. `as` (cast)
3. `*` `/` `%` `*%` `*|`
4. `+` `-` `+%` `-%` `+|` `-|`
5. `<<` `>>`
6. `&` (bitwise AND — context disambiguates from prefix `&`)
7. `^`
8. `\|`
9. Comparison: `==` `!=` `<` `<=` `>` `>=`
10. `is`
11. `and`
12. `or`
13. `..` `..=`
14. Assignment (`=`, `+=`, etc. — right-associative)

Wrapping (`+%`) and saturating (`+|`) operators share their plain
counterpart's precedence — they're not "promoted" relative to `+`.

Same precedence as C / Rust for bitwise vs comparison (low) and
shifts vs arithmetic (low). Use parens when in doubt — `if (flags &
MASK) == TARGET` reads better than relying on precedence memory.

#### 4.2.2 Discarding a value

Use `_` as the assignment target to evaluate an expression for its
side effects and discard the result:

```
_ = expensive_call()           -- explicitly ignore the return
_ = items.push(x)              -- ignore the new length
```

The compiler **errors** on a non-`nil` expression result that's not
assigned, used, or discarded. This forces side-effecting calls that
return a value to either capture it (`let x = …`) or explicitly
discard (`_ = …`) — no silent value loss.

### 4.3 Blocks

`do … end` is both a **statement** and an **expression**. Variables
declared inside go out of scope at `end`.

As a statement (no value used):

```
do
  let temp = compute()
  print temp
end
```

As an expression — the block evaluates to its **last expression**
(or `nil` if the last item is a statement):

```
let area = do
  let w = read_width()
  let h = read_height()
  w * h        -- no `return`, just a bare expression as last item
end
```

This is the natural shape for "compute a value with some scratch
state, then discard the scratch". It replaces the IILE pattern from
older lang families.

For `let` initializers that need `return` flow control (early-out,
recursion), use a regular `def` — `do … end` blocks don't catch
returns; `return` propagates to the enclosing function.

### 4.4 Conditionals

```
if cond
  body
end

if cond
  body
else
  other
end

if cond
  body
else if cond2
  other
else
  default
end
```

No parentheses around conditions, no `then` keyword. The condition
expression ends at the newline; the body starts on the next line.

#### 4.4.1 `if let`

Pattern-match in conditional position. Bindings introduced by the
pattern are in scope inside the truthy branch (and only there):

```
if let Item.Potion(n) = item
  drink(n)
end

if let Event.MouseClick(x, y) = e when x < 128
  hit_left(x, y)
end
```

Pattern syntax = §4.8.1; `when` guards are accepted (§4.8.2). When
the pattern doesn't match, the truthy branch is skipped (and `else`
runs if present).

### 4.5 Loops

```
while cond
  body
end

for i in 0..=10              -- inclusive 0..10
  body
end

for i in 0..10               -- exclusive (0..9)
  body
end

for i in 0..=100 step 5      -- explicit step
  body
end

for item in collection
  body
end
```

No `do` keyword after the head — the condition / range expression
ends at the newline, body starts on the next line.

`break` and `continue` work in any loop.

`0..=10` and `0..10` are first-class **range expressions**. They're
also valid `match` patterns (§4.8.1) and can be passed around as
values.

#### 4.5.1 Range values

Range expressions (`0..10`, `0..=10`, `0..=100 step 5`) are
first-class **built-in values** with the conceptual layout:

```
start: <int type>
end:   <int type>
step:  <int type>     -- 1 by default
inclusive: bool       -- true for ..=, false for ..
```

Ranges work over any integer type — `i8`, `u8`, `i16`, `u16`. The
inner type is the same as `start`'s type; `end` and `step` are
checked to match. Runtime slot: 4 × `sizeof(T)` + 1 byte for the
inclusive flag (padded to the next 2-byte boundary).

```
for byte_val in 0u8..=255u8              -- iterate every byte
for tile_id in 0i16..=tile_count
```

Methods:

| Form | Returns | Notes |
|------|---------|-------|
| `r.contains(x)` | `bool` | True if `x` falls inside `[start, end)` (or `[start, end]` if inclusive), accounting for step. |
| `r.empty()` | `bool` | True if no elements would be produced (e.g. `5..=2`). |
| `r.len()` | `u16` | Number of elements that would be visited. |

`for x in r` is special-cased by the compiler — no allocation,
no iterator object. User-defined iterables ship via the iterator
protocol; see §4.5.3.

#### 4.5.2 `while let`

Loop while a pattern keeps matching. The bindings refresh each
iteration:

```
while let Event.KeyDown(k) = poll_event()
  handle_key(k)
end

while let Item.Potion(n) = inventory.next() when n > 0
  drink(n)
end
```

Equivalent rewrite (longer) for the keydown loop:

```
while true
  let evt = poll_event()
  if let Event.KeyDown(k) = evt
    handle_key(k)
  else
    break
  end
end
```

`while let` is the natural shape for "drain a stream / queue / iterator
of optional results" — common enough to deserve sugar.

#### 4.5.3 Iterator protocol

`for-in` works on any value with a `next(self) -> T?` method.
The compiler reads the return type to deduce the loop variable's
type; iteration stops when `next()` returns `nil`. No declaration,
no trait, no `iter()` indirection — Lua-style convention.

```
class Inventory
  let items: [Item; 64]
  let count: u16
  let cursor: u16 = 0

  def next(self) -> Item?
    if self.cursor >= self.count
      return nil
    end
    let item = self.items[self.cursor]
    self.cursor += 1
    return item
  end
end

let inv = Inventory.new()
for item in inv
  use(item)
end                  -- terminates when inv.next() returns nil
```

**Desugaring.** `for x in expr <body> end` compiles to:

```
let __it = expr
while true
  let __v = __it.next()
  if __v == nil
    break
  end
  let x = __v
  <body>
end
```

The iterator value is the expression itself — there's no separate
"iterator object". **Iteration is destructive**: the instance's own
cursor advances during the loop. After `for item in inv … end`, `inv`
is at its end; a second loop produces nothing until `inv` is reset.
To iterate the same data twice, instantiate twice or expose a
`reset()` method on your class:

```
for item in inv             -- first pass: iterates 0..count
  use(item)
end
for item in inv             -- second pass: empty! cursor already at count
  use(item)
end

inv.cursor = 0              -- manual reset
for item in inv             -- now this works again
  use(item)
end
```

This is intentional — `next(self) -> T?` is the simplest possible
iterator protocol on a 16-bit target. The user is responsible for
reset semantics if reuse is needed.

**Built-ins** (`Range`, `[T; N]`, `str`, `Vec(T)`) are special-cased
by the compiler — `for-in` over them emits direct memory access
with no `next()` call. The user-visible model is identical to a
custom iterator; the special-case is invisible.

#### 4.5.4 Labeled loops

A loop may carry a `:label` after its head; `break :label` and
`continue :label` target the labeled loop instead of the innermost:

```
for y in 0..height :rows
  for x in 0..width
    if hit_wall(x, y)
      break :rows               -- exits the outer loop
    end
    if skip_column(x)
      continue :rows             -- next y, not next x
    end
  end
end
```

The label is a lowercase identifier. Unlabeled `break` / `continue`
keep targeting the innermost loop. A `break :unknown` referencing a
non-existent label is a compile error. Labels do not leak into the
expression namespace — they're a loop-local annotation.

`while` and `for-in` both accept labels; the syntax is `<head>
:label` (the label trails after the iterable / condition, before the
newline).

### 4.6 Functions

```
def name(arg: T, arg2: T) -> RetT
  body
  return value
end

-- void return
def greet(who: str)
  print "hello, " + who
end

-- recursion: name is in scope inside its own body
def fib(n: i16) -> i16
  if n < 2
    return n
  end
  return fib(n - 1) + fib(n - 2)
end
```

Functions are **first-class** — they're values like any other:

- **Assign** to variables: `let op = add`
- **Pass** as arguments: `apply(add, 1, 2)`
- **Return** from functions: `def make_adder(n) -> fn(i16) -> i16 …`
- **Store** in arrays / struct fields / collections

```
let op = add               -- function reference
let result = op(1, 2)      -- call through variable

def apply(f: fn(i16, i16) -> i16, a: i16, b: i16) -> i16
  return f(a, b)
end

let r = apply(add, 3, 4)   -- 7
```

The function-pointer type is spelled `fn(args) -> ret` in
annotations. At runtime it's a 16-bit code address.

#### 4.6.1 Tail-call optimization

When a function's last action before returning is `return f(args)`
where `f` is either the current function (self) or another function
of the same parameter shape (sibling), the compiler reuses the
current stack frame instead of pushing a new one. This is **the
only** tail-call shape optimized — full Scheme-style TCO across all
call positions is out of scope.

```
def count_down(n: i16)
  if n == 0
    return
  end
  print n
  return count_down(n - 1)        -- TCO: reuses frame, no stack growth
end

def alt_a(n: i16) -> i16
  if n == 0
    return 0
  end
  return alt_b(n - 1)             -- sibling TCO: same param shape
end
def alt_b(n: i16) -> i16
  if n == 0
    return 1
  end
  return alt_a(n - 1)
end
```

TCO does **not** apply to:

- `return f(args) + 1` — there is work after the call.
- `return f(args)` where `f` has a different parameter shape — the
  frame layout differs.
- Function-pointer calls (`return op(x)` where `op` is a variable) —
  the target isn't known at compile time.

Use `gero check --verbose` to confirm a tail call was optimized.
Non-tail recursion (`fib`-style) is unaffected — each call still
pushes a frame. Deep non-tail recursion will overflow the gero VM
stack (typically `$0100..$0FFF`, 4 KB); rewrite as a loop when
depth is unbounded.

#### 4.6.2 Variadic parameters

The last parameter of a `def` may be variadic, spelled `args: ...`:

```
def log(level: u8, fmt: str, args: ...)
  print level, " ", format(fmt, args)
end

log(1, "player at $(d:3d), $(d:3d)", x, y)
```

Inside the body, `args` is a **tuple** containing the supplied
arguments. There is no runtime length field — the compiler knows
the arity at each call site and emits a per-call specialization
sharing the function body. The arity must be ≥ 0 (zero variadic
args is allowed).

The format-spec language (§3.2.2) understands varargs: `format(fmt,
args)` forwards a varargs tuple positionally. User-defined helpers
follow the same convention.

Restrictions:

- Only the **last** parameter may be variadic.
- A variadic parameter has **no default value** — caller supplies
  zero or more positional args of the expected type.
- All variadic args must be **the same statically-known type** (or
  satisfy a common annotation). Mixed-type varargs aren't supported;
  for heterogeneous data, pass a tuple or struct explicitly.

#### 4.6.3 Method calls and chaining

Methods on classes (and stdlib helpers spelled as methods) call with
dot notation:

```
hero.take_damage(10)
inventory.push(item)
```

A `.` at the **start** of the next line continues the chain — useful
for fluent-style transformations:

```
let damaged_alive = monsters
  .filter(alive)
  .map(deal_damage)
  .filter(still_alive)
```

The newline-then-leading-`.` rule is the only line-continuation
exception in the otherwise newline-terminated grammar. Trailing `.`
at end-of-line does **not** continue (rejected — eliminates a class
of "did this newline end the statement?" ambiguity).

### 4.7 Lambdas (anonymous functions)

```
let square = lambda (x: i16) -> i16
  return x * x
end

let add5 = lambda (x: i16) -> i16  return x + 5  end
```

Lambdas are first-class function values (same as named `def`s) —
assign, pass, return, store. They differ from `def` only in being
unnamed and inline.

#### 4.7.1 Short lambda form

For single-expression lambdas (the common case in `map`, `filter`,
`fold`), gero-lang accepts a Rust-style short form:

```
|x| x * 2                           -- one param, expression body
|x, y| x + y                        -- multiple params
|| read_input()                     -- zero params
|x: i16| -> i16  x * 2              -- explicit types (rare; usually inferred)
```

The body is a **single expression**, not a block — there is no
`return` keyword, no `end` terminator. The expression's value is the
lambda's return value.

```
let doubled = xs.map(|x| x * 2)
let evens   = xs.filter(|x| x % 2 == 0)
let total   = xs.fold(0, |acc, x| acc + x)
```

For multi-statement bodies, drop back to the long form:

```
let summary = items.map(lambda (item: Item) -> str
  let n = format_count(item.count)
  let name = item.display_name()
  return name + " x" + n
end)
```

Or wrap the work in a `do … end` expression so the short form still
applies:

```
let labels = items.map(|item| do
  let n = format_count(item.count)
  item.display_name() + " x" + n
end)
```

Both lambda forms have identical capture semantics (see §4.7.2).

#### 4.7.2 Static lexical scope (closures)

All functions — `def` and `lambda` alike — close over the lexical
scope they were defined in. Free variables in the body resolve to the
binding in the enclosing scope at definition time, not at call time:

```
def make_counter(start: i16) -> fn() -> i16
  let n = start
  return lambda () -> i16
    n = n + 1
    return n
  end
end

let c = make_counter(10)
print c()   -- 11
print c()   -- 12
```

**Capture semantics.** When a `let` binding is captured **and**
mutated by an inner closure, the compiler promotes it to a
heap-allocated "upvalue" slot — both the outer scope and every
closure that captures it share the same pointer. Mutations through
either side are visible to the other. Same model as Lua's upvalues.

If a binding is only **read** by inner closures (never written from
the closure), it stays on the stack and the closure copies the value
at construction. Zero heap overhead for the common read-only case.

The promotion decision is automatic — the programmer doesn't
annotate. To inspect the choice, `gero check --verbose` reports
which `let` bindings were promoted.

#### 4.7.3 Inline scoped computation: use `do … end`

Older lang traditions use Immediately Invoked Lambda Expressions
(IILEs) for "compute a value with some scratch state". gero-lang
uses **`do … end` as an expression** instead (§4.3) — same effect,
half the syntax:

```
let area = do
  let w = read_width()
  let h = read_height()
  w * h
end

let board = do
  let b: [u8; 64] = [0; 64]
  for i in 0..8
    b[i * 8 + i] = 1   -- diagonal
  end
  b
end
```

Real lambdas + immediate-call still parse if you want them
(`(lambda () … end)()`), but the common case is just `do … end`.
The lambda form earns its keep when you need a **named** captured
state or a function value to pass elsewhere.

### 4.8 Match (Rust-style)

Pattern matching with destructuring, guards, range patterns, or
patterns, and compile-time exhaustiveness checking.

#### 4.8.1 Patterns

| Pattern | Matches | Binds |
|---------|---------|-------|
| `42` | the literal `42` | nothing |
| `"hello"` | the literal string | nothing |
| `_` | anything | nothing |
| `x` | anything | the value to `x` |
| `1 \| 2 \| 3` | any of the listed literals | nothing |
| `0..=15` | any value in the inclusive range | nothing |
| `Item.Sword` | the variant (no payload) | nothing |
| `Item.Potion(amount)` | the variant; binds payload | `amount` |
| `Item.Key(name, _)` | the variant; binds first payload, ignores second | `name` |
| `(a, b)` | a 2-tuple | `a`, `b` |
| `Player { hp, mp }` | a struct; binds named fields | `hp`, `mp` |
| `Player { hp: 0, mp }` | hp must be 0; binds mp | `mp` |

#### 4.8.2 Guards

`when` clause adds an arbitrary boolean condition:

```
match item
  case Item.Potion(n) when n > 50 =>
    print "big potion"
  case Item.Potion(_) =>
    print "small potion"
  case _ =>
    print "not a potion"
end
```

The guard runs only after the pattern matches; failure falls through
to the next arm. The arm separator is `=>` (fat arrow), not `then`.

#### 4.8.3 Exhaustiveness

For enum-typed scrutinees, the compiler **errors** if any variant is
unhandled and there's no wildcard arm:

```
match item
  case Item.Sword => ...
  case Item.Potion(_) => ...
  -- ERROR: missing case for Item.Key
end
```

Add a `case _ => ...` to discharge the warning, OR list every
variant explicitly. For non-enum scrutinees (integers, strings),
exhaustiveness can't be checked — the compiler requires a wildcard
arm or warns.

#### 4.8.4 Worked example

```
enum Event
  case Quit
  case KeyDown(u8)
  case MouseClick(x: i16, y: i16)
  case Tick(frame: u16)
end

def handle(e: Event)
  match e
    case Event.Quit =>
      cleanup()
    case Event.KeyDown(k) when k == $1B =>       -- ESC
      cleanup()
    case Event.KeyDown(_) =>
      -- ignore other keys
    case Event.MouseClick(x, y) when x < 128 =>
      hit_left_pane(x, y)
    case Event.MouseClick(x, y) =>
      hit_right_pane(x, y)
    case Event.Tick(f) when f % 60 == 0 =>
      one_second_tick()
    case Event.Tick(_) =>
      -- frame tick, no per-second action
  end
end
```

#### 4.8.5 Compilation

- **Single-arm tag dispatch** (no payloads): jump table indexed by
  tag byte
- **With payloads**: dispatch on tag, then bind locals from payload
  bytes, then evaluate guard if present
- **Or patterns**: expanded to `case A => X case B => X`
  (compiler dedupes the body if it can)
- **Range patterns**: emit `cmp` + bounded jumps

#### 4.8.6 `if let` vs `match` — when to use which

| Situation | Use |
|-----------|-----|
| Single pattern, single body, no exhaustiveness needed | `if let` |
| Multiple patterns dispatching to different bodies | `match` |
| Need exhaustiveness check on an enum | `match` |
| Want to handle the no-match case inline (else branch) | `if let` |
| Pattern is in a loop draining a stream | `while let` |
| Want guards with multiple cases | `match` (single-case guards work in `if let` too) |
| Single pattern but failure should bail (return / break) | `match` with `case _ => return` (or @noreturn helper) |

In short: `match` is the dispatcher; `if let` / `while let` / `let
else` are sugar for the single-pattern shapes. Reach for `match`
the moment you have ≥ 2 cases or want exhaustiveness; otherwise the
shorter form reads better.

### 4.9 Print

`print` is a built-in statement (deliberately not a function — this
preserves the old-school BASIC immediate-mode feel that the language
takes its ergonomics from):

```
print "hello"
print x, y, z       -- comma = space-separated, newline at end
```

The cost is one parser special case. The win is `print "hello"`
without imports, parens, or `io.print(…)` ceremony — exactly the
shape a 12-year-old learning to code on the gtx-16 should hit on
day one. The trade-off is intentional.

Compiles to a host-provided syscall (`int $10`). The host's printer
implementation defines the output channel (gtx-16 prints to a debug
console; CLI tools print to stdout).

### 4.10 Defer

`defer <stmt>` schedules a statement to run when the enclosing block
exits. Useful for hardware-state save / restore, IRQ-mask windows,
and any cleanup that has to fire on **every** exit path including
`return` / `break` / `continue`:

```
def render_with_palette(new_pal: u8)
  let old = read_palette()
  defer set_palette(old)        -- restoration guaranteed
  set_palette(new_pal)
  render_frame()
  -- if render_frame returns early, the palette still restores
end

def safe_update()
  let mask = read_irq_mask()
  defer set_irq_mask(mask)
  set_irq_mask(0)
  -- critical section: any return / break / continue still restores
end
```

**Scope.** Block-scoped — the defer attaches to the nearest
enclosing block (`do`, `if`-arm, `while` / `for` body, function
body, `match`-arm body, `lambda` body). The deferred statement runs
when that block exits, not when the function returns.

```
while cond
  let frame = acquire()
  defer release(frame)      -- runs at the bottom of every iteration
  if early
    break                   -- release still runs before the break
  end
  process(frame)
end
```

**Order.** Multiple defers in the same block run in **LIFO** order:

```
defer a()
defer b()
defer c()
-- on exit: c, then b, then a
```

**Exit paths covered.** Normal end-of-block, `return`, `break`,
`continue`. The deferred statement also runs when the block exits
via an early `return` that's nested in deeper blocks below the
defer — every exit path through this block fires the cleanup.

**Exit paths NOT covered.** Hardware faults (gero's `int $02`-style
traps — out-of-bounds, nil-deref, div-by-zero). Defers do **not**
run on fault. Faults are terminal in gero; no user-level recovery
path runs.

**Restrictions.** The deferred statement is parsed as a regular
statement, but the codegen / typechecker rejects:

- `defer return …`, `defer break`, `defer continue` — cleanup
  blocks can't redirect control flow. Wrap with `do … end` if you
  need a multi-line body that doesn't contain those forms.
- `defer defer …` — pointless, doesn't compose.

**Compilation.** The compiler walks the block accumulating defers
into a per-block list. At each scope-exit point it emits the
cleanup code in reverse order; for `return` / `break` / `continue`
it routes the jump through a generated cleanup label so the same
emission code is shared. Zero runtime overhead on the common
no-defer path.

**Bytecode cost.** A block with `N` defers and `M` distinct exit
paths emits one shared cleanup tail (`N` instructions on average) and
`M` jumps routed through it — total ≈ `N + M` bytecode instructions
per block on top of the bare block, regardless of how often the
exits are taken at runtime. The cleanup tail is reached by the
jumps via the cleanup label; each `return` / `break` / `continue`
becomes one branch. The runtime cost per exit is the LIFO-walk of
the cleanup tail itself (`N` calls + the original control transfer).
For typical use (1-2 defers, 1-3 exits), the cost is small enough
to be invisible at the per-frame scale; for hot loops that defer
inside the loop body, the defer cost runs **once per iteration** —
budget accordingly.

### 4.11 Inline assembly (`asm`)

`asm "<instruction>"` is a builtin statement that emits a single
bytecode instruction directly. It's the escape hatch into the
gero ISA for cases the compiler can't express: ISR atomic
windows, hand-tuned hot loops, cycle-counted timing tricks, or
direct manipulation of the VM's register / flag state.

```
def fast_swap(a: u16, b: u16)
  asm "swap {a}, {b}"
end

def fence()
  asm "memfence"
end
```

**Substitution.** Operands inside `{name}` braces resolve to the
gero-lang local with that name. The compiler validates that the
local exists and emits the appropriate register / addressing
reference at the asm slot.

**Constraints.**

- **One instruction per `asm` statement.** Multi-instruction asm
  blocks are not supported; chain multiple `asm "..."` statements
  in source order if needed.
- **Substituted operands must be of a type the instruction accepts**
  — the assembler validates this at lowering time. Type mismatch
  is a compile error pointing at the gero-lang local, not the asm
  string.
- **No control-flow into / out of an `asm` statement.** The asm
  instruction must complete normally; no embedded branches, no
  jumps to labels outside the asm. (The asm statement itself can
  still affect the VM PC if the instruction is a branch — `asm
  "ret"` returns from the enclosing function, like any `return`
  statement would — but the compiler does not analyze this and the
  user is responsible for the resulting control flow.)

**When to reach for it.** The asm escape hatch is the **last
resort**. If you find yourself using it more than 2-3 times in a
real project, the compiler is missing a codegen optimization and
the right move is to surface the missing feature in the language
or stdlib. The lifeline is real but it shouldn't carry weight.

For longer cycle-counted routines, write the whole function in
gero asm (`.gx` source) and link it via the standard linker rules
— inline `asm` is for the one-instruction sliver of a high-level
function, not for whole subroutines.

---

## 5. Modules

### 5.1 Files = modules

Each `.gr` file is a module. The filename (without extension) is
the module name. Top-level declarations are **exported by default**;
prefix with `local` to keep private.

```
-- file: math.gr

const PI_FIXED = $0324      -- π ≈ 3.14159 in 8.8 fixed

def abs(x: i16) -> i16
  if x < 0
    return -x
  end
  return x
end

local def helper()           -- not exported
  -- ...
end
```

### 5.2 Imports

```
use math                     -- imports the whole module as "math"
use "./physics"              -- relative path import
use abs from math            -- selective import (only "abs" in scope)
use abs as absolute from math  -- selective + rename
```

Resolution:
- Bare name (`math`) → look up in stdlib first, then in current dir
- Quoted path (`"./foo"`) → relative to the importing file
- No transitive re-exports — if you import a module, only its direct
  exports are visible

### 5.3 Standard library

The stdlib is intentionally tiny — gero-lang programs targeting
cartridges shouldn't carry incidental complexity. Each module
solves one concrete need:

| Module | What |
|--------|------|
| `math` | `abs`, `min`, `max`, `clamp`, `sqrt_fixed`, fixed-point helpers, `rng()` |
| `mem`  | typed peek / poke / memcpy / memset / `addr_of` — see §5.3.1 |
| `str`  | `len`, `at`, `cmp`, `concat` (allocated), `format(fmt, args)` |
| `bank` | `switch_to(N)`, `current()` — bank manipulation |
| `test` | `assert_eq(a, b)`, `assert_ne(a, b)` — used in `@test` functions |

`assert` and `debug_assert` are **always in scope** without import —
both are built-in pseudo-functions:

- `assert(cond, msg?)` — always evaluated, in every build mode. On
  `false`, traps via fault vector `$02` with the optional message
  in the diagnostic. Use for invariants that **must never fail**
  in production code.
- `debug_assert(cond, msg?)` — evaluated in debug builds only.
  Elided entirely (zero bytecode emitted) under `gero build
  --release`. Use for pedagogical / development-time checks that
  shouldn't carry shipping cost.

```
assert(self.hp >= 0, "hp went negative")        -- always live
debug_assert(items.len() < 1000)                -- debug-only
```

#### 5.3.1 `mem` stdlib

```
mem.read_u8(addr: u16) -> u8
mem.read_u16(addr: u16) -> u16
mem.read_i8(addr: u16) -> i8
mem.read_i16(addr: u16) -> i16
mem.write_u8(addr: u16, v: u8)
mem.write_u16(addr: u16, v: u16)
mem.write_i8(addr: u16, v: i8)
mem.write_i16(addr: u16, v: i16)

mem.memcpy(dst: u16, src: u16, n: u16)
mem.memset(dst: u16, v: u8, n: u16)

mem.addr_of(x) -> u16
mem.peek(addr: u16) -> u8           -- alias for read_u8
mem.poke(addr: u16, v: u8)          -- alias for write_u8
```

`mem.read_u16` / `mem.write_u16` follow the gero VM convention:
little-endian, low byte at `addr`, high byte at `addr + 1`. Signed
variants (`read_i16`, `write_i16`) use the same byte order with
two's-complement interpretation.

`mem.addr_of(x)` returns the runtime address of `x` as a plain `u16`.
For typed reference passing, use `&T` (§3.4.4) — `addr_of` is the raw
escape for the cases where the bytes themselves matter (DMA setup,
asm bridge, manual MMIO layout). Calling `addr_of` on a `let` local
returns its stack-slot address, valid until the enclosing scope ends;
calling on a `const` returns its static-data address (always valid).

Host-specific modules (`input`, `display`, `audio` for gtx-16) live
outside the gero stdlib — gtx-16 ships its own header modules.

---

## 6. Classes

> **Pre-read:** §3.4.2 explains the `struct` vs `class` choice. If
> the type has no methods and no inheritance, use `struct` instead —
> it costs 2 bytes less per instance and signals "pure data" at the
> call site.

```
class Player
  let hp: i16
  let mp: i16
  let level: u8

  def init(self, name: str)
    self.hp = 100
    self.mp = 50
    self.level = 1
  end

  def take_damage(self, amount: i16)
    self.hp = self.hp - amount
    if self.hp <= 0
      self.die()
    end
  end

  def die(self)
    print "you died"
  end
end
```

Instantiation:

```
let p = Player("Cecil")     -- calls init
p.take_damage(20)
print p.hp                  -- 80
```

Inheritance:

```
class Hero extends Player
  let weapon: str

  def init(self, name: str, weapon: str)
    super.init(name)
    self.weapon = weapon
  end
end
```

Single inheritance only. Method resolution: walks the chain bottom
up, first hit wins. `super.method(args)` calls the parent's version
explicitly.

**Field shadowing and `super.<field>`.** A subclass may declare a
field with the same name as a parent field — the subclass field
shadows the parent's for unqualified access (`self.value`). The
shadowed parent field remains addressable via `super.<field>`:

```
class Parent
  let value: i16 = 10
end

class Child extends Parent
  let value: i16 = 20    -- shadows Parent.value

  def report(self)
    print self.value      -- 20 (own field)
    print super.value     -- 10 (parent field, still in memory)
  end
end
```

`super.<field>` follows the same chain-walking resolution as
`super.<method>` — first ancestor that declares the named field
wins. Layout-wise, both fields occupy distinct slots in the instance
memory (Child instances have one `value` for the parent layout +
one for the subclass).

**Visibility default.** Class members (fields and methods) are
**public by default** — no `@public` annotation needed. This is
intentional: on a 16-bit target the cycle cost of enforcing
encapsulation is paid in code size and call indirection, and the
target audience (game logic, not library API design) gets more value
from terse direct access than from contract-enforcement. Mark
members `@private` (§3.7.6) when the encapsulation actively matters.

OOP compiles to:
- A vtable in static data per class (function pointers indexed by
  method ID)
- Instance memory: 2-byte vtable pointer + field bytes, contiguous
- Method dispatch: load vtable pointer, index, call

Old-school enough — same model NES games used for actor systems.

---

## 7. Compilation model

### 7.1 What compiles to what

| Source construct | Bytecode shape |
|------------------|----------------|
| `let x: i16 = 0` | Stack slot or register allocation |
| `const X = 5` | Inlined at use sites |
| Function | `addr_of_label`; calls become `call addr` |
| Lambda | Synthesized hidden function + closure-capture struct |
| Class | Vtable in static data + per-instance memory layout |
| String literal | Bytes in static data; var holds 16-bit pointer |
| Module | Translation unit; one `.gr` → one set of labels |
| Import | Linker resolves the symbol; all imports must be in the linkage set |

### 7.2 Memory layout of a compiled program

```
$0000..$00FF  zero page (stdlib uses for fast globals)
$0100..$0FFF  conventional stack range
$1000..$10FF  IVT (compiler emits handlers if program declares them)
$1100..       compiled code
              ↓
              user state (allocated globals, mutable data)
              ↓
$7FFF (or wherever code ends)

$8000..$BFFF  Mapped region A (plain RAM; on gtx-16, carts
                                  typically store sprite sheets here)
$C000..$FEFF  bank window (compiler emits per-bank if program
                              uses banked modules)
$FE40..$FEFF  gtx-16 IO surface (display, drawing, audio,
                                    input — see gtx-16 §14)
$FF00..$FFFF  IO page tail (RNG, timing, KV store, mouse)
```

### 7.3 Banked modules

Per-module banking via `@bank N` (§3.7.1). A whole-file annotation
sits at the top:

```
-- file: dialogs/town.gr
@bank 5

const INTRO = "Welcome to Mistwood..."
-- … 4 KB of dialog strings …
```

The compiler places this module's compiled output in bank 5. Cross-
bank calls compile to:

```asm
push mb                     ; save current bank
mov #5, mb                  ; switch
call town__intro_addr
pop mb                      ; restore
```

Per-declaration banking is also supported — useful when only some
items in a module need to live in a specific bank:

```
def main()
  -- always-resident
end

@bank 5
def boss_battle_data() -> [u8; 256]
  -- only loaded when boss_battle module switches in
end
```

Cross-bank calls go through the trampoline pattern above; intra-bank
calls compile to plain `call addr` with no overhead.

---

## 8. Worked examples

### 8.1 Hello, world

```
print "Hello, world!"
```

### 8.2 Fibonacci

```
def fib(n: i16) -> i16
  if n < 2
    return n
  end
  return fib(n - 1) + fib(n - 2)
end

print fib(10)   -- 55
```

### 8.3 J-RPG main loop sketch

```
use input
use display
use bank
use save

class GameState
  let player_x: i16
  let player_y: i16
  let map_id: u8
  let bag: [u8; 64]

  def init(self)
    if save.exists()
      save.load(self)
    else
      self.player_x = 128
      self.player_y = 96
      self.map_id = 0
    end
  end

  def update(self)
    if input.up()
      self.player_y -= 1
    end
    if input.down()
      self.player_y += 1
    end
    if input.left()
      self.player_x -= 1
    end
    if input.right()
      self.player_x += 1
    end
  end

  def draw(self)
    display.clear(0)
    display.sprite(0, self.player_x, self.player_y)
    display.flip()
  end
end

let state = GameState()

while true
  state.update()
  state.draw()
end
```

---

## 9. Out of scope

These design choices are deliberate. They keep the language small
and the compiler simple; the absence isn't a missing feature.

- **Async / coroutines.** gero-lang programs are single-threaded.
  Cooperative multitasking is the host's job — gtx-16 carts run an
  asm-level interrupt loop and dispatch work from there, or build a
  game state machine in pure gero-lang. No `async` / `await`,
  no generators.
- **Traits / interfaces.** Polymorphism dispatches through class
  inheritance (§6) or enum variants (§3.6). The J-RPG / cart use
  case doesn't need structural polymorphism; adding it would force
  vtable indirection on every class.
- **User-defined generics.** `Vec(T)`, `Range`, `[T; N]`, and
  tuples are compiler-known; user types can't take type parameters.
  If you need typed containers beyond those, wrap them in a class
  with the right interface for your use case.
- **Block comments.** `--` to EOL is the only comment syntax —
  matches the asm `;` family in spirit (no `--[[ ... ]]`).
- **Decimal floats.** The VM is integer-only; `fixed` (Q8.8) covers
  the fractional arithmetic gtx-16 carts actually need.
- **`Option<T>` / `Result<T, E>` enums.** Pointer-like types use
  `T?` + `nil`; fallible operations use multi-return tuples
  (§3.4.1). No `?` propagation operator. Lua/Go-style explicit
  checks.
- **`++` / `--` as expressions.** They're statements only (§4.2);
  no `let y = x++` ambiguity.
- **Raw pointers `*T` with arithmetic.** References (`&T`, §3.4.4)
  cover the "pass without copy" use case without arithmetic. For
  raw `u16` addresses (asm bridge, DMA setup), `mem.addr_of(x)` and
  `mem.read_*` / `mem.write_*` (§5.3.1) are the explicit escape;
  there is no `*T + 1` syntax.
- **Borrow checker.** References don't track exclusive vs shared
  borrows; lifetime checking is limited to "no return ref to stack
  local" (§3.4.4). The cart audience doesn't need Rust-grade memory
  safety on top of what `T?` and explicit checks already provide.
- **`then` / `do` after block heads.** Removed for source noise
  reduction; the parser is recursive-descent and doesn't need them.
  See §4.4 / §4.5. (Lua keeps them for LR-parser reasons that don't
  apply here.)
