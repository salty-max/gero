# Gero Language — Spec v0.1 (DRAFT)

The high-level language that compiles to [Gero bytecode](./isa.md).
Source file extension `.gr`. Compiler is a Zig program in this repo
(`src/lang/`).

> **Status: design draft.** Builds on the prior
> [eevee-source](https://github.com/salty-max/eevee-source) prototype
> (Crafting Interpreters-style tree-walk in TypeScript) but
> deliberately diverges on three axes: **no semicolons**, **typed**,
> **module / import system**. Locks happen as the compiler
> implementation forces decisions.

---

## 1. Philosophy

- **Reads like Lua / BASIC** — `let`, `do … end`, `if … then … end`,
  `print`. Familiar to anyone who's touched a teaching language.
- **No semicolons** — statement boundaries are newlines. Cheap to
  type, less visual noise. (Modern Lua, Go, Python convention.)
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

To continue a long expression onto the next line, use parentheses or
break inside a binary operator:

```
let total =
  player.hp +
  player.mp
```

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
| Hex | `0xFF`, `0xABCD` | `int` |
| Binary | `0b1010_0101` | `int`. Underscores allowed for readability. |
| Negative | `-1` | `int` (unary minus operator) |

No floating-point literals — gero VM is integer-only. For fractions
use the `fixed` type (8.8 fixed-point — see §3.3).

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

### 2.6 Keywords (reserved)

```
let const def lambda return
if then else end
while do for in step
match case when
class extends self super
enum is
use from as local
true false nil
and or not
break continue
print
```

`and`, `or`, `not` are the boolean operators (short-circuit). The
bitwise counterparts use symbolic operators `&` `|` `^` `<<` `>>`
`~` (§4.2.2).

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
| `s.at(i)`         | `u8` (byte at index `i`) | No. Bounds-check at runtime; out-of-bounds → fault vector `0x02`. |
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
let v: fixed = 1.5    -- compiles to 0x0180
let dx: fixed = 0.125 -- compiles to 0x0020
```

Standard arithmetic operators work — multiply / divide handle the
shift internally.

This is the canonical answer for "I need fractions" — same trick
PICO-8, Sonic, early Doom used.

### 3.4 Compound types

| Form | Example | Notes |
|------|---------|-------|
| Array (fixed-size) | `[u8; 64]` | N is comptime. Stack-allocated if local. |
| Tuple | `(i16, str)` | Anonymous heterogeneous pair / triple / etc. Up to 4 elements in v0.1. Destructurable in `let` and `match`. Field access via `.0`, `.1`, …. |
| Optional | `T?` | Sugar for `Option<T>` — see §3.4.1. |
| Function | `fn(i16, i16) -> i16` | First-class — assignable, passable. |
| Struct | `struct Foo a: i16, b: u8 end` | C-style POD. Fields contiguous in memory, no methods. See §3.4.2. Literal: `Foo { a: 1, b: 2 }`. |
| Class | `class Foo { … }` | Vtable + fields, methods, single inheritance. See §6. |

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

**Layout** = `sizeof(T)`. The value `0x0000` is the canonical `nil`
representation (since pointer types use `0x0000` as their natural
null), so no tag byte is needed.

**Testing for nil:**

```
if p != nil then
  p.greet()           -- safe — flow analysis carries non-nil through
end

if p == nil then
  return
end
p.greet()             -- safe here too
```

**Dereferencing a nullable.** Direct method/field access on a `T?`
value compiles with a runtime nil-check that faults via vector
`0x02` if the value is `nil`. The compiler **statically requires
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
  if s.len == 0 then return (0, "empty input") end
  -- ...
  return (value, nil)
end

let (n, err) = parse_int(input)
if err != nil then handle(err) end
```

The `str?` second slot is the error message when present, `nil` on
success. Idiomatic in Lua, Go, and most pre-Rust runtimes.

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
if item is Item.Sword then equip_basic() end
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
| `@zero_page` | `let` | Place this global in the zero-page region (`0x0000..0x00FF`) — 1-byte addressing mode, faster + smaller code. Slot pressure is high (256 bytes shared); compiler errors on overflow. |
| `@addr $1234` | `let` | Pin this global at the given absolute address. Use for binding to memory-mapped IO registers or fixed-position state. The compiler reserves no other RAM at that address. |

**`@bank` precedence.** `@bank N` may appear at either:
- **File scope** — the first non-comment token in a `.gr` file.
  Applies to every declaration in the file unless overridden.
- **Declaration scope** — directly above a `def` / `let` / `const`.
  Applies to that declaration only.

Per-declaration `@bank` always wins over the file-level default. A
declaration inside a file with `@bank 5` at the top can opt out
back to the base image with `@bank 0`. Declarations that appear
without any `@bank` annotation (and no file-level default) land
in the base image (bank-less area before `0xC000`).

```
@zero_page
let cursor_pos: u16 = 0      -- fast access, e.g. updated 60×/sec

@addr $FF00
let DISPCTL: u8 = 0          -- bound to gtx-16 display-control IO register

@bank 5
def town_intro_dialog() -> str
  return "Welcome to Mistwood..."
end
```

#### 3.7.2 Codegen control

| Annotation | Applies to | Effect |
|------------|------------|--------|
| `@inline` | `def`, `lambda` | Always inline at call sites. Compiler errors if the function is recursive or its body is too large. |

```
@inline
def fast_clamp(x: i16, min: i16, max: i16) -> i16
  if x < min then return min end
  if x > max then return max end
  return x
end
```

#### 3.7.3 Diverging functions

| Annotation | Applies to | Effect |
|------------|------------|--------|
| `@noreturn` | `def`, `lambda` | Asserts the function never returns normally (it must `hlt`, infinite-loop, or call another `@noreturn`). The compiler treats calls as diverging — usable in `match` bail arms with otherwise non-exhaustive shape. The return type, if specified, must be `noreturn`. |

```
@noreturn
def panic(msg: str) -> noreturn
  print "PANIC: ", msg
  hlt
end

def use_potion(item: Action)
  match item
    case Action.Heal(n) then heal(n)
    case _              then panic("not a healing item")
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
| `@interrupt N` | `def` | Bind this function as the handler for vector `N` (gero ISA §6.1). The compiler emits the `rti` epilogue automatically and writes the function address into `mem[0x1000 + 2 * N]` at boot. The function body must take no parameters and return nothing. |

```
@interrupt 0x06              -- vblank
def on_vblank()
  frame_count += 1
end

@interrupt 0x21              -- save-flush convention
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

| Annotation | Applies to | Effect |
|------------|------------|--------|
| `@asm("...")` | statement-level | Embed a single asm instruction (or a multi-line block via heredoc syntax — TBD). Operands can reference gero-lang locals via `{name}` substitution. |

```
def fast_swap(a: u16, b: u16)
  @asm("swp {a}, {b}")
end
```

The asm escape hatch is the **last resort** — if you find yourself
using it more than 2-3 times in a project, the compiler is missing a
codegen optimization and you should file an issue.

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
const PI_FIXED = 0x0324       -- comptime, inlined
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
  case Item.Potion(n) then heal(n)
  case _              then return
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
```

No `++` / `--` (they were in the eevee-source prototype but
deliberately dropped — `x += 1` covers it without operator-overload
rules around prefix vs postfix).

#### 4.2.2 Operators (binary)

| Category | Operators | Notes |
|----------|-----------|-------|
| Arithmetic | `+` `-` `*` `/` `%` | `/` and `%` on signed → truncated toward zero |
| Comparison | `==` `!=` `<` `<=` `>` `>=` | All return `bool` |
| Logical | `and` `or` `not` | Short-circuit evaluation. `not` is unary. |
| Bitwise | `&` `\|` `^` `<<` `>>` `~` | Map directly to ISA `and` / `or` / `xor` / `lsh` / `rsh` / `not`. `~` is unary bitwise NOT. |
| Range | `..` `..=` | See §4.5. Produce `Range<T>` values. |
| Type test | `is` | `value is EnumVariant` — see §3.6. |

**Precedence (highest to lowest):**

1. Unary: `-` `not` `~`
2. `*` `/` `%`
3. `+` `-`
4. `<<` `>>`
5. `&`
6. `^`
7. `\|`
8. Comparison: `==` `!=` `<` `<=` `>` `>=`
9. `and`
10. `or`
11. `..` `..=`
12. Assignment (`=`, `+=`, etc. — right-associative)

Same precedence as C / Rust for bitwise vs comparison (low) and
shifts vs arithmetic (low). Use parens when in doubt — `if (flags &
MASK) == TARGET then` reads better than relying on precedence
memory.

#### 4.2.1 Discarding a value

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
if cond then
  body
end

if cond then
  body
else
  other
end

if cond then
  body
else if cond2 then
  other
else
  default
end
```

No parentheses around conditions. Lua-style.

#### 4.4.1 `if let`

Pattern-match in conditional position. Bindings introduced by the
pattern are in scope inside the `then` branch (and only there):

```
if let Item.Potion(n) = item then
  drink(n)
end

if let Event.MouseClick(x, y) = e when x < 128 then
  hit_left(x, y)
end
```

Pattern syntax = §4.8.1; `when` guards are accepted (§4.8.2). When
the pattern doesn't match, the `then` branch is skipped (and `else`
runs if present).

