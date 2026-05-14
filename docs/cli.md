# `gero` CLI — Spec v0.1

Single binary `gero` with subcommands — `git` / `cargo` / `go` style.
Built from `apps/gero-cli/` in this repo, installed as `zig-out/bin/gero`.

This doc is the user-facing contract for the toolchain. Every
command's flags, exit codes, and behavior should match what's spec'd
here.

> **Status: design draft.** Locks happen as the CLI implementation
> forces decisions. v0.1 covers what's needed to write, build, run,
> test, format, and inspect a gero program end-to-end.

---

## 1. Overview

```
gero <subcommand> [flags] [args]
```

Discover the command list with `gero --help`. Discover per-command
flags with `gero <cmd> --help`.

A single `gero` binary covers asm, compile, run, test, bench, fmt,
check, build, disasm, info. The bare-VM runtime is the only target
this repo produces — fantasy-console hosts (e.g. gtx-16) live
downstream and consume `.gx` files as library inputs.

---

## 2. Common flags

Accepted by every subcommand (where meaningful):

| Flag | Default | Effect |
|------|---------|--------|
| `--help` / `-h` | — | Print help for the command and exit 0. |
| `--quiet` / `-q` | off | Suppress non-error output. |
| `--verbose` / `-v` | off | Extra info: timings, allocation counts, intermediate sizes. |
| `--optimize=<mode>` | `debug` | `debug` / `release` / `size`. Mirrors Zig modes. |
| `--out=<path>` / `-o` | (per-cmd default) | Output path for commands that produce files. |

Pass `--` to terminate flag parsing (so a file named `--bench.gx`
can be passed as a positional).

---

## 3. v0.1 commands

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

### 3.2 `gero compile <file.gr>` — compile gero-lang

Compiles a single gero-lang module (and its imports) into a `.gx`.

**Default output:** `<basename>.gx`.

```bash
gero compile main.gr            # → main.gx
gero compile main.gr -o game.gx --optimize=release
```

**Behavior:**
- Resolves `use` imports relative to source dir + stdlib.
- Type-checks, monomorphizes (if generics ever land), codegens
  bytecode directly (no asm intermediate — speed).
- Same error format as `gero asm`.

**Exit:** 0 on success; 3 on parse error; 4 on type error.

### 3.3 `gero run <file.gx>` — execute

Loads a `.gx` into a fresh VM and executes from `entry_point`.

```bash
gero run hello.gx
```

**Behavior:**
- Runs the bare VM — `print` syscalls go to stdout, `int 0x21`
  (save-flush) writes `<basename>.sav` next to the `.gx`.
- Fantasy-console hosts (e.g. gtx-16) embed gero as a library
  and provide their own runtime — they're not invoked through
  `gero run`.

**Exit:** 0 on `hlt` clean exit; 6 on unhandled fault (invalid
opcode, /0, etc.); 1 on host-level error (file missing, version
mismatch).

### 3.4 `gero test [pattern]` — run tests

> **v0.2 shape (shipped):** asm-level golden-stdout harness. The
> runner reads `[test].include` from `gero.toml`, walks each
> declared path for `.gas` programs paired with a sibling
> `<name>.expected` file, assembles each, boots a fresh VM,
> captures stdout (via the host `int $10` print syscall), and diffs
> against the golden. The lang-level form described below (`@test`
> functions, structured assertion diagnostics) lands with the
> language compiler in v0.3.

```bash
gero test                         # all .gas tests under [test].include
gero test loop                    # only tests with "loop" in the name
gero test --verbose               # show per-test duration
```

`gero test` is project-aware: it requires a `gero.toml` in the
cwd or an ancestor (run `gero new` to scaffold one). No fall-back
to a hardcoded root.

**Output format (v0.1, asm-level):**

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

**Behavior (v0.1):**
- Pattern is a substring match against the `.gas` basename
  (without extension).
- Each test gets a fresh VM instance (no cross-test state).
- The `int $21` SRAM-save syscall is no-op'd — only stdout is
  part of the golden compare.
- Each test is capped at a fixed cycle budget; a `.gas` that
  doesn't reach `hlt` fails with a timeout outcome.
- Unhandled faults and `brk` breakpoints count as failures.

**v0.2 lang-level shape (planned):** compile the project in
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
running 4 benches
bench_damage_calc       1000 iter   avg 142 cyc   min 138   max 156
bench_format_string     1000 iter   avg 87 cyc    min 82    max 94
...
```

**Behavior:**
- Iteration count via `--iter=N` flag (default 1000).
- Cycle counts assume cycle-accurate VM (v0.1 VM is) — wall-clock
  fallback if not.
- Benches that fault crash the run (no error swallowing — a faulting
  bench is a bug).

**Exit:** 0 on success; 1 on bench fault; 2 on no benches matched.

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
version:     0x0001
entry:       0x1100
image:       12345 bytes
banks:       4 × 16 KB
sram:        2 banks (battery-backed)
debug:       yes (symbols: 142)
```

**Exit:** 0; 1 on bad magic / version mismatch.

### 3.8 `gero fmt <files...>` — format source

Canonical formatter for `.gas` (and eventually `.gr`). Style is
fixed — no config file, no flags (like `gofmt` / `zig fmt`).

