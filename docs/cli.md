# `gero` CLI — Reference

Single binary `gero` with subcommands — `git` / `cargo` / `go` style.
Built from `apps/gero-cli/` in this repo, installed as `zig-out/bin/gero`.

This doc is the user-facing contract for the toolchain. Every
command's flags, exit codes, and behavior should match what's spec'd
here.

---

## 1. Overview

```
gero <subcommand> [flags] [args]
```

Discover the command list with `gero --help`. Discover per-command
flags with `gero <cmd> --help`.

A single `gero` binary covers asm, compile, run, test, bench, fmt,
check, build, disasm, info, repl, lsp. The bare-VM runtime is the only
target this repo produces — fantasy-console hosts (e.g. gtx-16)
live downstream and consume `.gx` files as library inputs.

---

## 2. Common flags

Flags shared by more than one subcommand. **Each is accepted only by
the subcommands whose own `--help` lists it** — using one elsewhere is
a usage error (exit 2), not a silently ignored argument:

```
$ gero build --optimize=release
error: --optimize=release is not a flag for `gero build` — run `gero build --help` for the ones it takes
```

That matters because the alternative is worse than a typo.
`--optimize` is a reasonable guess for "build the release profile",
which `[build].optimize` owns instead (§8) — accepting it would build
the debug profile and say nothing.

| Flag | Default | Accepted by | Effect |
|------|---------|-------------|--------|
| `--help` / `-h` | — | every subcommand | Print help for the command and exit 0. |
| `--color=<m>` / `-c`, `--no-color` | `auto` | every subcommand | `auto` (TTY + `NO_COLOR`) / `always` / `never`. |
| `--quiet` / `-q` | off | all but `run`, `test`, `info`, `repl`, `lsp` | Suppress non-error output. |
| `--verbose` / `-v` | off | `asm`, `compile`, `run`, `test`, `check`, `build` | Extra info: timings, allocation counts, intermediate sizes. |
| `--out=<path>` / `-o` | (per-cmd default) | `asm`, `compile` | Output path. |
| `--optimize=<mode>` / `-O` | `debug` | `compile` | `debug` / `release` / `size`. Mirrors Zig modes. |
| `--lang=<gas\|gr>` | (none) | `new`, `init`, `fmt` | Which language. Scaffolds it (`new` / `init`, §3.10); picks the front-end for `fmt --stdin` (§3.8). |

Every other flag belongs to exactly one subcommand and is documented
with it in §3.

Pass `--` to terminate flag parsing (so a file named `--bench.gx`
can be passed as a positional).

---

## 3. Subcommands

### 3.1 `gero asm <file.gas>` — assemble

Assembles a single `.gas` file into a `.gx` bytecode image.

**Default output:** `<basename>.gx` next to the source.

```bash
gero asm hello.gas              # → hello.gx
gero asm hello.gas -o build/    # → build/hello.gx
gero asm hello.gas --optimize=release
```

**Behavior:**
- Reads source, runs assembler (uses `knit` for parsing), produces
  `.gx` with header per ISA spec §7.1.
- Prints `(N bytes, M banks, debug: yes/no)` summary unless `--quiet`.
- Errors print as `<file>:<line>:<col>: <message>` (knit's
  `formatParseErrorPretty` style with caret underline).

**Exit:** 0 on success; 3 on parse / assembly error.

### 3.2 `gero compile <file.gr>` — compile Gero

Compiles a single Gero module (and its imports) into a `.gx`.