### 4.5 Loops

```
while cond do
  body
end

for i in 0..=10 do          -- inclusive 0..10
  body
end

for i in 0..10 do           -- exclusive (0..9)
  body
end

for i in 0..=100 step 5 do  -- explicit step
  body
end

for item in collection do
  body
end
```

`break` and `continue` work in any loop.

`0..=10` and `0..10` are first-class **range expressions**. They're
also valid `match` patterns (§4.8.1) and can be passed around as
values.

#### 4.5.0.1 The `Range<T>` type

```
struct Range<T>
  start: T
  end: T
  step: T          -- 1 by default
  inclusive: bool  -- true for ..=, false for ..
end
```

Layout: 6 or 8 bytes depending on `T` (3 × sizeof(T) + 1 byte for
`inclusive`, padded to alignment). For `T = i16` the slot is 8 bytes.

Methods:

| Form | Returns | Notes |
|------|---------|-------|
| `r.contains(x)` | `bool` | True if `x` falls inside `[start, end)` (or `[start, end]` if inclusive), accounting for step. |
| `r.empty()` | `bool` | True if no elements would be produced (e.g. `5..=2`). |
| `r.len()` | `u16` | Number of elements that would be visited. |

`for x in r do` is special-cased by the compiler — no allocation, no
iterator object. Custom iterables (anything other than ranges,
arrays, or strings) are a v0.2 feature pending the iterator protocol
spec.

