# Gero-lang — Diagnostics

The contract every gero-lang error message obeys. The parser, the
typechecker, the bake interpreter, and codegen all emit diagnostics
in the shape described here. New error categories extend this doc;
ad-hoc message shapes are rejected at review time.

This doc is paired with `docs/gero-lang.md` (the language spec).
The spec defines what programs are legal; this defines what users
see when their program isn't.

---

## 1. Philosophy

Three rules every diagnostic obeys:

1. **Point at the smallest meaningful span.** Not "this whole
   function" — the specific token / range that's wrong.
2. **Say what's wrong, then how to fix it.** A `help:` line giving
   a concrete next step turns a complaint into a guide.
3. **One pass, all errors.** The compiler collects every diagnostic
   it can recover from; a user fixing five issues runs `gero check`
   once, not five times.

What we deliberately avoid:

- Cryptic codes alone (`E0277`) without a sentence.
- Pointing at a closing brace 40 lines below the real problem.
- "Expected expression" with no hint about what *kind* of
  expression the parser was looking for.
- Stack traces, frame pointers, or compiler-internal jargon in the
  message text.

---

## 2. Anatomy

```
<severity>: <one-line summary> [<CODE>]
  --> <file>:<line>:<col>
   |
LL |   <source line>
   |   <caret + annotation>
   |
help: <one-line fix suggestion>
note: <additional context, may repeat>
```

**Header**: severity (`error` / `warning` / `note`), summary (≤ 70
chars, no trailing period), code in brackets.

**Source pointer**: `--> path:line:col` — line and column are
1-based, column counts UTF-8 code units (matches editors).

**Excerpt**: the line(s) containing the offending span. Up to 3
lines of context above / below for multi-line diagnostics.
`LL` is the 1-based line number, right-padded to align the bar `|`.

**Caret**: a row of `^` characters under the exact span, optionally
followed by a short inline annotation explaining what's wrong with
the underlined slice.

**`help:`** lines suggest concrete fixes the user can apply
verbatim. Skipped when no obvious fix exists.

**`note:`** lines add context — the binding that introduced the
constraint, the spec section that governs the rule, the related
location that produced the conflicting type. Multiple notes stack
vertically.

### 2.1 Multi-span diagnostics

When a single error involves two locations (e.g. a type used here
conflicts with the declaration there), both spans appear in the
excerpt with their own annotations:

```
error: type mismatch [E_TYPE_MISMATCH]
  --> src/game.gr:42:14
   |
40 |   let hp: i16
   |       --  --- type declared here
42 |   hp = "low"
   |        ^^^^^ expected `i16`, found `str`
   |
help: convert the value with `... as i16` or store in a `str` binding
```

### 2.2 Color rendering

Implementations render with ANSI color when stdout is a TTY:

- `error:` — bright red
- `warning:` — bright yellow
- `note:` — bright cyan
- `help:` — bright green
- Caret line — same color as the severity
- Source line — default fg, line number dim

Non-TTY output (`gero check > log.txt`) drops color but keeps shape
byte-identical.

---

## 3. Severities

| Severity | Effect | Use when |
|----------|--------|----------|
| `error` | Build fails; bytecode not emitted | The program is incorrect — typecheck failure, parse failure, semantic violation. |
| `warning` | Build continues; non-zero exit only with `--werror` | Suspicious but legal code — unused binding, unreachable arm, integer narrowing without `as`. |
| `note` | Attached to an error or warning | Adds context — never standalone. |

There is no `info:` or debug-level severity in user output. Compile
trace lives behind `gero check --verbose`.

---

## 4. Style guide

### 4.1 Message text

- **Summary** ≤ 70 chars, no trailing period, lowercase first word
  unless it's a proper noun. Example: `type mismatch`,
  `match is non-exhaustive`, `Vec(T) is not bakeable`.
- **Avoid the imperative** in summaries. The summary describes the
  problem, the `help:` describes the fix.