**Default output** — precedence:
1. `--out <path>` — explicit wins.
2. `gero.toml` in an ancestor of the cwd — writes to
   `<project_root>/<[build].out>/<optimize>/<basename>.gx`
   (mirrors `gero build`'s Cargo-style layout). A malformed
   manifest exits 3 rather than silently falling back.
3. Sibling default — `<basename>.gx` next to the source.

```bash
gero compile main.gr                       # manifest or sibling
gero compile main.gr -o game.gx --optimize=release
```

**Behavior:**
- Resolves `use` imports relative to source dir + stdlib.
- Type-checks, monomorphizes (if generics ever land), codegens
  bytecode directly (no asm intermediate — speed).
- Same error format as `gero asm`.

**Exit:** 0 on success; 3 on parse error or malformed manifest;
4 on type error.

### 3.3 `gero run <file.gx>` — execute

Loads a `.gx` into a fresh VM and executes from `entry_point`.

```bash
gero run hello.gx
```

**Behavior:**
- Runs the bare VM — `print` syscalls go to stdout, `int 0x21`
  (save-flush) writes `<basename>.sav` next to the `.gx`, and a
  `<basename>.sav` present at startup is loaded into the program's
  battery-backed banks before the first instruction (ISA §3.2.1).
- Fantasy-console hosts (e.g. gtx-16) embed gero as a library
  and provide their own runtime — they're not invoked through
  `gero run`.

**Flags:**
- `--cycles` — report the cycle count once the program halts. The
  VM advances one cycle per instruction executed, so the number is
  instructions retired rather than a model of per-instruction cost;
  an `int` handled by the host is the host's work and is not
  counted. Execution is deterministic, so the figure is a property
  of the program and two runs are directly comparable.

**Exit:** 0 on `hlt` clean exit; 6 on unhandled fault (invalid
opcode, /0, etc.); 1 on host-level error (file missing, version
mismatch).

### 3.4 `gero test [pattern]` — run tests

> One walk, two kinds of test. The runner reads `[test].include`
> from `gero.toml` and covers both languages found under it:
>
> - **`.gas` golden tests** — a program paired with a sibling
>   `<name>.expected`. Assembled, booted on a fresh VM, stdout
>   captured via the host `int $10` print syscall and diffed against
>   the golden.
> - **`.gr` `@test` defs** (§3.7.5) — each module is parsed and
>   type-checked once, then lowered once per `@test` def with that def
>   as the entry point and run on a fresh VM. A clean `hlt` passes; the
>   `trap` fault a failed `test.assert_*` / `panic` raises fails, as
>   does any other fault or a cycle-budget overrun.
>
> `[pattern]` filters both by name — a `.gas` program's basename or a
> `@test` def's own name.

```bash
gero test                         # all .gas tests under [test].include
gero test loop                    # only tests with "loop" in the name
gero test --verbose               # show per-test duration
```

`gero test` is project-aware: it requires a `gero.toml` in the
cwd or an ancestor (run `gero new` to scaffold one). No fall-back
to a hardcoded root.

**Output format:**

```
running 4 tests
test arith ... ok
test cmp_branch ... ok
test hello ... ok
test loop ... FAIL

FAIL loop: stdout differs from .expected
  expected:
    *****
  got:
    ****
  at tests/asm/programs/loop.gas

3 passed, 1 failed (4.2 ms)
```

**Behavior:**
- Pattern is a substring match against the `.gas` basename
  (without extension).
- Each test gets a fresh VM instance (no cross-test state).
- The `int $21` SRAM-save syscall is no-op'd — only stdout is
  part of the golden compare.
- Each test is capped at a fixed cycle budget; a `.gas` that
  doesn't reach `hlt` fails with a timeout outcome.
- Unhandled faults and `brk` breakpoints count as failures.

**Future lang-level shape:** compile the project in
**test profile** — `@test` functions are included, `@bench` and
`@asm` are stripped / skipped. Pattern matches function names;
`assert(...)` failures emit structured diagnostics with the
expected / got values and source location.

**Exit:** 0 if all tests pass; 7 on at least one failure.

### 3.5 `gero bench [pattern]` — run benchmarks

Compiles the project in **bench profile** — `@bench` functions are
included. Each bench runs N times (default 1000), reports avg /
min / max cycle counts.

```bash
gero bench                        # all benches
gero bench damage                 # filter
gero bench --iter=10000           # custom iteration count
```

**Output format:**

```
running 2 benchmarks, 1000 iterations each
bench damage_calc ... ok  (avg 142 cyc, min 138 cyc, max 156 cyc)
bench format_string ... ok  (avg 87 cyc, min 82 cyc, max 94 cyc)
```

**Behavior:**
- Discovers `@bench` defs in the `.gr` modules under
  `[test].include`, the same walk `gero test` uses. `[pattern]`
  filters by def name.
- Iteration count via `--iter=N` (default 1000).
- Each iteration boots a fresh VM, so a bench measures its own body
  rather than state left by the run before.
- Cycle counts come from the VM's own counter. The VM is
  deterministic — same image, same start state, same count — so a
  spread between `min` and `max` means the body itself varies, not
  measurement noise.
- A bench that faults or exceeds the cycle budget is reported and the
  run continues; a faulting bench has no meaningful cost to report.

**Exit:** 0 when every bench completed; 6 when any faulted or ran
away (§5 — a runtime fault). No benches matched is not an error.

### 3.6 `gero disasm <file.gx>` — disassemble

Bytecode → asm text. The inverse of `gero asm`. Uses the `.gx`'s
debug symbol section if present to annotate addresses with names.

```bash
gero disasm game.gx                   # whole cart (base + every bank)
gero disasm game.gx -o game.gas       # to file
gero disasm game.gx --bank=3          # only bank 3
gero disasm game.gx --check-roundtrip # CI gate — asm → disasm → asm equality
```

When `--bank` is omitted, the whole cart is rendered: the base image
first, then every bank slot in turn, each prefixed with a
`; --- base image ---` / `; --- bank N ---` section header. Carts
with no banks render unchanged (no headers, single transcript).

`--check-roundtrip` skips all rendering and instead drives the archive
through `asm → disasm → asm`, exiting non-zero if the re-assembled
base image differs from the original. Bank bytes are excluded from the
compare (the round-trip helper disassembles the base image only).
`--quiet` suppresses the one-line ok summary. Wired into
`zig build test-examples` so every shipped example is gated.

**Output:** asm-syntax-clean source the user could re-assemble (round-
trip property — modulo formatting).

**Exit:** 0 on success; 1 on file / version error or round-trip
mismatch.

### 3.7 `gero info <file.gx>` — header info

Prints the `.gx` file header in human form.

```bash
gero info game.gx
```

```
file:        game.gx
size:        24536 bytes
magic:       GERO
version:     0x0200
entry:       0x1200
image:       12345 bytes
banks:       4 × 16 KB
sram:        2 banks (battery-backed)
debug:       yes (symbols: 142)
lines:       318 rows across 4 files
```

`lines` reports the debug section's line table (ISA §7.3), which
maps an address back to the source position that produced it. It
reads `none` for an image whose producer had no include / import
map to attribute files with, and the whole `debug` / `lines` pair
is absent from a release build.

**Exit:** 0; 1 on bad magic / version mismatch.

### 3.8 `gero fmt <files...>` — format source

Canonical formatter for `.gas` and `.gr`. Style is fixed
per-invocation — no `--option`s, no `.editorconfig` lookup. Inside
a gero project, the manifest's `[fmt]` section overrides the
compile-time defaults (see below).

```bash
gero fmt main.gas                 # format in place
gero fmt main.gr                  # Gero source — same UX
gero fmt --check main.gas         # check only (exit 8 if changes needed)
gero fmt src/                     # recurse into directory (.gas + .gr)
gero fmt a.gas b.gr src/          # any mix of files and directories
gero fmt                          # project-aware: [build].entry + [test].include
cat main.gas | gero fmt --stdin             # editor format-on-save (stdin → stdout)
cat main.gr | gero fmt --stdin --lang=gr    # Gero from stdin
```

**Behavior:**
- In-place edit by default. Files already in canonical form are
  left untouched.
- **Project-aware fallback**: invoked with no positional args
  inside a gero project (cwd or any ancestor has `gero.toml`),
  walks `[build].entry` + every entry in `[test].include`. No
  manifest + no positional args → exit 2 with a usage hint.
- `--check` is non-destructive: exits 0 if every file is canonical,
  8 if any file would be reformatted, 3 on a genuine parse error.
  CI use case.
- `--stdin` reads source from stdin, writes formatted bytes to
  stdout. Mutually exclusive with positional paths (exit 2).
  Manifest `[fmt]` overrides are **not** consulted in stdin mode
  — there's no project root context, so compile-time defaults
  apply. `--stdin --check` exits 0 if already canonical, 8 if it
  would reformat (no stdout in `--check` mode). Use case: editor
  format-on-save (VS Code / Neovim / Helix).
- `--lang=<gas|gr>` selects the front-end for `--stdin` — stdin
  carries no filename to dispatch on, so the language is explicit.
  Defaults to `gas`. Ignored outside stdin mode (path mode
  dispatches on the file extension). Editors pass `--lang=gr` when
  formatting a Gero buffer on save.
- Recurses into directories, formats every `.gas` and `.gr` found.
  `.gr` sources parse via the Gero front-end and re-emit
  through the AST printer; `.gas` round-trips through the asm
  printer.
- `include "..."` directives round-trip verbatim — fmt doesn't
  expand includes (that's `gero asm`'s job).
- **Every comment survives.** A `;` comment is preserved wherever
  it sits, including inside a `struct` body — trailing a field, on
  its own line between fields, on the opening-brace line, or
  between the last field and `}`. Trailing comments align to
  `comment_column` like any other host line; standalone ones keep
  their position in the body.
- **Formatting is idempotent.** Running `gero fmt` on canonical
  output reproduces it byte-for-byte, so `--check` can't oscillate
  in CI.

**Exit:** 0 (clean / formatted); 8 (`--check` would-modify); 3 on
parse error; 1 on host IO; 2 on usage.

#### Ignore directives

Drop these `;` comments to opt regions out of canonicalization
(same pattern as `// prettier-ignore` / `#[rustfmt::skip]`):

```asm
; gero-fmt-ignore-file
; (rest of file passed through verbatim)

; gero-fmt-ignore-next
const PRINT   = $10              ; only this line preserved

; gero-fmt-ignore-start
const PRINT   = $10
const NEWLINE = $0A
; gero-fmt-ignore-end             ; everything between markers preserved

const FOO = $20  ; gero-fmt-ignore   ; this single line preserved (trailing)
```

The directive comments themselves stay in the output.

#### `[fmt]` section in `gero.toml`

Override the printer's canonical defaults per-project. Same
pattern as Rust's `rustfmt.toml` / Black's `pyproject.toml
[tool.black]` — one canonical shape per project, no in-file
overrides.

The two languages have one printer each, and the printers do not
have the same knobs. `[fmt]` sets a key for **every** printer that
has it; `[fmt.gas]` and `[fmt.gr]` override their own. So a project
states its shape once and refines only where the languages differ:

```toml
[fmt]
indent = 4                   # both printers

[fmt.gas]
comment_column = 30          # default 30 — 0 disables alignment
align_kv = true              # default true — align `=` in const/data blocks
hex_case = "upper"           # default "upper" — upper | lower | preserve

[fmt.gr]
max_width = 100              # default 100 — column lines are kept within
use_tabs = false             # default false — a tab per level instead of spaces
hex_case = "preserve"        # default "preserve" — upper | lower | preserve
trailing_comma = true        # default true — comma after a broken form's last element
bracket_spacing = true       # default true — `P { x: 1 }` vs `P {x: 1}`
wrap = "collapse"            # default "collapse" — collapse | preserve
sort_use = false             # default false — order the opening `use` run
newline = "lf"               # default "lf" — lf | crlf | native
```

| Key | `.gas` | `.gr` | Default |
|-----|:--:|:--:|---------|
| `indent` | ● | ● | `2` |
| `hex_case` | ● | ● | `"upper"` / `"preserve"` |
| `comment_column` | ● | — | `30` |
| `align_kv` | ● | — | `true` |
| `max_width` | — | ● | `100` |
| `use_tabs` | — | ● | `false` |
| `trailing_comma` | — | ● | `true` |
| `bracket_spacing` | — | ● | `true` |
| `wrap` | — | ● | `"collapse"` |
| `sort_use` | — | ● | `false` |
| `newline` | — | ● | `"lf"` |

`comment_column` and `align_kv` are assembler-only because Gero has
no `const` block to align and does not column-align trailing
comments — rustfmt and prettier do not either. `hex_case` defaults
differently per language: the assembler canonicalises to `upper`,
while Gero re-emits the spelling the author wrote, because a
literal's case there often carries meaning the printer cannot see
(`$FF` a mask, `$deadbeef` a sentinel).

`trailing_comma` governs only the **last** element of a broken form —
the commas separating the others are grammar, not style, and are
always emitted. `bracket_spacing` is prettier's option of the same
name. `wrap = "preserve"` keeps a construct the author spread across
lines even when it would fit on one, the way prettier's `objectWrap`
and Black's magic trailing comma do; `"collapse"` puts it back.
`sort_use` orders the run of `use` declarations a file opens with, by
module — a `use` further down is left alone, since moving it would
reorder code around it. `newline` follows rustfmt's `newline_style`.

**Line width** applies to `.gr` only, and only where the printer has
a choice. A call's arguments, a `def`'s parameters, a struct
literal's fields and a tuple's elements ride on one line when they
fit within `max_width`, and break one element per line when they do
not. A wide enough `max_width` collapses a broken
construct back. The assembler is line-oriented (one instruction per
line) and has nothing to wrap.

Inside a project, `gero fmt` (and `gero fmt --check`) reads the
sections and applies the overrides. Outside a project (or with no
`[fmt]` section), compile-time defaults are used — preserves the
single-file CLI behavior. `--stdin` always uses the defaults: it has
no path, so it has no project.

Invalid `hex_case` values produce a clean diagnostic naming the
section they came from, with line/col; the parser rejects any other
shape (integer keys for `indent` / `comment_column` / `max_width`,
boolean for `align_kv` / `use_tabs`, string for `hex_case`).

### 3.9 `gero check <file>` — validate without producing output

Run a source file through the full assembler pipeline (resolve
includes → parse → codegen-validate) and report diagnostics
without writing a `.gx` artifact. Editor-LSP-style use case + CI
gate that catches asm spec drift faster than the full assemble-and-
run round-trip.

```bash
gero check main.gas               # one .gas file
gero check src/                   # walk recursively for *.gas
gero check a.gas b.gas src/       # any mix of files + dirs
gero check                        # project-aware: [build].entry + [test].include
gero check main.gr                # type-check a Gero source
gero check main.gas --quiet       # suppress per-file lines + summary
gero check main.gas --verbose     # per-phase timings (single-file only)
gero check --format=json src/     # editor-friendly JSON diagnostics
gero check --werror src/          # warnings escalate to exit 4 (CI gate)
```

**Project-aware fallback**: invoked with no positional args
inside a gero project (cwd or any ancestor has `gero.toml`),
walks `[build].entry` + every entry in `[test].include`. No
manifest + no positional args → exit 2 with a usage hint.

**Output (default):**

- **Single-file pass:** `✓ <path>  (N bytes, M banks)` summary
  followed by a Cargo-style `Finished in X ms` footer.
  `--verbose` inserts per-phase timings between them.
- **Multi-file:** one `✓ <path>` line per successful file, then a
  single `N errors in M files` block grouping every diagnostic
  under per-file caret sections, then a `check: N files passed, M
  failures` summary line, then the footer. Failures from multiple
  files share one summary header — no per-file "1 error in 1 file"
  noise.
- `--quiet` suppresses per-file ok lines + the summary but keeps
  failure diagnostics + the footer.

**`--format=json` mode:**

Emits a single JSON object to stdout (no per-file ✓ lines, no
summary, no footer). Stderr stays reserved for host I/O failures
(file missing, stat error). Schema:

```json
{
  "version": 1,
  "diagnostics": [
    {
      "file": "src/main.gas",
      "line": 12,
      "column": 5,
      "severity": "error",
      "code": "E004",
      "message": "undefined symbol",
      "note": "did you mean `foo_bar`?"
    },
    {
      "file": "src/main.gr",
      "line": 4,
      "column": 9,
      "end_line": 4,
      "end_col": 24,
      "severity": "warning",
      "code": "W_DEAD_TEST",
      "message": "unreachable test"
    }
  ],
  "files_checked": 4,
  "files_failed": 1
}
```

- Both front-ends report into the same `diagnostics` array, so a
  consumer parses stdout once whichever produced the report.
- `severity` is `error`, `warning`, or `note`.
- `code` is omitted for plain syntax errors that don't map to an
  E-code.
- `note` is omitted when absent.
- `end_line` / `end_col` mark where the offending span ends, so an
  editor can underline it. Present on `.gr` diagnostics, which carry
  a range; absent on `.gas` ones, which carry a point.
- Exit codes are unchanged from `human` mode (0 / 4 / 1 / 2) —
  editors can branch on the code, then `JSON.parse(stdout)` for
  the diagnostic list.
- The `version` field lets the schema evolve while keeping the
  contract stable.

**Exit:** `0` if clean; `4` on any fatal diagnostic; `1` on host
IO problem; `2` on usage error. Warning-severity diagnostics
print but exit `0` by default — `--werror` escalates any warning
to a fatal exit code for CI gates that want zero-warning builds.
(Asm-side diagnostics have no warning severity today; `--werror`
is a no-op for `.gas` inputs.)

### 3.10 `gero new <name>` — scaffold a fresh project

Lay out a minimal project in a new `./<name>/` sub-directory, in
either language. Templates are embedded in the binary — no network
call, no external assets. For an in-place scaffold (cwd as the
project root) see [§3.11 `gero init`](#311-gero-init--initialize-the-current-directory).

```bash
gero new my-cart --lang=gr        # → ./my-cart/ Gero scaffold
gero new my-cart --lang=gas       # → ./my-cart/ asm scaffold
gero new my-cart                  # asks, when run from a terminal
gero new my-cart --lang=gr --quiet  # skip the next-steps banner
```

**Choosing the language.** `--lang` settles it. Without the flag,
an interactive run asks:

```
  Which language is this project written in?

    1  gero-lang  (.gr) — the high-level language
    2  asm        (.gas) — the assembler

  >
```

With no terminal to ask — a pipe, a CI step, a script — the command
exits 2 and names the flag instead of picking for you. Every project
is one language or the other for its whole life, and a default would
be the one answer nobody chose.

**Scaffold (`--lang=gr`):**

```
my-cart/
├── gero.toml              # name, version 0.1.0, vm target, entry src/main.gr
├── src/
│   └── main.gr            # hello-world entry
├── tests/
│   └── smoke.gr           # a `@test` def, collected by `gero test`
└── README.md              # build / test / run pointers + tooling.md link
```

**Scaffold (`--lang=gas`):**

```
my-cart/
├── gero.toml              # name, version 0.1.0, vm target, entry src/main.gas
├── src/
│   └── main.gas           # hello-world entry, halts cleanly
├── tests/
│   ├── smoke.gas          # template golden-file test
│   └── smoke.expected
└── README.md              # build / test / run pointers + tooling.md link
```

A Gero scaffold ships no `.expected`: `gero test` judges a `@test`
def by its own assertions, where a `.gas` golden is diffed against
captured stdout (§3.4). Both scaffolds pass `gero check`,
`gero fmt --check` and `gero test` the moment they are written.

**Behavior:**
- The scaffold ships **no** `.github/workflows/`, **no**
  `lefthook.yml`, **no** opinionated CI / hook config. The README
  points at the upstream tooling guide where copy-paste recipes
  live for GitHub Actions, GitLab, lefthook, and plain git hooks.
- `<name>` must be 1-64 chars, start with a letter or `_`, and
  contain only letters, digits, `_`, or `-`. Names with `/`, `.`,
  spaces, or shell metacharacters are rejected.
- `gero new .` is rejected with a redirect to `gero init`.
- Fails cleanly with exit 1 if `<name>` already exists.

**Exit:** 0 on success; 1 on host IO / pre-existing dir;
2 on usage / invalid name / no language chosen. The language is
settled before anything is created, so a refused run leaves no
directory behind.

### 3.11 `gero init` — initialize the current directory

Same scaffold as `gero new`, but laid down **in place**: the cwd
becomes the project root, and its basename becomes the project
name. Cargo / poetry / yarn / zig convention — `new` for a fresh
sub-directory, `init` for the current one.

```bash
gero init --lang=gr               # scaffold Gero into ./
gero init --lang=gas              # scaffold asm into ./
gero init                         # asks, when run from a terminal
gero init --lang=gr --quiet       # skip the next-steps banner
```

**Behavior:**
- Takes `--lang` and runs the same prompt as `gero new` (§3.10),
  and refuses the same way when there is no terminal to ask.
- Pre-flights every target path; refuses to overwrite if any file
  the chosen language would write already exists (exit 1 with the
  list). That set is `gero.toml`, `src/main.<ext>`,
  `tests/smoke.<ext>`, `README.md`, plus `tests/smoke.expected`
  for `--lang=gas`. The language is settled first, so `--lang=gr`
  is not blocked by a stray `main.gas`.
- Cwd basename must satisfy the same validation as `gero new`
  (1-64 chars, leading letter / `_`, body of letters / digits /
  `_` / `-`). Rename the directory or `cd` into a parent + run
  `gero new` if it doesn't.
- Takes no positional args — accepting one would defeat the
  in-place intent.

**Exit:** 0 on success; 1 on host IO / pre-existing files;
2 on usage / invalid basename / no language chosen.

### 3.12 `gero build` — build project

Walks the ancestor chain for `gero.toml`, reads `[package]` +
`[build]`, compiles `build.entry`, and writes the resulting `.gx`
to
`<project_root>/<build.out>/<build.optimize>/<stem>.gx`. The
per-profile subdir (Cargo's `target/{debug,release}/` pattern)
keeps debug and release artifacts side by side so rebuilding in
one mode doesn't clobber the other.

```bash
gero build                        # → out/debug/<name>.gx
gero build -v                     # per-phase timings
gero build --target=vm            # explicit target override
```

**Behavior:**
- The entry's extension picks the front-end. A `build.entry` ending
  in `.gr` runs the Gero pipeline, resolving the `use` graph
  from that file; anything else runs the asm pipeline, resolving
  `include` directives. Both share `gero compile` / `gero asm`'s
  diagnostics, so an error reads the same however it was reached.
- Resolves `gero.toml` by ancestor walk — `gero build` works from
  any subdirectory of the project.
- Manifest-relative `[build].entry` and `[build].out` are joined
  under the project root (`dirname(gero.toml)`). The full output
  directory is `<build.out>/<build.optimize>/` and is created if
  missing.
- Output filename stem is `[build].name` if set, else
  `[package].name` — the manifest is the single source of truth,
  matching Cargo's `[[bin]].name` convention.
- `[build].debug_symbols = false` strips the `(address, name)`
  debug table from the `.gx`. Default is `true`.
- `--target=<vm|gtx-16>` overrides the manifest's `[package].target`.
  Only `vm` is implemented; `gtx-16` is reserved (errors with
  "not yet implemented").
- Takes no positional args — entry comes from the manifest.
  Single-file use is what `gero asm` covers.

**Incremental builds (`.gr` only):** a build records what it
learned under `<build.out>/.cache/` — one entry per module, plus
the relocatable code each one lowered to. The cache sits beside
the per-profile output dirs rather than inside one, so switching
profiles doesn't discard the other's record.

A later build compares each module against that record:

- Every module unchanged, artifact still present → nothing to do.
  The build reports `<path> (unchanged)` and stops after reading
  the sources.
- A module's own text changed → it is re-checked and re-lowered.
- A module's *interface* changed — anything it exports, function
  and method bodies excluded — → everything that transitively
  imports it is redone too.
- A module's *body* changed but its interface did not → its
  dependents keep their cached code. Nothing they could have
  relied on moved.

Anything that makes the record untrustworthy — missing, corrupt,
written by a different compiler version, or built for a different
entry point or `--optimize` mode — is treated as no cache at all,
and the build runs in full. Deleting `<build.out>/.cache/` is
always safe.

**Exit:** 0 on success; 1 on host IO / missing manifest; 2 on
usage (unknown target, positional); 3 on manifest parse error or
asm pipeline error.

Note: the asm pipeline doesn't optimize, so the `[build].optimize`
key drives only the output subdirectory today. A `--optimize=<m>`
flag override (without editing the manifest) will become
meaningful once a compiler back-end with optimization passes
lands.

---

### 3.13 `gero repl` — interactive Gero prompt

Read-eval-print loop for Gero. Reads stdin lines into a
session source buffer, recompiles + runs each input on a fresh
VM. State persists across inputs.

```bash
gero repl                          # interactive prompt; .quit / EOF to leave
```

**Input classification**:

- `def` / `class` / `struct` / `enum` / `use` / `bake def` / `@ann`
  → module-scope declaration; persists across the session.
- `let` / `const` → re-run on every subsequent input so the
  binding stays visible.
- Anything else → runs once in the current iteration's
  `__repl_main` body. Bare expressions get auto-wrapped in
  `print` so the value lands on stdout; `name(args)` calls don't
  wrap (their own `print`s surface the result).

**Multi-line input**: while open-block keywords (`def`, `do`, `if`,
`while`, `for`, `repeat`, `class`, `struct`, `enum`, `match`)
exceed close keywords (`end`, `until`), the prompt switches to
`... ` and accumulates more lines.

**Meta-commands** — all begin with a `.`:

| Command | Effect |
|---------|--------|
| `.help` | Print the meta-command list. |
| `.quit` / `.exit` | Leave the session (EOF also works). |
| `.reset` | Drop every committed binding. |
| `.dump <name>` | Print the source of a previously-defined name. |

**Error handling**: parse / typecheck / codegen failures print
diagnostics and leave the session source untouched, so the user
keeps typing without restarting.

**Exit**: `0` on clean `.quit` / EOF.

### 3.14 `gero lsp` — language server

Speaks the Language Server Protocol over stdin/stdout. Editors
spawn it; there is nothing useful to run by hand.

```bash
gero lsp                           # what an editor's LSP client runs
```

Takes no positional arguments. Everything written to stdout is a
protocol message, so anything the server needs to say about itself
goes to stderr.

`--stdio` is accepted and ignored. Stdio is the only transport the
server speaks, but most clients pass the flag by convention — VS Code's
`vscode-languageclient` appends it whenever a transport is named — and
rejecting it would leave the server unable to start under them.

Diagnostics (identical to what `gero check` reports) and
formatting (identical to what `gero fmt` writes) are provided for
both `.gas` and `.gr`, as are go-to-definition, hover,
find-references and completion. Each answers from a table the
compiler built — the type-checker's bindings for `.gr`, the
assembler's symbol table for `.gas` — rather than from a second
resolution of the same names. Hovering a name in `.gas` reports the
address it assembled to.

Inlay hints and quick-fix code actions are `.gr` only.

Buffers the editor holds unsaved are read from memory, and changing
one re-checks every open document that imports it — so editing a
library reddens its importers without a save.

**Exit**: `0` on `shutdown` + `exit`, or when the client closes
stdin. `1` on `exit` without `shutdown`, or a malformed header.

Protocol scope and per-editor wiring: [`lsp.md`](lsp.md).

---

## 4. Not yet shipped

The following subcommands are not implemented. Invoking them
prints `not yet implemented` and exits non-zero.

| Command | Why not yet |
|---------|--------------|
| `gero hexdump <file.gx>` | Low priority — `gero info` + `xxd` cover the use case today. |
| `gero debug <file.gx>` | Interactive debugger — needs a real-mode UX design pass. |
| `gero doc` | Docgen from `///` comments — waits for a substantial stdlib. |

---

## 5. Exit code conventions

Single source of truth for callers / CI scripts:

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error (file missing, host I/O, etc.) |
| 2 | Usage error (bad args, unknown subcommand, a flag the subcommand does not take) |
| 3 | Parse / assembly error |
| 4 | Type-check / lint error |
| 5 | Link error (missing symbol, version mismatch) |
| 6 | Runtime fault (`hlt` from fault, /0, invalid opcode) |
| 7 | Test failure (≥ 1 test failed) |
| 8 | Format diff (`fmt --check` would modify) |

---

## 6. Environment variables

| Var | Effect |
|-----|--------|
| `GERO_HOME` | Override stdlib root (default: bundled with the `gero` binary) |
| `GERO_NO_COLOR` | Disable ANSI colors in error output |
| `GERO_LOG=<level>` | `error` / `warn` / `info` / `debug` — verbosity control beyond `--verbose` |

---

## 7. Locale / output

All CLI output is **English-only** . No localization.
Diagnostics include source-positions (`file:line:col`) machine-
parseable by editors / CI tools.

---

## 8. Project file (`gero.toml`)

Current shape — consumed by `gero build` / `gero check` /
`gero fmt` / `gero test`. Walked by ancestor search, so any
subcommand works from any subdirectory of the project. See
`gero new` / `gero init` (§3.10 / §3.11) for the scaffold.

```toml
[package]
name = "my-cart"
version = "0.1.0"
target = "vm"                       # vm (default) | gtx-16 (deferred)
description = "..."                 # optional
license = "MIT"                     # optional, SPDX-style
repository = "https://..."          # optional
authors = ["Jane Doe <jane@..>"]    # optional
keywords = ["vm", "demo"]           # optional

[build]
entry = "src/main.gas"              # required — .gas or .gr
out = "out/"                        # output directory; default "out/"
optimize = "debug"                  # debug (default) | release | size
name = "cart-cli"                   # optional, defaults to package.name
debug_symbols = true                # emit debug-symbol blob; default true

[test]
include = ["tests/"]                # paths walked for .gas + .expected
exclude = ["tests/wip"]             # paths subtracted; default empty
cycle_budget = 1_000_000            # per-test cycle cap; default 1M

[fmt]                               # see §3.8 for full reference
indent = 2                          # every printer that has the key

[fmt.gas]                           # assembler printer only
comment_column = 30
align_kv = true
hex_case = "upper"

[fmt.gr]                            # Gero printer only
max_width = 100
use_tabs = false
hex_case = "preserve"
```

**Defaults**: `[build].out` → `"out/"`; `[build].optimize` →
`"debug"`; `[build].debug_symbols` → `true`; `[package].target` →
`"vm"`; `[test].cycle_budget` → `1_000_000`. Every field outside
those + `[package].name` / `[package].version` / `[build].entry`
is optional.

**Front-end**: `[build].entry`'s extension picks it — `.gas` runs
the assembler, `.gr` the language pipeline. There is no separate
language field: two places to say the same thing is two places to
disagree.

**Output path**: `<build.out>/<build.optimize>/<stem>.gx` —
the per-profile subdir (Cargo's `target/{debug,release}/` pattern)
keeps debug and release artifacts side by side. `<stem>` is
`[build].name` if set, else `[package].name` (Cargo's
`[[bin]].name` convention — decouple the binary name from the
package name). Example: default scaffold ships
`out/debug/my-cart.gx`.

**Validation**: `[build].optimize` is checked against
`{debug, release, size}` at parse time so a typo doesn't silently
land artifacts in `out/relase/`. Invalid → exit 3 with line:col.

**Future**: a `[deps]` / `[workspace]` section will land when a
registry + multi-package layout exist.