#### 4.5.1 `while let`

Loop while a pattern keeps matching. The bindings refresh each
iteration:

```
while let Event.KeyDown(k) = poll_event() do
  handle_key(k)
end

while let Item.Potion(n) = inventory.next() when n > 0 do
  drink(n)
end
```

Equivalent rewrite (longer) for the keydown loop:

```
while true do
  let evt = poll_event()
  if let Event.KeyDown(k) = evt then
    handle_key(k)
  else
    break
  end
end
```

`while let` is the natural shape for "drain a stream / queue / iterator
of optional results" — common enough to deserve sugar.

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
  if n < 2 then return n end
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

#### 4.6.1 Method calls and chaining

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

#### 4.7.1 Static lexical scope (closures)

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

(Mutable closure captures like the example above are **v0.2**. v0.1
captures by value: `n` would be snapshotted at lambda construction
and `c()` would always return the same `start + 1`. The example
above shows the *intended* end state.)

For v0.1: captured variables are **copied** into the closure at
construction. Mutating the outer variable after that has no effect on
the closure; mutating the captured copy inside the closure has no
effect on the outer.

#### 4.7.2 Inline scoped computation: use `do … end`

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
  for i in 0..8 do
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
  case Item.Potion(n) when n > 50 then
    print "big potion"
  case Item.Potion(_) then
    print "small potion"
  case _ then
    print "not a potion"
end
```

The guard runs only after the pattern matches; failure falls through
to the next arm.

#### 4.8.3 Exhaustiveness

For enum-typed scrutinees, the compiler **errors** if any variant is
unhandled and there's no wildcard arm:

```
match item
  case Item.Sword then ...
  case Item.Potion(_) then ...
  -- ERROR: missing case for Item.Key
end
```

Add a `case _ then ...` to discharge the warning, OR list every
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
    case Event.Quit then
      cleanup()
    case Event.KeyDown(k) when k == 0x1B then       -- ESC
      cleanup()
    case Event.KeyDown(_) then
      -- ignore other keys
    case Event.MouseClick(x, y) when x < 128 then
      hit_left_pane(x, y)
    case Event.MouseClick(x, y) then
      hit_right_pane(x, y)
    case Event.Tick(f) when f % 60 == 0 then
      one_second_tick()
    case Event.Tick(_) then
      -- frame tick, no per-second action
  end
end
```

#### 4.8.5 Compilation

- **Single-arm tag dispatch** (no payloads): jump table indexed by
  tag byte
- **With payloads**: dispatch on tag, then bind locals from payload
  bytes, then evaluate guard if present
- **Or patterns**: expanded to `case A then X case B then X`
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
| Single pattern but failure should bail (return / break) | `match` with `case _ then return` (or @noreturn helper) |

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

Compiles to a host-provided syscall (`int 0x10`). The host's printer
implementation defines the output channel (gtx-16 prints to a debug
console; CLI tools print to stdout).

---

## 5. Modules

### 5.1 Files = modules

Each `.gr` file is a module. The filename (without extension) is
the module name. Top-level declarations are **exported by default**;
prefix with `local` to keep private.