- **Inline annotations** under the caret are sentence fragments,
  not full sentences. `expected i16, found str` not `This is a str
  but i16 was expected.`
- **Help lines** start with a verb in the imperative — `convert`,
  `replace`, `add`, `wrap`. They state the *fix*, not the *reason*.
- **Note lines** start with a noun phrase — `the binding declared
  here`, `the spec rule requires`, `previous use at`. They state
  *context*.

### 4.2 Identifiers and quoting

- Source identifiers (var / fn / type names) in **backticks** when
  appearing in prose: `the binding `x` is nullable`.
- Type names in **backticks**: `expected `i16`, found `str``.
- Keywords in **backticks**: `the `bake` keyword requires…`.
- Annotations with **the `@` prefix**: `@no_capture`, `@bank`.

### 4.3 "Did you mean…?" suggestions

For undefined-identifier errors, the typechecker computes
Levenshtein distance against all in-scope names and offers
suggestions when distance ≤ 2:

```
error: undefined symbol `lenght` [E_UNDEFINED_SYMBOL]
  --> src/foo.gr:5:11
   |
5  |   let n = lenght(items)
   |           ^^^^^^
   |
help: did you mean `length`?
```

Multiple candidates: list up to 3, ordered by distance then
alphabetically.

---

## 5. Categories

Every diagnostic carries one of the codes below. Codes are stable
across compiler versions; renaming requires a deprecation cycle.

### 5.1 Parser (E_SYNTAX_*)

Errors raised during tokenization or recursive-descent parsing.

| Code | Meaning |
|------|---------|
| `E_SYNTAX_UNEXPECTED_TOKEN` | Token doesn't fit the grammar at this position. |
| `E_SYNTAX_MISSING_TOKEN` | Required token absent — `expected )`, `expected end`. |
| `E_SYNTAX_MALFORMED_LITERAL` | Bad escape, bad hex digit, bad fixed-point form. |
| `E_SYNTAX_AMBIGUOUS_EXPR` | Grammar would accept two readings; user must parenthesize. |
| `E_SYNTAX_HEX_PREFIX` | `0x...` rejected — use `$...`. |
| `E_SYNTAX_ANNOTATION_PLACEMENT` | Annotation doesn't attach to a following decl. |

**Mockup — missing closing keyword:**

```
error: expected `end` to close `def`-block [E_SYNTAX_MISSING_TOKEN]
  --> src/foo.gr:10:1
   |
5  | def greet(name: str)
   | --- block opened here
...
10 | print "done"
   | ^^^^^ reached end-of-file with no matching `end`
   |
help: add `end` after the function body
```

**Mockup — hex prefix:**

```
error: hex literals use `$`, not `0x` [E_SYNTAX_HEX_PREFIX]
  --> src/foo.gr:3:18
   |
3  |   @addr 0xFE40
   |         ^^^^^^
   |
help: write `$FE40` instead
```

### 5.2 Type errors (E_TYPE_*)

Raised by the typechecker after parsing succeeds.

| Code | Meaning |
|------|---------|
| `E_TYPE_MISMATCH` | A value of type X is used where type Y is required. |
| `E_TYPE_UNDEFINED` | Type name doesn't resolve to a declaration. |
| `E_TYPE_ARG_COUNT` | Wrong number of args at a call site. |
| `E_TYPE_AMBIGUOUS_INFER` | Inference can't pin a single type. |
| `E_TYPE_RECURSIVE_NO_RET` | Recursive fn missing return annotation. |
| `E_TYPE_INVALID_CAST` | `as T` between incompatible types. |
| `E_TYPE_NARROWING` | Implicit narrowing (warning by default). |

**Mockup — type mismatch in let init:**

