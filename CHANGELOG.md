# Changelog

All notable changes to gero are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project will adhere to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
from v1.0.0 onward.

## v0.5.4 - 2026-09-20

The release where a host can drive a program's functions itself.

`run` executes from the entry point until halt, which is the whole of
what an embedder could do. It is not enough for a host that owns the
frame: a console calling a cart's `_init` once and its `_update` and
`_draw` every frame needs three functions out of one image, sharing
one memory. Compiling a separate image per function — what `gero test`
does — gives three programs that share nothing.

`VM.call` enters the way `call Addr` does and hands control back when
the callee returns. It restores `sp` and `fp` whatever happened
inside, reports halting and faulting rather than passing them off as
a return, and takes an instruction budget, because a host calling
into a program it did not write should report a runaway instead of
hanging on one.

Doing this outside the VM means copying a calling convention only
this repo owns, and getting it wrong is quiet: pushing the return
address alone leaves `ret` popping whatever was underneath.

Which is how the second half of this release was found. The handler
documenting `ret` said `0x82`; the dispatch table binds `0xA2`. So
did sixty-one others — every jump, every bitwise operation, `swap`,
`nop`, the flag ops, half of `mov` — left behind by an opcode-map
renumbering. A reader learning the ISA from the source got the wrong
byte more often than the right one. They are corrected, and `gero
lint` now checks each one against the table so they cannot part
again.

### Added

- `VM.call` runs a function in a loaded program and hands control back when it returns, for a host driving a program's functions itself — a console calling a cart's per-frame entry points, a debugger evaluating a call. It enters the way `call Addr` does, restores `sp` and `fp` on every path, and takes an instruction budget, because a host calling into a program it did not write should report a runaway rather than hang on one. `disasm.Symbols.addressOf` is the reverse of `lookup`, for finding that function by name.

### Fixed

- Sixty-two VM handlers documented an opcode the dispatch table does not bind them to — every jump, every bitwise op, every subroutine instruction and more, left behind by an opcode-map renumbering. A reader learning the ISA from the source got the wrong byte more often than the right one. `gero lint` now checks each handler's `/// 0xNN` against `dispatch.zig`, so the two cannot drift again.

## v0.5.3 - 2026-09-20

The release where a host can hand a program its own environment.

Ambient modules already let an embedding host put names in scope
without the program importing them, but only gero's own stdlib
modules. A host with an API of its own — a console handing a cart
seventy-odd functions it never wrote a `use` line for — had no route.

It has one now, and it is an import edge the entry never wrote.
Everything that follows is machinery a `use` already drives: the
module's exports land in the entry's scope, same-named defs in two
modules get distinct symbols, `@inline` splices a body at the call
site, and a diagnostic in host source is attributed to the host
module.

The shadowing is the part that decided the design. Linking an import
leaves a name the importer declared itself alone, so a program that
defines `cls` keeps its own `cls` and loses nothing else. A prelude of
top-level defs collides instead, which would make the program an error
rather than a program that meant what it said.

Two fixes were in the way and are worth their own mention. `mem`
members did not resolve when called bare — the module's signatures
live in their own table, and only the qualified `mem.peek(a)` form
consulted it, so `poke(a, v)` after `use poke from mem` was told that
`mem` has no member `poke`. And a module whose file lacked a final
newline ran into the file fused after it, joining its last line to
another's first; the syntax error that produced was reported against
the importing file, which does not contain it.

### Added

- `resolveUseImportsVirtualAmbient` and `resolveUseImportsFromAmbient` resolve a module the entry imports without saying so, for a host that hands a program an environment rather than making it import one. The module's exports are in scope unqualified, and a name the entry declares itself wins silently — which a prelude of top-level `def`s cannot do, since it collides instead.

### Fixed

- `mem` members now resolve when called bare — ambient (§5.3.5) or selectively imported. The module's signatures live in their own table rather than the stdlib one, and only the qualified `mem.peek(a)` form consulted it, so `poke(a, v)` after `use poke from mem` reported that `mem` has no member `poke`.
- A module whose file does not end in a newline no longer runs into the file fused after it. Its last line joined the next module's first, and the syntax error that produced was reported against the importing file, which did not contain it.

## v0.5.2 - 2026-09-16

The release where gero can be depended on.

It never could. `build.zig` reads three example programs into build
options, and did so through the **process's working directory** —
which is gero's own root when gero is what you are building, and the
dependent's root when it is not. `examples/` is outside the package's
`.paths` besides, so the files are not in the tarball at all. Anything
declaring gero as a dependency got this during resolution, before
compiling a line of its own code:

```
thread panic: makeExamplesOptions: read examples/asm/hello.gas failed (FileNotFound)
```

Paths now resolve against this package's own root, and a missing
example yields an empty option rather than aborting. Adding
`examples/` to `.paths` would have worked too, and would have shipped
test fixtures to every dependent in order to satisfy a build step no
dependent runs.

Nothing about building gero itself changes: its build root has the
files, so its example gates read them exactly as before.

**This was invisible from inside the repo.** `zig build ci` is green
on v0.5.1 and on this release, because nothing in gero exercises the
package *as a package*. It surfaced the first time anything tried to
depend on gero — which, up to now, nothing had.

### Fixed

- The published package can be used as a dependency. Example fixtures resolve against the package root rather than the caller's working directory.

## v0.5.1 - 2026-09-16

A release for whoever embeds gero rather than writes it.

A host can now name stdlib modules whose members are in scope
unqualified, so the program it compiles calls `min(a, b)` having
written no `use` line:

```zig
const ambient = [_][]const u8{ "math", "mem" };
var checked = try gero.lang.typecheckAmbient(
    alloc, src, &tree.program, null, null, &ambient);
var compiled = try gero.lang.compile(
    alloc, src, &checked, .{ .ambient_modules = &ambient });
```

Off by default, and a build naming no ambient modules behaves exactly
as it did — every stdlib name still reached through `use` or a module
qualifier. Nothing that compiled against 0.5.0 compiles differently.

**An ambient name is shadowed silently**, which is the whole
difference from an import. After `use min from math`, declaring `min`
is `E_TYPE_REDEFINED` — correctly, since the author wrote both and one
is a mistake. An ambient `min` was never asked for, so a declaration
of that name simply wins:

```gero
def min(a: i16, b: i16) -> i16     -- no error; this `min` wins
  return a
end

def main()
  print min(3, 9)        -- 3, the program's own
  print math.min(3, 9)   -- 3, still reachable qualified
end
```

The rule holds at any depth, for locals, parameters and captures,
because resolution finds what is in scope first and falls back to the
ambient set only when it finds nothing.

The case it exists for is a host supplying an *environment* rather
than a library — a console handing a program the arithmetic it will
obviously need, where an import at the top of every file is ceremony
its author did not choose and cannot see a reason for. The five
always-in-scope builtins stay reserved: shadowing `assert` or `panic`
is still `E_BUILTIN_SHADOW`, because the language guarantees what
those mean.