```
-- file: math.gr

const PI_FIXED = 0x0324      -- π ≈ 3.14159 in 8.8 fixed

def abs(x: i16) -> i16
  if x < 0 then return -x end
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

v0.1 stdlib is intentionally tiny:

| Module | What |
|--------|------|
| `math` | `abs`, `min`, `max`, `clamp`, `sqrt_fixed`, fixed-point helpers, `rng()` |
| `mem`  | `memcpy`, `memset`, `peek`, `poke` (raw VM-level memory ops) |
| `str`  | `len`, `at`, `cmp`, `concat` (allocated) |
| `bank` | `switch_to(N)`, `current()` — bank manipulation |
| `test` | `assert(cond, msg?)`, `assert_eq(a, b)` — for `@test` functions |

`assert` is **always in scope** without import — it's a built-in
pseudo-function that compiles to a conditional `int 0x02`-style
trap (Invalid-state fault, vector `0x02`) when the condition is
false. The optional message is included in the diagnostic. Outside
of `@test` functions, prefer explicit error handling — `assert` is
for invariants that **should never** fail.

```
assert(self.hp >= 0, "hp went negative")
assert_eq(items.len(), 4)
```

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
    if self.hp <= 0 then
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
0x0000..0x00FF  zero page (stdlib uses for fast globals)
0x0100..0x0FFF  conventional stack range
0x1000..0x10FF  IVT (compiler emits handlers if program declares them)
0x1100..       compiled code
              ↓
              user state (allocated globals, mutable data)
              ↓
0x7FFF (or wherever code ends)

0x8000..0xBFFF  VRAM (host-mapped if FC consumer)
0xC000..0xFEFF  bank window (compiler emits per-bank if program
                              uses banked modules)
0xFF00..0xFFFF  IO / peripherals
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
  if n < 2 then return n end
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
    if save.exists() then
      save.load(self)
    else
      self.player_x = 128
      self.player_y = 96
      self.map_id = 0
    end
  end

  def update(self)
    if input.up()    then self.player_y = self.player_y - 1 end
    if input.down()  then self.player_y = self.player_y + 1 end
    if input.left()  then self.player_x = self.player_x - 1 end
    if input.right() then self.player_x = self.player_x + 1 end
  end

  def draw(self)
    display.clear(0)
    display.sprite(0, self.player_x, self.player_y)
    display.flip()
  end
end

let state = GameState()

while true do
  state.update()
  state.draw()
end
```

---

## 9. Roadmap (post-v0.1)

| Feature | Why |
|---------|-----|
| Iterator protocol | Custom `for x in custom_collection` (v0.1 special-cases ranges, arrays, strings) |
| Async / coroutines | Game-dev needs them; deferred until cooperative-multitasking story is sorted |
| **Mutable closures** | Capture-by-reference. v0.1 captures by value; the example uses the intended end state for clarity |
| Traits / interfaces | Polymorphism without inheritance. Ruled out for v0.1 (single inheritance + enums cover the J-RPG use case); reopen if a real consumer surfaces friction |

---

## 10. Reference & divergence from eevee-source

The [eevee-source](https://github.com/salty-max/eevee-source)
prototype provides the conceptual base — keywords (`let`, `do`,
`end`, `if/then/else`, `def`, `class`, `lambda`, `match`), a
recursive-descent parser, expression precedence chain.

This v0.1 spec **diverges** on:

| eevee-source | gero-lang v0.1 | Why |
|--------------|----------------|-----|
| Statements end with `;` | Statements end at newline | Less noise |
| Untyped (dynamic) | Typed at let/fn boundaries | 16-bit target needs known widths |
| No imports / single file | `use` modules | J-RPG-scale projects need them |
| `++` / `--` operators | Dropped | `+= 1` covers it |
| `print` as statement | Same — kept | Old-school BASIC vibe matches |
| Basic `match` (literals + wildcards) | Rust-style: enums + destructuring + guards + range patterns + exhaustiveness | ADTs are how a language stays honest at scale |

**Carried forward from eevee-source unchanged:**

- First-class functions (assign, pass, return, store)
- Static lexical scope (all functions are closures over their
  definition site)
- Lambda functions (anonymous, first-class)
- Inline scoped computation (replaced by `do … end` as expression
  in v0.1; the IILE-via-lambda form still parses but is no longer
  the recommended pattern)
- Class-based OOP with single inheritance
- Imperative core (statements, mutable `let`, sequential evaluation)

Implementation will follow the same recursive-descent shape since
[knit](https://github.com/salty-max/knit) (parser-combinators) is
the natural fit — but the AST, type-checker, and pattern-match
compiler are net-new for v0.1.