```
error: type mismatch [E_TYPE_MISMATCH]
  --> src/foo.gr:12:18
   |
12 |   let x: i16 = "hello"
   |          ---   ^^^^^^^ found `str`
   |          |
   |          expected `i16` because of this annotation
   |
help: parse the string with `str.to_i16("hello")` or change `x`'s
      annotation to `str`
```

**Mockup — wrong arg count:**

```
error: function `draw` takes 2 arguments, called with 3 [E_TYPE_ARG_COUNT]
  --> src/render.gr:18:3
   |
18 |   draw(player, screen, 0)
   |   ^^^^                 - extra argument
   |
note: `draw` declared at src/render.gr:5:1
   |
5  | def draw(actor: Player, target: Screen)
```

**Mockup — ambiguous inference:**

```
error: cannot infer type for parameter `n` [E_TYPE_AMBIGUOUS_INFER]
  --> src/util.gr:3:13
   |
3  | def double(n)
   |            ^ used as `i16` and as `u8` at different call sites
   |
note: called with `i16` at src/main.gr:7:3
note: called with `u8` at src/main.gr:9:3
help: add an explicit annotation: `def double(n: i16)` or
      `def double(n: u8)`
```

**Mockup — recursive without return type:**

```
error: recursive function needs an explicit return type [E_TYPE_RECURSIVE_NO_RET]
  --> src/math.gr:1:1
   |
1  | def fib(n: i16)
   | ^^^^^^^^^^^^^^^^
4  |   return fib(n - 1) + fib(n - 2)
   |          ----------- self-reference
   |
help: add `-> i16` after the parameter list
note: the compiler cannot infer the return type through a
      self-reference; an annotation is required
```

### 5.3 Nullable (E_NULL_*)

The `T?` (nullable) family. Per spec §3.4.1.

| Code | Meaning |
|------|---------|
| `E_NULL_DEREF` | Dereferencing a nullable without a prior nil-check. |
| `E_NULL_NON_POINTER` | `T?` applied to a non-pointer-like type. |
| `E_NULL_NIL_TO_NONNULL` | Passing `nil` where the parameter is non-nullable. |

**Mockup — deref without check:**

```
error: dereferencing nullable without nil-check [E_NULL_DEREF]
  --> src/dialog.gr:8:3
   |
6  |   let p: Player? = find_player()
   |       -                          declared nullable here
7  |
8  |   p.greet()
   |   ^^^^^^^^^ `p` may be nil at this point
   |
help: guard with `if p != nil` before dereferencing
note: see §3.4.1 — gero requires an explicit nil-check; there is
      no `?.` propagation operator
```

**Mockup — non-pointer nullable:**

```
error: `T?` cannot be applied to `i16` [E_NULL_NON_POINTER]
  --> src/state.gr:4:14
   |
4  |   let n: i16? = nil
   |          ^^^^
   |
help: use a sentinel constant for absent integer values, e.g.
      `const NOT_FOUND: i16 = -1`
note: `T?` is restricted to pointer-like types (`str`, classes,
      function pointers) — see §3.4.1
```

### 5.4 Match (E_MATCH_*)

`match` arm coverage and reachability. Per spec §4.8.

| Code | Meaning |
|------|---------|
| `E_MATCH_NON_EXHAUSTIVE` | Enum scrutinee missing a variant arm. |
| `E_MATCH_UNREACHABLE_ARM` | An arm can never match (covered by earlier arm). |
| `E_MATCH_REDUNDANT_GUARD` | `when` guard whose negation is impossible. |
| `E_MATCH_BIND_TYPE` | Pattern binds a payload of the wrong type. |

**Mockup — non-exhaustive:**

```
error: match is non-exhaustive [E_MATCH_NON_EXHAUSTIVE]
  --> src/event.gr:12:3
   |
12 |   match e
   |   ^^^^^^^ missing case: `Event.Tick`
13 |     case Event.Quit => quit()
14 |     case Event.KeyDown(_) => handle_key()
   |
help: add a wildcard arm — `case _ => ...` — or list every variant
note: `Event` declared at src/event.gr:2:1 with 3 variants
```