### Added

- `gero.lang.typecheckAmbient` and `CompileOptions.ambient_modules` — stdlib modules in scope without an import, shadowable by any declaration (`lang.md` §5.3.5).

## v0.5.0 - 2026-09-16

The release where a program can point at something.

`math` carried `fixed_sin` and no cosine, and no `atan2` at all — so
the arithmetic every game needs first, aiming one thing at another,
was the arithmetic the language could not do. It now has `sin`,
`cos`, `atan2`, `flr`, `ceil`, `sgn`, and a `sqrt` that works on
integers as well as fixed-point.

**Angles are turns.** One full turn is `1.0`, so a quarter is `0.25`.
On a fixed-point machine that is not a matter of taste: a turn is
exactly the whole part of a Q16.16 value, so the fraction *is* the
angle. Wrapping costs a bit mask where degrees cost a `mod 360` on
every call, and the quarter turns come out exact rather than
depending on 360 dividing evenly.

```gero
math.sin(0.25)         -- 1.0, exactly
math.sin(2.25)         -- also 1.0; wrapping is free
math.sin(0.0 - 0.75)   -- and negative angles need no fixing up
```

**Two names lose a qualifier they never needed.** `fixed_sin` said
"the fixed-point one", but there is no integer sine to distinguish it
from — a sine returning an integer is meaningless without a scale.
`sqrt_fixed` becomes `sqrt` and dispatches on type, as `abs`, `min`
and `clamp` already did. The module was inconsistent with itself
besides, carrying the qualifier as a prefix on one name and a suffix
on the other.

### Migrating

| Was | Now |
|---|---|
| `math.fixed_sin(d)` | `math.sin(d / 360.0)` |
| `math.sqrt_fixed(x)` | `math.sqrt(x)` |

The rename is caught by the compiler. **The unit change is not** — and
it is the one to watch. `math.sin(90)` still compiles after a
search-and-replace, and now means ninety whole turns rather than
ninety degrees. Anything reading an angle from a variable needs the
`/ 360.0` as well as the new name.

### Breaking

- `math.fixed_sin(deg)` is `math.sin(turns)` — renamed **and** re-united. A full turn is `1.0`.
- `math.sqrt_fixed(x)` is `math.sqrt(x)`, now polymorphic over `i16` / `u16` / `fixed`.

### Added

- `math.cos(t)` — the cosine that was missing.
- `math.atan2(y, x)` — direction as turns, counter-clockwise from `+X`. C's argument order, not PICO-8's reversed one, and no screen-space inversion. Within 0.45°, exact on all eight compass directions.
- `math.flr(x)` / `math.ceil(x)` — round down / up. Not `as i16`, which truncates toward zero; they disagree on every negative value with a fraction.
- `math.sgn(x)` — `-1`, `0` or `1` in the operand's own type.
- `math.sqrt(x)` on integers, exact.

### Fixed

- The stdlib member-suggestion pool was a hand-sized `[16]` and `math` now declares eighteen; it is sized from the tables, so adding a builtin cannot overrun it again.

## v0.4.2 - 2026-09-15

The release where a program can hold a world.

Both of these surfaced the same way: by writing cart code against the
gtx-16 spec, which is the first time the language was asked to hold
state and draw it sixty times a second rather than compute something
and print it. Two gaps showed up on the first screenful.

`let ball: Ball = Ball { x: 160, y: 120 }` type-checked and then
failed to lower, though `lang.md` §4.4 has always said a top-level
initializer runs at program start like any other. Scalars worked;
structs, tuples and arrays did not. The startup path stored each
initializer through the accumulator, which holds exactly one value.
This is the line a program with state reaches for first — the world,
the player, the level — and it failed.

The second is that every argument had to be written at every call
site, so a function with one interesting parameter and four settings
made every caller restate the settings. A trailing parameter can now
declare the value a call may leave out. The default is emitted at the
call site, so `rect(10, 20)` compiles to exactly what
`rect(10, 20, 8, 8, 7)` compiles to — no runtime cost, and the golden
corpus matches byte for byte. Methods take defaults on the same terms,
`@static` ones included; because the default is written into the call
site, it comes from the static type of the receiver while the body
still comes from the vtable, and `super.m()` takes the ancestor's
rather than the override's.

### Added

- A trailing parameter can declare the value a call may leave out (§4.6.3).
- `E_SYNTAX_PARAM_DEFAULT` — a default on a variadic parameter, or ahead of one without.

### Fixed

- A module-level `let` can hold a struct, tuple or array.
- A diagnostic about a `use` line points at the word that is wrong.

## v0.4.1 - 2026-09-15

A submodule-pointer fix, so a clone does not depend on a dangling ref.

v0.4.0 records the `editors/vscode-gero` pointer at a commit that a
rebase-merge replaced and deleted. It still resolves — GitHub keeps
such commits reachable through the pull-request ref for a while — so
a v0.4.0 checkout initialises its submodules today and would stop
once that commit is collected. Nothing else changed.

### Fixed

- The `editors/vscode-gero` submodule points at a commit on that repo's `main`.

## v0.4.0 - 2026-09-15

The release where the editor knows what your code means.

v0.3.0 shipped a language server that reported diagnostics and
formatted a buffer. This makes it answer questions: go-to-definition,
hover, find-references and completion, for **both** languages — `.gr`
from the type-checker's own binding table, `.gas` from the
assembler's symbol table. Neither re-resolves a name the compiler
already resolved, so an editor and a build cannot disagree about what
a name means. Hovering a label in assembly tells you the address it
assembled to.

On top of that sits import tooling. An unresolved name says which
module has it, completion offers names you have not imported yet and
writes the `use` line when you accept one, an import nothing uses is
reported, and the quick-fixes to add or remove one are a keystroke
away. `gero new` and `gero init` finally ask which language you are
writing rather than assuming assembly.

The formatter grew up too. The Gero printer took no options at all
and flattened every call and struct literal onto one line however
long it ran; it now wraps what does not fit, and `gero.toml`
configures both printers — indent, width, tabs, trailing commas,
bracket spacing, `use` ordering and line endings.

**Three breaks, each small and each deliberate.** A selective `use`
now binds only the names it lists, where it used to leak the whole
module — programs that reached a name they never imported stop
compiling, and none in the example corpus did. `gero new` / `gero
init` without `--lang` exit 2 when there is no terminal to ask,
rather than silently scaffolding assembly. And `--format=json` emits
the schema its own spec documents, which moves the help text from
`note` to `help`.

### Breaking

- `gero check --format=json` emits its documented schema.
- `gero new` and `gero init` scaffold either language.
- A selective `use` from a project file binds only the names it lists.

### Added