```bash
gero fmt main.gas                 # format in place
gero fmt --check main.gas         # check only (exit 8 if changes needed)
gero fmt src/                     # recurse into directory
gero fmt a.gas b.gas src/         # any mix of files and directories
gero fmt                          # project-aware: [build].entry + [test].include
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
- Recurses into directories, formats every `.gas` found. `.gr`
  sources route to "not yet implemented" until v0.3 wires the
  gero-lang front-end.
- `include "..."` directives round-trip verbatim — fmt doesn't
  expand includes (that's `gero asm`'s job).

**Exit:** 0 (clean / formatted); 8 (`--check` would-modify); 3 on
parse error; 1 on host IO; 2 on usage.

**Roadmap:** `--stdin` (read stdin, write stdout — editor format-
on-save) lands alongside the LSP server (#122 / v0.3).

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
gero check main.gr                # → "not yet implemented" until v0.3
gero check main.gas --quiet       # suppress per-file lines + summary
gero check main.gas --verbose     # per-phase timings (single-file only)
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

**Exit:** `0` if clean; `4` on any diagnostic; `1` on host IO
problem; `2` on usage error.

**Roadmap:** `--format=json` for editor integration + `.gr` source
support land alongside the lang front-end in v0.3 (#7).

### 3.10 `gero new <name>` — scaffold a fresh project

Lay out a minimal v0.2 asm project in a new `./<name>/`
sub-directory. Templates are embedded in the binary — no network
call, no external assets. For an in-place scaffold (cwd as the
project root) see [§3.11 `gero init`](#311-gero-init--initialize-the-current-directory).

```bash
gero new my-cart                  # → ./my-cart/ scaffold
gero new my-cart --quiet          # skip the next-steps banner
```

**Scaffold:**

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
2 on usage / invalid name.

**Roadmap:** `--kind=lang` lands in v0.3 once the gero-lang
front-end ships; interactive picker when stdin is a TTY.

### 3.11 `gero init` — initialize the current directory

Same scaffold as `gero new`, but laid down **in place**: the cwd
becomes the project root, and its basename becomes the project
name. Cargo / poetry / yarn / zig convention — `new` for a fresh
sub-directory, `init` for the current one.

```bash
gero init                         # scaffold into ./, name = cwd basename
gero init --quiet                 # skip the next-steps banner
```

**Behavior:**
- Pre-flights every target path; refuses to overwrite if
  `gero.toml`, `src/main.gas`, `tests/smoke.gas`,
  `tests/smoke.expected`, or `README.md` already exist (exit 1
  with the list).
- Cwd basename must satisfy the same validation as `gero new`
  (1-64 chars, leading letter / `_`, body of letters / digits /
  `_` / `-`). Rename the directory or `cd` into a parent + run
  `gero new` if it doesn't.
- Takes no positional args — accepting one would defeat the
  in-place intent.

**Exit:** 0 on success; 1 on host IO / pre-existing files;
2 on usage / invalid basename.

### 3.12 `gero build` — build project

Walks the ancestor chain for `gero.toml`, reads `[package]` +
`[build]`, runs the asm pipeline against `build.entry`, and
writes the resulting `.gx` to `<project_root>/<build.out>/<package.name>.gx`.

Essentially `gero asm` wrapped with manifest resolution +
output-path discipline. Reuses every existing asm-pipeline piece.

```bash
gero build                        # → out/<package.name>.gx
gero build -v                     # per-phase timings
gero build --target=vm            # explicit target override
```

**Behavior:**
- Resolves `gero.toml` by ancestor walk — `gero build` works from
  any subdirectory of the project.
- Manifest-relative `[build].entry` and `[build].out` are joined
  under the project root (`dirname(gero.toml)`). `out/` is
  created if missing.
- Output filename is `<package.name>.gx`, not the entry's
  basename — the manifest is the single source of truth.
- `--target=<vm|gtx-16>` overrides the manifest's `[package].target`.
  Only `vm` ships in v0.2; `gtx-16` is reserved (errors with
  "not yet implemented").
- Takes no positional args — entry comes from the manifest.
  Single-file use is what `gero asm` covers.

**Exit:** 0 on success; 1 on host IO / missing manifest; 2 on
usage (unknown target, positional); 3 on manifest parse error or
asm pipeline error.

**Roadmap:** `gero build --optimize=release` becomes meaningful
once the lang back-end (v0.3) lands; today the asm pipeline has
no optimizer to drive, so the `[build].optimize` key is read but
its only consumer ships in v0.3+.

---

## 4. v0.2+ commands (deferred)

| Command | Why deferred |
|---------|--------------|
| `gero hexdump <file.gx>` | Nice-to-have but `gero info` + `xxd` cover it |
| `gero init <name>` | Needs project file (`gero.toml`) convention spec'd first |
| `gero debug <file.gx>` | Interactive debugger — big project, real-mode UX needed |
| `gero repl` | REPL on a 16-bit VM is awkward — wait for clear use case |
| `gero doc` | Docgen from `///` comments — wait for stdlib to be substantial |

---

## 5. Exit code conventions

Single source of truth for callers / CI scripts:

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error (file missing, host I/O, etc.) |
| 2 | Usage error (bad args, unknown subcommand) |
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

All CLI output is **English-only** in v0.1. No localization.
Diagnostics include source-positions (`file:line:col`) machine-
parseable by editors / CI tools.

---

## 8. Future: project file (`gero.toml`)

Once `gero init` / dependency management land, a project file
will be needed:

```toml
[project]
name = "my-game"
version = "0.1.0"

[deps]
loom = { git = "https://github.com/salty-max/loom" }
```

Spec'd in v0.2 alongside `gero init`. For v0.1, conventions in §3.10
suffice.