**Mockup — unreachable:**

```
warning: unreachable arm [E_MATCH_UNREACHABLE_ARM]
  --> src/event.gr:15:5
   |
13 |     case Event.KeyDown(_) => handle_key()
   |          ---------------- covers all `KeyDown` payloads
14 |     case Event.MouseClick(x, y) => hit(x, y)
15 |     case Event.KeyDown(0x1B) => quit()
   |          ^^^^^^^^^^^^^^^^^^^ this pattern is already covered
   |
help: re-order arms — put more-specific patterns first
```

### 5.5 References (E_REF_*)

The `&T` borrowed-reference family. Per spec §3.4.4.

| Code | Meaning |
|------|---------|
| `E_REF_STACK_LIFETIME` | Returning `&local` from a function. |
| `E_REF_TEMPORARY` | `&` applied to an expression with no addressable storage. |
| `E_REF_DOUBLE` | `&&T` rejected. |
| `E_REF_NULLABLE` | `(&T)?` rejected — references are non-nullable. |

**Mockup — stack lifetime:**

```
error: returning reference to local binding [E_REF_STACK_LIFETIME]
  --> src/util.gr:5:10
   |
3  | def make() -> &Stats
   |               ------ declared return type
4  |   let s = Stats { hp: 0, mp: 0 }
   |       - stack-local lives only until end of `make`
5  |   return &s
   |          ^^ this reference would dangle after `make` returns
   |
help: return the value by copy (`-> Stats`), or store the value in
      a class field / static binding before taking its address
```

**Mockup — temporary:**

```
error: cannot take a reference to a temporary [E_REF_TEMPORARY]
  --> src/math.gr:7:18
   |
7  |   let r = update(&(a + b))
   |                  ^^^^^^^^ no addressable storage for `a + b`
   |
help: bind the expression first: `let sum = a + b; update(&sum)`
```

### 5.6 Annotations (E_ANN_*)

Annotation semantics and conflicts. Per spec §3.7.

| Code | Meaning |
|------|---------|
| `E_ANN_UNKNOWN` | `@name` not in the recognized set. |
| `E_ANN_CONFLICT` | Two annotations contradict each other. |
| `E_ANN_BAD_TARGET` | Annotation applied to the wrong kind of decl. |
| `E_ANN_BAD_ARG` | Wrong arg shape (`@bank` needs a literal, etc.). |
| `E_ANN_INLINE_TOO_LARGE` | `@inline` body exceeds the spec limit. |
| `E_ANN_CAPTURE_VIOLATION` | `@no_capture` violated by an inner closure. |

**Mockup — `@inline` too large:**

```
error: `@inline` function body is too large [E_ANN_INLINE_TOO_LARGE]
  --> src/draw.gr:4:1
   |
3  | @inline
4  | def render_actor(a: &Actor)
   | ^^^^^^^^^^^^^^^^^^^^^^^^^^^ 41 instructions after lowering
   |
note: `@inline` is capped at 32 instructions (spec §3.7.2)
help: remove `@inline` to let the compiler call this normally,
      or split the function into smaller pieces
```

**Mockup — `@no_capture` violation:**

```
error: closure mutates captured binding inside `@no_capture` function [E_ANN_CAPTURE_VIOLATION]
  --> src/loop.gr:6:11
   |
3  | @no_capture
4  | def hot_frame()
5  |   let n = 0
   |       - captured here
6  |   let inc = || n = n + 1
   |           ^^^^^^^^^^^^^^ mutates `n` — would heap-promote
   |
note: `@no_capture` forbids capture-and-mutate so this function
      cannot trigger a hidden heap alloc (spec §3.7.2 / §4.7.2)
help: refactor to take the counter as a parameter, or remove
      `@no_capture` if the alloc is acceptable
```

**Mockup — conflict:**