- Completion offers names you have not imported, and imports them when you accept one.
- The Gero printer takes formatting options, and `gero.toml` configures both languages.
- An unresolved stdlib name suggests the import that would bind it, and `gero lsp` offers it as a quick-fix.
- `gero lsp` offers quick-fix code actions for `.gr`.
- `gero lsp` answers completion for `.gr`.
- `gero lsp` answers go-to-definition and hover for `.gr`.
- `gero lsp` answers go-to-definition, hover, find-references and completion for `.gas`.
- `gero lsp` answers find-references and inlay hints for `.gr`.
- Completion after a `.` offers the receiver's members.
- `gero lsp` offers imports from files the document has not mentioned.

### Fixed

- `gero check` prints the `help:` line again.
- A member list opens when you type the dot.
- Opening one document no longer clears another's diagnostics.
- `gero lsp` accepts `--stdio`.
- `math.` completes to the functions of `math`.
- Go-to-definition, hover and find-references work on type names.

## v0.3.0 - 2026-09-14

The first release with the whole toolchain in it.

v0.2.0 was an assembler, a VM and a disassembler. This adds the Gero
language — a front end with types, classes, modules, pattern matching
and separate compilation — and the tooling around both: a formatter, a
language server, a project layout, a browser module, and two books that
teach the machine and the language from nothing.

**It is a breaking release, and the break is the point.** The bytecode
format moved to 2.0, so a `.gx` built before this will not load. That
is the version field doing its job rather than failing at it: widening
`fixed` to Q16.16 changed what the formatting syscalls expect in their
registers, and a loader that accepted the old shape would run the wrong
program quietly. The memory map moved for the same reason — the bank
window sat where a fantasy console needs its registers, which made
gero's own primary consumer unimplementable.

Three things worth knowing beyond the list below:

- **`fixed` is Q16.16.** Positions across a 320×240 screen have a
  representation now; Q8.8 stopped at ±127.99, so a sprite at `x = 200`
  had none.
- **`%` is floored everywhere**, on integers and on `fixed`, so
  wrapping a value into a range never lands outside it.
- **The VM is about a hundred times faster.** Its read path copied the
  whole 64 KB address space for every byte read. Every program was
  correct and slow, which is why no test caught it and a throughput
  floor now guards it.

### Breaking

- The bytecode format is versioned, and the loader refuses a major it does not know.
- `fixed` is now Q16.16 — 32-bit storage, 16 bits integer and 16 bits fraction, range -32768.0 through 32767.99998 at 1/65536 precision. It was Q8.8: ±127.99.
- An executable statement at module scope is now a compile error. §7.1 has always said execution begins at `def main()` and the rest of a module body is declarations — `def` / `class` / `struct` / `enum` / `const` / `let` / `use` — but codegen silently dropped anything else:
- Returning a value from a function with no return type is now a compile error. §4.6 documents `def greet(who: str)` as a **void return**, but `checkReturn` skipped its compatibility check whenever the enclosing signature had no `-> T`, so the value was accepted and came back as an untyped word. With a `str` that meant `print` rendered the interned pool pointer as an integer:
- The memory map is laid out so every region can do its job.

### Added