```
error: `@final` and `@abstract` cannot coexist [E_ANN_CONFLICT]
  --> src/entity.gr:1:1
   |
1  | @final
2  | @abstract
   | ^^^^^^^^^ conflicts with `@final` on line 1
3  | class Player
```

### 5.7 Bake (E_BAKE_*)

Compile-time evaluator restrictions. Per spec §3.8.

| Code | Meaning |
|------|---------|
| `E_BAKE_MMIO_ACCESS` | Reading / writing an `@addr` binding inside `bake`. |
| `E_BAKE_NON_BAKEABLE_VALUE` | Result type can't be baked (Vec, class, etc.). |
| `E_BAKE_ASM_INSIDE` | `asm "..."` inside a `bake` body. |
| `E_BAKE_BUDGET_EXCEEDED` | Instruction budget overrun. |
| `E_BAKE_FORBIDDEN_CALL` | Calling a non-bake fn outside the allowlist. |

**Mockup — MMIO access:**

```
error: MMIO access inside `bake` [E_BAKE_MMIO_ACCESS]
  --> src/init.gr:8:3
   |
2  | @addr $FE40
3  | @volatile
4  | let DISPCTL: u8 = 0
   |     ------- declared as memory-mapped IO here
...
7  | bake def setup_palette() -> u8
8  |   return DISPCTL
   |          ^^^^^^^ hardware doesn't exist at compile time
   |
note: bake code runs in a pure evaluator with no VM; `@addr`
      bindings have no compile-time value (spec §3.8)
help: read `DISPCTL` from regular runtime code, or pass the
      relevant value as a parameter
```

**Mockup — non-bakeable result:**

```
error: result of `bake` cannot contain `Vec(T)` [E_BAKE_NON_BAKEABLE_VALUE]
  --> src/init.gr:3:1
   |
3  | bake def build_items() -> Vec(Item)
   | ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
   |
note: `Vec(T)` is heap-allocated, which has no compile-time meaning
      (spec §3.8); class instances and function pointers are
      similarly rejected
help: return a fixed-size array `[Item; N]` instead
```

**Mockup — budget exceeded:**

```
error: bake instruction budget exceeded [E_BAKE_BUDGET_EXCEEDED]
  --> src/tables.gr:6:5
   |
3  | bake def expensive()
4  |   let n = 0
5  |   while n < 200_000_000
6  |     n = n + 1
   |     ^^^^^^^^^ executed 100,000,001 times before budget ran out
   |
note: the bake evaluator has a 100M-step budget per top-level
      `bake` invocation (spec §3.8) to bound compile time
help: simplify the computation, or precompute the table with a
      build script and embed the literals
```

### 5.8 Variadic (E_VAR_*)

`name: ...` parameter family. Per spec §4.6.2.

| Code | Meaning |
|------|---------|
| `E_VAR_NOT_LAST` | Variadic parameter isn't the last in the list (parse-time). |
| `E_VAR_HETEROGENEOUS` | Call site mixes types in the variadic slot. |
| `E_VAR_NO_DEFAULT` | Variadic parameter declared with a default value. |

**Mockup — heterogeneous call:**

```
error: variadic argument types must match [E_VAR_HETEROGENEOUS]
  --> src/log.gr:3:15
   |
1  | def log(fmt: str, args: ...)
   |                   --------- variadic param
2  |
3  |   log("two: $(d) and $(s)", 42, "hello")
   |                              --  ^^^^^^^ found `str`
   |                              |
   |                              first variadic arg has type `i16`
   |
help: all variadic args must share a single type; pass either two
      ints or two strings, not a mix
```

### 5.9 Casts (E_CAST_*)

`as T` operator. Per spec §3.5.1.

| Code | Meaning |
|------|---------|
| `E_CAST_INVALID` | Conversion not supported (class-to-class, function-pointer reinterpret). |
| `E_CAST_PRECISION_LOSS` | Narrowing without explicit `as` (warning). |

**Mockup — invalid cast:**

```
error: cannot cast between class types with `as` [E_CAST_INVALID]
  --> src/scene.gr:18:14
   |
18 |   let p = entity as Player
   |           ^^^^^^^^^^^^^^^^
   |
note: `as` only converts between numeric / `bool` / `char` types
      (spec §3.5.1); class hierarchy traversal goes through `match`
      with the variant tag
help: use a `match` with a `case Player { … } =>` arm to extract
      the player-specific shape
```

### 5.10 Loop labels (E_LOOP_*)

Per spec §4.5.5.

| Code | Meaning |
|------|---------|
| `E_LOOP_UNKNOWN_LABEL` | `break :name` references a label that isn't enclosing. |
| `E_LOOP_OUTSIDE` | `break` / `continue` outside any loop. |

**Mockup — unknown label:**

```
error: no enclosing loop labeled `:outer` [E_LOOP_UNKNOWN_LABEL]
  --> src/maze.gr:8:5
   |
4  | for y in 0..height :rows
5  |   for x in 0..width
6  |     if hit(x, y)
7  |       break :outer
   |             ^^^^^^ undefined
   |
help: the enclosing labels in scope are `:rows`
note: labels are loop-local; they don't propagate beyond their loop
```

### 5.11 Defer (E_DEFER_*)

Per spec §4.10.