- `zig build docs` generates the public API reference.
- feat(asm): a `heap` directive, so `sys alloc` works from assembly
- `gero fmt` no longer deletes comments inside `struct` bodies. Every `;` comment in a struct block was dropped on format — trailing a field, standalone between fields, on the opening-brace line, and between the last field and `}`. Since `gero fmt` rewrites in place and ships in the lefthook pre-commit hook, formatting a file destroyed those comments with no diagnostic and exit 0.
- The assembler can emit `sys`. It resolved `int` (`0xFC`) but not `sys` (`0xFB`), so hand-written asm could not reach the syscall surface ISA §5.13.1 defines — printing, the `format_*_to_buf` family, `alloc`, and `trap` were all unreachable. A `.gr` program printed a number with `print x`; the equivalent asm had to convert digits by hand.
- docs: the bytecode format is frozen at 0.4
- `include` and `use` resolve case-sensitively on every host. macOS and Windows volumes usually ignore case, so `include "Utils.gas"` found `utils.gas` there and nothing on Linux — a program built on the author's machine and failed in CI with a diagnostic about a file that plainly exists. The virtual file set already compared keys exactly, so the two halves of one feature disagreed.
- `gero build` compiles `.gr` projects. It previously ran the asm pipeline unconditionally, so a `gero.toml` with `entry = "src/main.gr"` fed gero-lang source to the assembler and failed with parse errors. The entry's extension now picks the front-end: `.gr` runs the gero-lang pipeline and resolves the `use` graph from that file, anything else runs the asm pipeline and its `include` directives.
- `gero check` now validates every `.gr` file end-to-end, not just ones with a `main`. It resolves `use` imports and runs codegen in a new validation mode (`compile` gained `require_entry`), so a library file with no entry point still has its bodies lowered and its codegen-only errors surfaced at check time instead of only at `gero compile`.
- `gero fmt` and `gero check` now cover `.gr` (gero-lang) sources, not just `.gas`.
- `gero compile <file.gr>` is wired end-to-end: resolves `use "..."` imports, tokenizes, parses, type-checks, lowers, writes a `.gx` archive. Output precedence: `--out <path>` wins; else `<project_root>/<[build].out>/<optimize>/<basename>.gx` when a `gero.toml` exists in an ancestor (mirrors `gero build`'s Cargo-style layout, creates the profile dir on demand); else sibling-default next to the source. A malformed manifest exits 3 rather than silently falling back.
- `gero test` runs `@test` defs in `.gr` modules alongside the existing `.gas` golden programs — one walk of `[test].include` covers both. Each module is parsed and type-checked once, then lowered once per `@test` def with that def as the entry point. A clean `hlt` passes; the `trap` fault a failed `test.assert_*` or `panic` raises fails, as does any other fault or a cycle-budget overrun. `[pattern]` filters by def name. Exit stays `7` when any test fails.
- `gero build` now caches `.gr` builds. A build records one entry per module under `<build.out>/.cache/` — its content hash, its interface hash, and the relocatable code it lowered to — and a later build does only the work the record does not already cover.
- `gero check --format=json` now emits what cli.md §3.9 documents: one JSON object, with every diagnostic in its `diagnostics` array. A `.gr` diagnostic previously trailed the object as a separate NDJSON line under different field names, so the object reported `files_failed: 1` beside an empty `diagnostics` array and `JSON.parse(stdout)` — the documented editor integration — threw on the second line. Both front-ends now report into the same array, with `.gr` diagnostics carrying `end_line` / `end_col` for the span they cover.
- `gero repl` ships — an interactive gero-lang prompt that reads lines from stdin, classifies each input (top-level decl / prelude binding / per-iteration body), compiles the assembled session on every submit, and runs the result on a fresh VM. Closes #223.
- `gero run --cycles` reports what a program cost.
- `gero run` restores a program's saved data at boot.
- `gero check --werror` escalates warning-severity diagnostics to a fatal exit code (4). Without the flag, warning-only files now print their diagnostics but exit `0` — previously every diagnostic, regardless of severity, escalated to exit 4 because the check loop didn't distinguish severities for `.gr` files.
- feat(editors): both tree-sitter grammars ship a browser build
- feat(editors): a tree-sitter grammar for `.gr`
- feat(editors): VS Code highlights `.gr`
- The wasm artifact carries both books.
- refactor(asm,lang): one `.gx` container implementation
- feat(asm,lang): a source line table in the `.gx` debug section
- A `.gx` records source paths relative to the entry file, not absolute.
- fix(vm,lang): widen the interrupt vector table to all 256 vectors
- feat(lang): `cond and x or y` is the conditional expression
- fix(lang): arrays compare by element, not by address
- `assert(cond, msg?)` and `debug_assert(cond, msg?)` are now always-in-scope builtins per spec §5.3. Both validate the cond against `bool` and the optional msg against `str` at the typechecker, and reject 0-arg / 3+arg shapes with `E_ASSERT_ARG_COUNT`. On `false` the emitted sequence prints the message via `sys print_str` (when provided) and halts the VM — the host sees the diagnostic before the clean halt. `assert` fires in every build mode; `debug_assert` is elided to zero bytecode (args not evaluated) under `--optimize=release` / `=size`, with a `W_DEBUG_ASSERT_SIDE_EFFECT` warning when a `debug_assert` arg contains a call, since the call disappears in release. Adds `CompileOptions.optimize` (`debug` / `release` / `size`) plumbed through to the codegen — same enum the CLI's `--optimize` parses. Closes #219.
- feat(lang): a call's brackets must touch what they apply to
- The `bake` compile-time evaluator per spec §3.8 is now live. `bake def name(…) -> T body end` and `bake do … end` run against a typed-AST interpreter at compile time; results land in the static-data segment so `const SIN_TABLE = make_sin_table()` ships zero runtime cost. Closes #217.
- `str` is now bakeable, as §3.8 has always specified ("`str` (interned in static data)"). The bake evaluator rejected string literals outright, so a `bake def` returning a `str` — or a struct or tuple with a `str` field — failed to compile. A baked string's bytes are now interned into the string pool and its pointer slot patched with the resolved address once the pool lays out, so a baked `str` and a runtime literal resolve identically, escapes included. Identical bytes share one pool entry.
- A checked program says which declaration each name resolves to.
- fix(lang): newlines are insignificant inside a bracket group
- Four new always-in-scope builtins fill gaps the spec already referred to but didn't define:
- The typechecker now emits `E_CAST_PRECISION_LOSS` (warning) at every "store into a typed slot" site when the source's range doesn't fit in the destination's — let-init, assignment, call args, returns, struct + class literal fields, variadic args, and method-call args. Adding an explicit `as T` cast suppresses the warning. Closes #256.
- Codegen for class inheritance — `extends`, vtable override, `super.method`, `super.field` with shadowing. Closes #260.
- Codegen for single-class OOP — instance allocation, vtable emission, constructor lowering, field read/write, and method dispatch via vtable.
- Closures — `lambda () ... end` and short-form `|args| expr` compile end-to-end. Closes #259.
- Annotation enforcement — full OOP semantics + every codegen-control annotation now wired end-to-end. Closes #262.
- Fixed-size arrays `[T; N]` now lower end-to-end in the gero-lang compiler: array literals `[a, b, c]`, repeat literals `[value; count]`, and indexed read/write `arr[i]` / `arr[i] = x`.
- `gero compile` now lowers compound assignment (`+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `|=`, `^=`, `<<=`, `>>=`) and the `++` / `--` statements. Each desugars to its plain-assignment form (`a op= b` → `a = a op b`, `x++` → `x = x + 1`) and reuses the existing store path, so it works for the same targets `=` supports — local / param / global identifiers and class fields. Previously these emitted `E_CODEGEN_UNSUPPORTED`.
- Pattern destructuring now lowers at every binding site — `let`, `if let`, `while let`, and `match` arms share one matcher.
- `gero compile` now lowers payload-carrying enum variants — construction and `match` extraction. Previously `E.A(5)` and `case E.A(n)` emitted `E_CODEGEN_UNSUPPORTED`.
- Closes #193. First slice of the gero-lang codegen — the framework that downstream slices hang instruction selection / register allocation / annotation lowering off.
- Closes #194 + #258. **M1 milestone (Core codegen walking-skeleton)** — the typed AST now lowers to real `.gx` bytecode that the VM boots, runs, and prints from.
- Closes #214. Advances #195. **M2 milestone** — control flow lowers to real bytecode. The codegen now consumes `if / else if / else`, `while`, `for x in a..b [step N]`, `repeat … until`, `match`, `break [:label]` / `continue [:label]`, and `defer` — alongside the rest of the operator set (comparisons, short-circuit `and` / `or`, `not`, bitwise / shift / mod).
- Closes #222 + nullary half of #195. Advances #216. **M3a milestone (codegen foundations)** — adds enum codegen for nullary variants, the `mem.*` stdlib (typed peek/poke + memcpy/memset + addr_of), and the typed-reference (`&T`) codegen. The class-vtable + closure pieces ride in M3b alongside the shared heap allocator.
- Closes #261. **Finishes M1** — memory-placement annotation lowering (`@bank`, `@addr`, `@zero_page`, `@volatile`, `@align`) on top-level `let` / `const` / `def`.
- `==` / `!=` now work on struct values, and `str` equality is content-based.
- `print` now renders structs and enums by value, payload-carrying enums compare structurally, and a set of pre-existing lang gaps surfaced alongside are closed (§3, §3.2.1, §3.6, §4.9, ISA §syscalls).
- Struct literals now lower as values — `Foo { ... }` constructs, and struct-typed bindings carry full value semantics (§3.4).
- **Closes out the two limitations carried forward from the memory- placement annotation PR** — cross-bank calls now auto-route through a `__call_bank` trampoline, and byte-width global stores lower to `movl` so MMIO writes no longer clobber the neighboring byte.
- Tuple support is now complete (§3.4) — the five combinations deferred from the initial tuple PR are lowered.
- Tuple values now construct, lower, and support `.N` element access (§3.4).
- `Vec(T)` — the growable dynamic array (§3.4.3) — is now implemented. The value is a 6-byte `(ptr, len, cap)` header stored inline like a struct; the backing buffer lives on the heap (`sys alloc`).
- Complete the v0.3 lang front-end: parser-level support for every feature the spec locks in. After this, the AST is the final shape the typechecker can build against.
- The typechecker now attaches a `help: did you mean \`X\`?` line to `E_UNDEFINED_SYMBOL`, `E_TYPE_UNDEFINED`, `E_TYPE_UNDEFINED_FIELD`, and `E_TYPE_UNDEFINED_METHOD` when a known name is within Levenshtein distance 2 of the user's spelling. No help line fires when no candidate qualifies — a missing suggestion beats a misleading one.
- `do … end` now lowers as an **expression** (§4.3): `let x = do … end` runs the block's scoped statements and evaluates to its last expression — for any result type, including tuples, structs, and arrays. The block's inner locals are reserved in the enclosing frame, and its defers fire without clobbering the value.
- `gero fmt` on `.gr` sources now preserves comments. The lexer captures each `-- …` line comment as a side-table (off the token stream, so the grammar is unaffected), the parser carries it on `ParseTree.comments`, and the printer re-emits leading, standalone, and trailing comments at their statement / field / case / arm boundaries. Formatting is lossless and idempotent — previously every comment was silently dropped.
- `for x in <iterable>` now lowers over every iterable shape, not just ranges. The loop variable is typed from the iterable's element type (strong-typing: it's never left untyped).
- `str.format_into(dst, fmt, args…) -> u16` formats into a buffer the caller owns and returns the byte count written, excluding the terminator. It allocates nothing.
- `$(expr:fmt)` format specs (§3.2.2) now lower. The compiler parses the spec — `[[fill]align][0][width][.precision][type]` — at compile time and formats the value through the new `format_spec_to_buf` syscall: width, left / right / center alignment, fill (incl. zero-pad, sign-aware for negatives), precision, and the type letters `d x X b o s c` (decimal, hex lower / upper, binary, octal, string, char). Works in both `let s = "…"` (heap buffer) and `print "…"`. Previously any spec was a hard compile error.
- feat(lang): `if` produces a value
- Inline assembly (`asm "<instruction>"`) now lowers (§4.11). A `{name}` operand resolves to the named local / parameter's stack slot, the single instruction is assembled through the asm layer, and its bytes are emitted in place. A form with no matching opcode is a compile error (`E_CODEGEN_INLINE_ASM`) instead of a silent `hlt`.
- `is` now accepts a class name on the RHS for runtime class-type checks via the vtable pointer:
- `gero.lang.tokenize` lands — knit-driven `.gr` lexer that ships 37 reserved keywords, identifiers, `@`-annotations, integer literals (decimal / hex / binary with underscore separators and operand-position-aware negative sign), char literals (`'A'` → u8 byte, mirroring asm's `'A'`), strings with `$( … )` interpolation (paren-depth tracked across nesting), `--` line comments (disambiguated from `--` decrement by leading whitespace), every binary / comparison / bitwise / shift / range operator, `++` / `--` as statement-only increment / decrement, and multi-error recovery via `core.ParseError`. First brick of the gero-lang compiler frontend.
- `local` now does what §5.1 always said it does. The keyword was lexed, parsed for every declaration form, and stored on the AST — and then ignored, so a `local` declaration was freely reachable from an importing module.
- feat(lang): `match` produces a value
- `match` on a nullary enum scrutinee now lowers to a jump table indexed by tag byte (spec §4.8.5 "single-arm tag dispatch") when every arm is a bare `EnumName.Variant` and no guard is present. Trailing `_` / ident wildcards remain supported as the default target for unmapped tags. Mixed-shape matches (guards, payload binders, OR-patterns, literal arms) keep the existing sequential cmp-chain. Exhaustiveness checking also extends to `bool` — `match` on a bool scrutinee must cover both `true` and `false` (or carry a wildcard), and redundant arms emit `E_MATCH_UNREACHABLE_ARM`. Closes #195.
- Each `.gr` file is now its own module namespace. Every reachable file was fused into one buffer and type-checked as a single flat scope, so two modules declaring the same top-level name collided:
- A destructuring `let` at module scope now works. §7.1 lists `let` among the declarations a module body may hold, but only the single-identifier form was lowered — a pattern bound nothing, and every later reference failed with `E_CODEGEN_UNSUPPORTED: ident not in current frame`, pointed at the *use* rather than the declaration:
- `Diagnostic` now carries a `secondary: []const SpanLabel` slice for the annotated context spans the spec mockups in `docs/lang-diagnostics.md` §5.2 / §5.3 / §5.9 describe — same- line secondaries draw a `---` underline under the source line plus a stacked `|` pointer + label below; cross-line secondaries get their own `--> path:line:col` excerpt block under the primary. Decoration enum (`.underline` / `.point`) picks dashes vs carets per span.
- feat(lang): a block may sit on one line, as in Lua
- Plain `+` / `-` / `*` on integer types now trap on overflow in debug builds and wrap two's-complement in release / size per spec §4.2.1 (Rust model). Codegen emits a per-op check after the ALU op (`jvc`/`jcc skip; int 5; skip:` — 5 extra bytes per op). On overflow the program raises arithmetic-overflow (vector `$05` per ISA §6); the default handler halts with a host-visible fault marker, and programs can install a custom `int 5` handler for diagnostic recovery. Signed `*` lowers through the new `muls` opcode so `V` correctly reflects `i16` overflow; unsigned `*` keeps `mul` (V = `high != 0`). Fixed-point ops remain wrap-only per ISA §5.4.1. The `--optimize=<debug|release|size>` flag (added by the assert builtins PR) toggles the check. Closes #218.
- `gero.lang.parse` lands — the recursive-descent parser that consumes the lexer's `TokenStream` and emits an `ast.Program`. Covers every statement and expression form in gero-lang §3-§6.
- Type-checking is now per module. Each module sees its own top-level declarations plus the exported ones of the modules it imports, and nothing else — the enum, struct, class, and def registries became per-module views swapped as the checker enters each module, rather than one flat program-wide set.
- `gero.lang.print` lands — canonical `.gr` pretty-printer per issue #231. Closes the lang front-end: parser produces an `ast.Program`, printer reverses it back to source.
- `&T` references now auto-deref for field access and method dispatch per spec §3.4.4. Given `r: &Counter`, both `r.n` and `r.method()` resolve through the pointee's class layout / vtable — the typechecker peels one reference layer before field / method resolution, and the codegen emits an extra word-load through the reference slot to reach the heap-allocated instance. Mutation through a `&T` parameter (`r.n = r.n + 10`) writes back to the caller's binding. Closes #216.
- `@static` method calls now lower (§3.7) — `ClassName.method(args)` is compiled as a direct call with no receiver, and previously only type-checked-by-accident (it produced no diagnostic *and* no code). The call is now fully type-checked (arguments, return type, variadic arity) and emitted, including struct / tuple (sret) returns and variadic `@static` methods.
- `math`, `bank`, and `test` stdlib modules now lower (§5.3), generalizing the compiler's module-call dispatch beyond `mem`.
- `str.format(fmt, args…)` (§3.2.2) now lowers — programmatic formatting for a non-literal format string. Positional `{N}` / `{N:spec}` placeholders are parsed at runtime by the new `format_runtime` syscall (`{{` / `}}` escape a literal brace), reusing the same spec engine as compile-time interpolation. Each call allocates a fresh heap buffer and returns it as a `str`.
- `str` values gained their instance members (§3.2.1): `s.len` (the byte count to the null terminator, a `u16` property), `s.at(i)` (the byte at index `i`, a `u8`, debug-bounds-trapped), and `s.cmp(other)` (byte-wise lexicographic ordering, an `i16` — `< 0` / `0` / `> 0`). They lower to the existing byte-walk primitives — no new syscall.
- fix(lang): a struct may carry an array field
- Apply the spec-locked syntax decisions from `docs/gero-lang.md` v1. Lexer and parser updates land together so the entire surface matches the spec.
- Third slice of the gero-lang typechecker. Adds operator / call / cast / assignment type checking and bidirectional integer-literal inference on top of the resolution slice.
- Eighth (final) slice of the gero-lang typechecker. Lands the diagnostic rendering pipeline documented in `docs/lang-diagnostics.md` and wires `gero check` to handle `.gr` files end-to-end.
- Sixth slice of the gero-lang typechecker. Adds field / method resolution for structs and classes (§3.4.2, §6) and tuple-destructuring + bail-pattern flow analysis for multi-return fallible calls (§3.4.1).
- Second slice of the gero-lang typechecker (#235). Adds two-pass symbol resolution and basic-form type inference on top of the slice-1 scaffolding.
- `gero.lang.typecheck` lands as a no-op walker — the first slice of the gero-lang typechecker (option B sequential PRs, parent #233). Ships the bones: type representation, scope + symbol-table primitives, and an AST walker that visits every variant. Subsequent slices populate resolution, inference, and the spec's semantic rules.
- Fourth slice of the gero-lang typechecker. Adds the semantic rules for `T?` (nullables, §3.4.1) and `&T` (references, §3.4.4), plus basic `super` ident resolution inside class methods. Builds on the operator / call / cast / assignment slice.
- Fifth slice of the gero-lang typechecker. Adds match-arm exhaustiveness checking against `enum` declarations (§4.8) and the stack-lifetime check for `return &local` (§3.4.4).
- Seventh slice of the gero-lang typechecker. Adds annotation validation (§3.7), bake-context restrictions (§3.8), and variadic call validation (§4.6.2).
- Class methods can now be variadic (`def m(self, …, args: ...)`, §4.6.2). A variadic method type-checks once against `args: (T, …, T)` and monomorphizes per call-site arity — `args.N` indexing and `str.format(fmt, args)` forwarding work in a method body, on direct, `self`, `super`, and reference receivers, including inherited methods.
- feat(apps/gero-cli): `gero lsp` — a language server for `.gas` and `.gr`
- Every parameter needs a type annotation. Omitting one is `E_TYPE_PARAM_UNANNOTATED`.
- Signed `/` and `%` are correct for a negative dividend, and floored.
- VM bump allocator — shared infrastructure for M3b's class instances and closure heap-cells.
- ISA extension: signed multiply opcodes `muls Imm16, Reg` (`0x54`) and `muls Reg, Reg` (`0x55`) added in the previously-unused 0x5X arithmetic block. `muls` interprets both operands as `i16`, produces a 32-bit signed product with the low half in `dst` and the high half in `acu`, and sets `V` / `C` when the result doesn't fit in `i16`. Companion to existing unsigned `mul` — needed because `mul`'s V flag false-positives on legitimate signed products like `(-1) × 5 = -5`. Gero-lang's debug overflow trap on `*` is the canonical consumer. Bumps `.gx` format version `0x0002 → 0x0003` (backwards-compatible additive change per ISA §10) and fixes the §10 doc's stale "high byte of version" phrasing (minor is the low byte; major is the high byte).
- `VM.snapshot` and `VM.restore` capture and reload execution state.
- Closes #263. Adds a `sys` opcode (`0xFB`) to the VM ISA for host-callback syscalls and wires the first family — `print_str` / `print_int` / `print_char` / `print_newline`.
- A program that gives up now raises a fault instead of halting like it finished. `panic`, `unreachable`, `todo`, `assert`, and a failed `test.assert_*` all printed a message and emitted `hlt` — the same instruction a clean exit uses — so nothing downstream could tell a crashed program from a successful one. `gero run` returned `0` for a program that panicked.
- feat(wasm): breakpoints via the ISA's `brk` opcode
- feat(wasm): a `wasm32-freestanding` module with a C-ABI boundary
- feat(wasm): toolchain exports over a virtual file set
- feat(wasm): VM sessions, stepping, and the print buffer

### Fixed

- The assembler accepts CRLF source. `docs/asm.md` §2 says "CRLF and LF are both accepted; classic-Mac CR is not", and the lexer implemented that — but the parser is a separate path over the same bytes and knew only `\n`, so every line of a `.gas` file saved with Windows line endings failed with "unrecognized statement" at the column of the `\r`.
- `gero compile` is no longer advertised as unimplemented. The command has been wired end-to-end since #198, but `commandIsImplemented` still reported it as planned, so `gero compile --help` printed "Not yet implemented in this build" and `gero --help` filed it under the planned section. It now carries a real help arm with usage, examples, and the output-path precedence rule.
- `gero test` and `gero bench` no longer run an imported module's entries once per file that reaches them. Discovery collected annotated defs from the whole fused program, so a `@test` in `src/util.gr` ran twice under the natural `[test].include = ["."]` — once found directly, once through `main.gr`'s `use` graph. Each module's entries now come from that module alone, which is the "each module is parsed and type-checked once" cli.md §3.4 describes.
- A subcommand refuses a flag it does not take, instead of ignoring it.
- `gero repl` now renders parse / typecheck / codegen errors with caret-style source snippets via `gero.lang.render.prettyOne`, matching the output `gero check` produces. Lexer + parser errors flow through the same `Diagnostic` shape, so secondary spans (e.g. "expected `bool` because of this annotation") show under the offending line. Warnings render but no longer block the session — the program still runs.
- Six CLI modules held inline tests that never ran. `apps/` keeps its tests in the source file rather than a `tests/` mirror, and a module has to be registered as a test root in `build.zig` for those to execute — `bench`, `gr_runner`, `build_cache`, `compile`, `repl` and `line_editor` were not.
- `gero` builds and runs on Windows. The REPL's line editor drove POSIX termios with no target guard, so the CLI failed to compile for Windows entirely — `std.posix.termios` is `void` there, a stdin handle is a `HANDLE` rather than an integer fd, and `tcgetattr` needs libc. It failed for `wasm32-wasi` for the same reason.
- Reject direct, compound, increment, and decrement assignment to immutable `const` bindings.
- `zig build wasm` now packs The Gero Book into `book.json` beside `samples.json`, so the lab can fetch the chapters rather than vendor them. Front matter and chapters 1–4 are the current contents; a chapter added under `docs/book/` is included without a build change.
- The Gero Book — front matter and the first four chapters. A guided path into gero-lang for someone who has never targeted a machine like this, building one program across the chapters rather than a fresh snippet each time.
- test: a golden bytecode corpus, gated in CI
- feat(cli): actionable messages for `.gx` load failures
- A virtual file set resolves its includes the same way on every host. `include` and `use` joined paths with the host's separator, so a set whose keys are `banks/bank0.gas` resolved on Linux and macOS and missed on Windows, where the join produced `banks\bank0.gas` — a key no set contains. The browser was unaffected (wasm32 separates with `/`), but a native Windows embedder using the overlay API saw every multi-file program fail with "include target file not found".
- Interned string literals now have debug data symbols (`str_0`, `str_1`, …), so the disassembler renders them as `data8` — with the text in a comment when it's printable ASCII — instead of decoding `"Hello"` as `inc r?65`.
- Wire the `char_lit` AST variant through the lang front-end. Before this change, `'A'` parsed as `Expr.int_lit{value=65}` — char-ness was lost in the AST, and the `Expr.char_lit` / `Pattern.char_lit` variants were dead code.
- Three `gero check` / typecheck soundness fixes:
- Cross-bank calls (`@bank N`) now pass parameters and return values correctly. The trampoline is frame-transparent: the callee reads its arguments at the same frame offsets as a direct call, so banked functions that take parameters — and that return structs / tuples — work instead of reading six bytes of stale stack.
- A program too large to compile now reports a clean diagnostic instead of panicking the compiler. Three pathological-size narrowings were hardened:
- `gero fmt` now indents `elif` arms to match their `if`. The `.gr` printer emitted `elif` at column 0 regardless of nesting depth, so any `if`/`elif` chain inside a function (or any indented block) came out misaligned. `elif` arms now carry the surrounding indent, like the `if` and `else` lines around them.
- An `@interrupt` handler no longer leaks its bank selection into the interrupted code.
- A lambda with no return-type annotation now infers its return type from the body. Previously the type came only from an explicit `-> T` or from a function-typed binding hint; with neither, it fell back to `nil`, so a lambda returning a `str` lost that type and `print` rendered the interned pool pointer as an integer:
- `print` on a nullable is now the compile error §4.9 always specified, instead of emitting a meaningless address. A scalar `T?` printed its frame-slot offset and a pointer-like `T?` printed its raw pointer:
- Fix passing value-type aggregates (`struct` / `[T; N]` / `Vec(T)` / tuple) across function and method call boundaries — both by reference and by value.
- fix(lang): drop the hidden sret pointer for every call that pushes one
- `if let` and `while let` now bind their pattern variables into the guard and body scope. Previously the typechecker inferred the matched expression but never registered the bindings, so `if let E.A(n) = e when n > 0` reported `n` as an undefined symbol in both the `when` guard and the body (§4.4.1 / §4.5.1). The checkers now open a child scope and register the pattern bindings before walking the guard and body — mirroring `match`-arm scoping.
- Closes #220. Implements `@no_capture` enforcement in the typechecker per `docs/gero-lang.md` §3.7.2.
- `v.pop()` compiles in statement position. It lowered only as an expression, so discarding the result — the natural way to use a `Vec` as a pool — failed with `E_CODEGEN_UNSUPPORTED` even though §3.4.3 documents the method.
- Widen one-byte values correctly when tuple or struct patterns bind them to local names.
- Two documents that say what gero-lang is for and why the assembler did not go away when it arrived.
- `gero check` now refuses `break` / `continue` outside a loop (`E_LOOP_OUTSIDE`) and a labeled jump that matches no enclosing loop (`E_LOOP_UNKNOWN_LABEL`). Both used to slip through typecheck and fail only at codegen under an internal code.
- `zig build clean-cache` prunes stale Zig build outputs without a full wipe. Zig content-hashes every output into `.zig-cache/o/<hash>` and never reclaims old ones, so a cross-target / multi-mode workflow (`zig build ci` — 4 release modes × 5 targets) grows the cache without bound across commits; left alone it reaches tens of GB.
- gtx-16's vblank IRQ moves from vector `0x06` to `0x07`. `0x06` is the ISA's program-initiated trap — the vector `sys trap` raises after a failed `test.assert_*`, `panic`, `unreachable` or `todo` — so a cart's frame boundary and a deliberate give-up fired the same handler, and a cart installing a vblank ISR silently swallowed its own traps.
- docs: a bytecode versioning policy
- The VM runs about 100× faster.
- `include` and `use` resolve on wasm32-wasi. Both front-ends canonicalized a path with `realpath`, which wasi does not have — it returns `OperationUnsupported` there — so a wasi `gero` could compile a single file and nothing that imported another.
- fix(wasm): `gero_disasm` returns annotated assembly, and a release carries the browser module
- feat(wasm): `gero_disasm` can emit the hex byte column
- fix(wasm): `gero_files_clear` no longer hands the file set's storage out twice
- test: a wasm runtime gate over the example corpus
- Accept correctly cased relative imports and assembly includes on Windows when the source path uses forward slashes and the filesystem returns backslashes. Compare path components without a directory-depth limit while continuing to reject case mismatches.
- Release versions below 1.0 now shift one place right: a breaking change moves the minor, everything else moves the patch. `zig build version` previously took a `bump: major` changeset straight to `1.0.0` regardless of the current version, so a release would have declared the API stable by arithmetic rather than by decision. The script can no longer produce `1.0.0` at all — at `0.9.3` a breaking change gives `0.10.0`. CHANGELOG headings still follow the level each changeset declared.

## v0.2.0 - 2026-05-15

### Breaking

- ISA repagination — every non-`mov` / non-stack / non-primary-arithmetic opcode is renumbered onto a dedicated 16-slot page so the high nibble names the family at a glance: `0x6X` bitwise, `0x7X` shifts, `0x8X` `cmp`/`tst`, `0x9X` branches, `0xAX` subroutines, `0xBX` flag control, `0xCX` misc, `0xFX` system. `Operand` gains `reg_indirect` and `indexed` so the VM schema matches the resolver's kind enum — disassembly stops special-casing by opcode byte. Every embedded `.gx` blob needs re-encoding; mnemonic + operand-grammar surface unchanged.
- ISA completion sprint — `bset memset` renamed to `bfill` (block byte-fill); the new `bset` is single-bit set. 8 new opcodes (`sext`; `asr` reg/reg + reg/imm; `btest` / `bset` / `bclr`; `mov [reg+imm], reg` + `mov reg, [reg+imm]`) for clean signed-integer + bitfield + frame-local codegen from gero-lang.
- `asm.ErrorCode.reserved_opcode` (E008) removed — never emitted by any code path, lingering placeholder for ISA additions that never materialized. ID `8` left dead so any tool that parsed the error-code table by number stays stable.

### Added

- `gero check` — validates `.gas` (files or directories, walked recursively) without writing `.gx`. Caret-style diagnostics, per-file summary, `--quiet`, `--verbose`, `--format=json`. Foundation for editor integration.
- `gero fmt` — canonical formatter for `.gas` source. In-place rewrite or `--check` diff mode; `--stdin` for editor integration; respects `; gero-fmt-ignore-*` opt-out directives for hand-formatted regions.
- `gero build` — project-aware compile. Walks ancestors for `gero.toml`, reads `[package]` + `[build]`, runs the asm pipeline, writes `<out>/<name>.gx`.
- `gero new <name>` + `gero init` — scaffold a v0.2 asm project from an in-binary template. Two-verb split (cargo / zig / poetry convention) plus optional CI + lefthook templates that invoke the gero CLI.
- `gero check` / `gero fmt` / `gero test` graduate to project-aware fallback — invoke with no positional arg inside a `gero.toml`-rooted tree and the command resolves the project automatically.
- `gero.toml` — TOML subset parser + manifest schema (`[package]`, `[build]`, `[fmt]`, `[test]`) + `findManifest` ancestor walk. Foundation for every project-aware subcommand.
- `bank_call <label>` / `bank_jump <label>` — cross-bank pseudo-instructions; the assembler looks up which bank the target lives in and emits the equivalent `mov $bank, mb` + `call`/`jmp <addr>` pair automatically.
- `ifdef` / `ifndef` / `endif` — NASM/ca65-style conditional assembly with include-guard semantics.
- Zero-page mov forms — `mov` against an `$XX`-sized address downgrades to a 1-byte ZP variant automatically (no source change needed).
- `and` / `or` / `xor` reg-imm variants now follow the project's canonical `(src, dst)` operand order, aligning with every other ALU op.

### Changed

- Canonical printer richer — trailing comments stay inline with their host (padded to column 32 by default for vertical alignment across a block) instead of demoting to standalone lines. Three new `PrintOptions` knobs for column, alignment, and hex-case control.
- `gero check` + `gero fmt --check` are wired into `zig build ci` and the lefthook pre-commit hook over the example corpus.

### Fixed

- `gero asm` / `gero build` / `gero check` now report a clean diagnostic (`[E017] sram_banks count exceeds declared bank count`) when a `.gas` file declares `sram_banks N` without enough matching `bank` directives, instead of panicking in `vm.parseGx` on the just-emitted image. Codegen catches the loader invariant at layout time and points the caret at the offending `sram_banks` directive.

## v0.1.2 - 2026-05-13

### Fixed

- Release tarballs now include `x86_64-macos` — Intel Mac users can install via the Homebrew tap (a follow-up tap update lands separately) or download the `gero-vX.Y.Z-x86_64-macos.tar.gz` artifact directly. The release matrix in `.github/workflows/release.yml` cross-builds the target alongside the existing `aarch64-macos`, `x86_64-linux`, both Windows architectures, and `wasm32-wasi`.
- `gero --version` now reflects the actual package version. Previously `apps/gero-cli/cli.zig` held a hard-coded `version_string = "0.0.0"` that `zig build version` didn't touch, so every shipped binary — including v0.1.0 and v0.1.1 — printed `gero 0.0.0` regardless of the release tag. `build.zig` now reads `build.zig.zon`'s `.version` field and injects it into the CLI via the `build_options` module, making `build.zig.zon` the single source of truth.

## v0.1.1 - 2026-05-13

### Fixed

- Release tarballs now ship the `gero` CLI binary. v0.1.0 artifacts shipped `zig-out/lib/libgero.a` only — the executable was built but not copied into the dist archive, so the GitHub Release tarballs were unusable end-to-end. The packaging step now copies `zig-out/bin/` alongside `zig-out/lib/` and `zig-out/include/`.

## v0.1.0 - 2026-05-13

First tagged release. The asm path — VM kernel, assembler,
disassembler, and CLI — is feature-complete. The gero-lang compiler
lands in v0.2.0.

### VM kernel

- 16-bit register machine with **90 opcodes** across 11 families:
  `mov`, arithmetic, logical/shift/rotate, compare/test, stack,
  control flow, subroutine, misc/flag/system, plus two block-memory
  ops.
- Memory map: zero page + low RAM + IVT + user RAM + mapped region A
  (VRAM staging) + 16 KB bank window at `0xC000-0xFEFF` + mapped
  region B (IO page).
- Banks + persistent SRAM — `mb` register selects which bank slot the
  window maps to; the last `sram_bank_count` banks are flushed to a
  `.sav` file on `int $21`.
- Interrupts — `flg.I` global enable + per-vector `im` mask;
  `raiseIrq` for maskable, `raiseNmi` for non-maskable.
- `MemoryMapper` + `Device` interface so hosts (gtx-16 future) can
  claim address ranges for memory-mapped IO without VM-side changes.
- `.gx` parser, boot helper, and per-step cycle accounting.

### Assembler

- knit-based `.gas` lexer + parser: identifiers, numeric / char /
  string literals, full operator + punctuation set.
- Directives: `const NAME = <expr>`, `data8`, `data16`, `struct`,
  `org $ADDR`, `include` (with cycle detection).
- Codegen pass with symbol table + complex address operand forms.
- Bank + SRAM emission.
- Debug-symbol section so the disassembler can recover label names.
- Structured error reporting with E001..E016 codes.

### Disassembler

- `.gx` → `.gas` decoder + pretty-printer.
- Whole-cart default mode — base image + every bank, each prefixed
  with a section header. `--bank=N` scopes the view to a single bank
  slot.
- `--show-bytes` / `--no-show-bytes` toggles the hex-bytes gutter.
- `--check-roundtrip` drives `asm → disasm → asm` and exits non-zero
  on byte divergence — wired into CI against every shipped example.
- Collapses runs of 4+ consecutive `$00` bytes to keep output
  skim-able.

### CLI

- `gero asm` — assemble `.gas` to `.gx`.
- `gero run` — execute a `.gx`, with `int $21` SRAM flush to `.sav`.
- `gero disasm` — disassemble a `.gx` (whole cart by default).
- `gero info` — pretty-print a `.gx` header.
- `gero test [pattern]` — walk `tests/asm/programs/`, diff stdout
  against `.expected` golden files, exit 7 on any failure.
- Per-subcommand help, "did you mean?" suggestions on typos,
  ANSI / `NO_COLOR`-aware output.

### Examples

- Five worked programs under `examples/asm/` — `hello`, `fib`,
  `counter`, `save`, `banks/`. Each ships with a `.expected` golden
  file driven by `zig build test-examples` on every PR.

### Tooling

- `zig build ci` mirrors the full CI pipeline (lint + 4 release
  modes + cross-target compile + examples gate).
- Cross-targets compiled on every PR: `x86_64-linux`,
  `aarch64-macos`, `x86_64-windows`, `aarch64-windows`,
  `wasm32-wasi`.

### Breaking

- All two-register binary instructions (`mov`, `add`, `sub`, `mul`,
  `div`, `divs`, `adc`, `sbc`, `and`, `or`, `xor`) now read
  **src-first** (AT&T-style): `mov src, dst`. Previously reg-reg
  forms were silently dst-first while immediate forms were
  src-first; the inconsistency would have bit every example and
  every future language consumer. `cmp` / `tst` and shift / rotate
  ops keep their current shape (no dst). `.gx` files that used any
  flipped reg-reg form must be re-assembled. Closes #94.