| Code | Meaning |
|------|---------|
| `E_DEFER_CONTROL_FLOW` | `defer return / break / continue` rejected. |
| `E_DEFER_NESTED` | `defer defer ...` (pointless, doesn't compose). |

**Mockup — defer with return:**

```
error: `defer` body cannot use control flow [E_DEFER_CONTROL_FLOW]
  --> src/cleanup.gr:6:9
   |
6  |   defer return cleanup_result()
   |         ^^^^^^ `defer` body cannot `return`, `break`, or `continue`
   |
help: compute the value into a local first; defer the side effect:
        let result = cleanup_result()
        defer print result
note: defers run after the enclosing block's control flow is
      already decided (spec §4.10)
```

---

## 6. Error code registry

Codes are stable. New ones append; old ones never change meaning.

| Code | Category | First introduced |
|------|----------|------------------|
| `E_SYNTAX_UNEXPECTED_TOKEN` | Parser | v0.3 |
| `E_SYNTAX_MISSING_TOKEN` | Parser | v0.3 |
| `E_SYNTAX_MALFORMED_LITERAL` | Parser | v0.3 |
| `E_SYNTAX_AMBIGUOUS_EXPR` | Parser | v0.3 |
| `E_SYNTAX_HEX_PREFIX` | Parser | v0.3 |
| `E_SYNTAX_ANNOTATION_PLACEMENT` | Parser | v0.3 |
| `E_TYPE_MISMATCH` | Typechecker | v0.3 |
| `E_TYPE_UNDEFINED` | Typechecker | v0.3 |
| `E_TYPE_ARG_COUNT` | Typechecker | v0.3 |
| `E_TYPE_AMBIGUOUS_INFER` | Typechecker | v0.3 |
| `E_TYPE_RECURSIVE_NO_RET` | Typechecker | v0.3 |
| `E_TYPE_INVALID_CAST` | Typechecker | v0.3 |
| `E_TYPE_NARROWING` | Typechecker | v0.3 |
| `E_NULL_DEREF` | Nullable | v0.3 |
| `E_NULL_NON_POINTER` | Nullable | v0.3 |
| `E_NULL_NIL_TO_NONNULL` | Nullable | v0.3 |
| `E_MATCH_NON_EXHAUSTIVE` | Match | v0.3 |
| `E_MATCH_UNREACHABLE_ARM` | Match | v0.3 |
| `E_MATCH_REDUNDANT_GUARD` | Match | v0.3 |
| `E_MATCH_BIND_TYPE` | Match | v0.3 |
| `E_REF_STACK_LIFETIME` | References | v0.3 |
| `E_REF_TEMPORARY` | References | v0.3 |
| `E_REF_DOUBLE` | References | v0.3 |
| `E_REF_NULLABLE` | References | v0.3 |
| `E_ANN_UNKNOWN` | Annotations | v0.3 |
| `E_ANN_CONFLICT` | Annotations | v0.3 |
| `E_ANN_BAD_TARGET` | Annotations | v0.3 |
| `E_ANN_BAD_ARG` | Annotations | v0.3 |
| `E_ANN_INLINE_TOO_LARGE` | Annotations | v0.3 |
| `E_ANN_CAPTURE_VIOLATION` | Annotations | v0.3 |
| `E_BAKE_MMIO_ACCESS` | Bake | v0.3 |
| `E_BAKE_NON_BAKEABLE_VALUE` | Bake | v0.3 |
| `E_BAKE_ASM_INSIDE` | Bake | v0.3 |
| `E_BAKE_BUDGET_EXCEEDED` | Bake | v0.3 |
| `E_BAKE_FORBIDDEN_CALL` | Bake | v0.3 |
| `E_VAR_NOT_LAST` | Variadic | v0.3 |
| `E_VAR_HETEROGENEOUS` | Variadic | v0.3 |
| `E_VAR_NO_DEFAULT` | Variadic | v0.3 |
| `E_CAST_INVALID` | Casts | v0.3 |
| `E_CAST_PRECISION_LOSS` | Casts | v0.3 |
| `E_LOOP_UNKNOWN_LABEL` | Loop labels | v0.3 |
| `E_LOOP_OUTSIDE` | Loop labels | v0.3 |
| `E_DEFER_CONTROL_FLOW` | Defer | v0.3 |
| `E_DEFER_NESTED` | Defer | v0.3 |
| `E_UNDEFINED_SYMBOL` | Name resolution | v0.3 |

---

## 7. Implementation contract

Every gero-lang pass that surfaces diagnostics MUST:

1. Build them through a shared `Diagnostic` struct that carries the
   code, severity, primary span, secondary spans (with their own
   annotations), help, and notes.
2. Render via a single formatter that produces the exact layout
   shown in §2 — including alignment, color decisions, and excerpt
   construction.
3. Collect all diagnostics in a single per-program list, returned
   alongside the pass's primary output. Never `panic` or `exit`
   from a user-program error.
4. Emit at most **one diagnostic per root cause**. If a missing
   `end` would otherwise produce 10 downstream syntax errors, the
   parser recovers and emits only the first.

`gero check` runs every pass that can emit diagnostics — lexer,
parser, typechecker, bake interpreter, codegen sanity — and prints
all of them before exiting non-zero. There is no "silent build"
path for errors; warnings are always printed too (but don't fail
the build unless `--werror` is passed).

### 7.1 Per-file grouping

Output mirrors the asm-side shape (`apps/gero-cli/diagnostics.zig`
→ `printAllFailures`):

```
<N> errors in <M> files

src/foo.gr
  <diagnostic 1>
  <diagnostic 2>

src/bar.gr
  <diagnostic 3>
```

Rules:

- A single summary header on top: `<N> error(s) in <M> file(s)`.
  Pluralized correctly.
- Files appear in the order they were checked (typically the
  command-line order, or the dependency-resolved import order).
- Within a file, diagnostics are sorted by source byte offset
  ascending — earlier in the file first.
- Empty line between file groups.
- A file with zero diagnostics doesn't get a header.

This matches what `gero check` already does on the asm side; the
lang front-end reuses the same renderer so a mixed-project build
(asm + lang) prints under one unified summary.

---

## 8. Testing diagnostics

Diagnostic regressions are catastrophic — they devalue every error
message the user has learned to read. Every diagnostic emission
site MUST have a paired test that:

1. Constructs a minimal source that triggers exactly that code.
2. Parses, asserts the diagnostic with that code is present,
   asserts the span covers the documented range.
3. Optionally asserts the rendered output matches a snapshot.

Test naming follows the asm side: `tests/lang/<pass>.test.zig`
groups per-pass coverage; a separate `tests/lang/diagnostics.test.zig`
holds the cross-pass diagnostic suite when patterns repeat.

The lint rule `mirror` enforces the pairing between
`src/lang/<pass>.zig` and `tests/lang/<pass>.test.zig`.

---

## 9. Machine-readable output (`--format=json`)

Editors, CI, and external tooling consume diagnostics through the
JSON format the asm side already ships (`gero check --format=json`).
The lang front-end emits through the **same** schema — one report
per `gero check` invocation, all files combined.

Schema (mirrors `apps/gero-cli/diagnostics.zig::printJsonReport`):

```json
{
  "version": 1,
  "diagnostics": [
    {
      "file": "src/foo.gr",
      "line": 12,
      "column": 18,
      "severity": "error",
      "code": "E_TYPE_MISMATCH",
      "message": "type mismatch",
      "span": { "start": 234, "end": 241 },
      "help": "convert with `... as i16` or use a literal",
      "notes": [
        {
          "file": "src/foo.gr",
          "line": 12,
          "column": 7,
          "message": "expected `i16` because of this annotation"
        }
      ]
    }
  ],
  "files_checked": 3,
  "files_failed": 1
}
```

Rules:

- Stdout carries the JSON object — nothing else. Stderr stays free
  for host I/O failures.
- `version` is the schema version; bump on any breaking field
  change. Consumers should check it.
- One JSON document per `gero check` run, not one per file. The
  consumer iterates `diagnostics[]` to group by file if needed.
- Codes use the registry in §6. Severities are exactly `"error"`,
  `"warning"`, or `"note"`.
- `notes[]` is the secondary-span / context list — same as the
  human-readable `note:` lines but structured.
- The `span` byte offsets are into the **original source file**
  (not a fused source map). Editors can map back via `(line,
  column)` and the diagnostic's `file`.

## 10. Editor integration (LSP)

The JSON output is the contract; an LSP server bridges it to
editors. The `gero lsp` command (planned in #204) reads the JSON
report and emits LSP `Diagnostic` notifications — the inline-lint
squiggles, hover summaries, and quick-fix actions every editor
expects.

LSP `Diagnostic` mapping:

| LSP field | Gero source |
|-----------|-------------|
| `range` | The diagnostic's `span` resolved to LSP positions |
| `severity` | `error`/`warning`/`note` → 1/2/3 |
| `code` | `E_*` registry code |
| `message` | The human-readable summary + help line |
| `relatedInformation[]` | The `notes[]` array, each mapped to an LSP `DiagnosticRelatedInformation` |

What editor integration unlocks once `gero lsp` lands:

- Inline squiggles under exact spans, updated on every keystroke.
- Hover popups showing the full diagnostic including `help:` and
  `note:` lines.
- "Quick fix" actions for diagnostics that carry a single
  unambiguous fix (e.g. `E_SYNTAX_HEX_PREFIX` → "replace `0x` with
  `$`"). The diagnostic emitter marks fixable diagnostics with a
  `"fix"` field; the LSP server translates to LSP `CodeAction`.
- "Go to declaration" / "find references" — separate LSP work, not
  driven by diagnostics, but the symbol resolution that the
  typechecker performs feeds it too.

Until `gero lsp` ships, editor integration is one of:

1. Run `gero check --format=json` on save, parse the output in a
   VS Code task / Vim quickfix.
2. Use the existing tree-sitter grammar (`editors/tree-sitter-gero/`)
   for syntax highlighting only — no semantic diagnostics.
3. Run `gero check` in a terminal pane and click line:col links.
