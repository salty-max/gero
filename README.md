# Gero

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![Zig 0.16+](https://img.shields.io/badge/Zig-0.16%2B-f7a41d.svg)](https://ziglang.org/download/)

A 16-bit virtual machine, assembler, disassembler, and Lua-style
language compiler — all in pure Zig. Foundation for the gtx-16 fantasy
console and other Gero-ecosystem consumers.

New here? [**Why gero-lang?**](#why-gero-lang) explains what the
language is for, and
[`docs/asm-vs-lang.md`](./docs/asm-vs-lang.md) explains why the
assembler did not go away when it arrived.

## Quickstart

Install via Homebrew (macOS Apple Silicon + Linux):

```bash
brew install salty-max/tap/gero
```

**The bytecode format is frozen at 1.0.** A `.gx` you build today runs
on every later gero that speaks format 1 — see
[Bytecode](#bytecode) below.

Or build from source:

```bash
git clone https://github.com/salty-max/gero
cd gero
zig build                          # produces ./zig-out/bin/gero
```

Assemble and run the smallest meaningful program:

```bash
gero asm examples/asm/hello.gas    # → examples/asm/hello.gx
gero run examples/asm/hello.gx     # → Hello, gero!
```

That's the entire asm path. If you built from source, run the commands
from the repo root and prefix them with `./zig-out/bin/` — or run
`zig build install --prefix ~/.local` to drop the binary into
`~/.local/bin`.

For editor setup (VS Code / Neovim / Helix), CI recipes
(GitHub Actions / GitLab), and pre-commit hooks (lefthook /
pre-commit framework / plain git), see
[`docs/tooling.md`](./docs/tooling.md).

## Why gero-lang?

gero-lang is the high-level language for the gero VM. It reads like
Lua, compiles ahead of time to the same `.gx` bytecode the assembler
produces, and is typed where it matters. It exists because the
alternatives each give up something a cart needs.

**Against Lua on a fantasy console.** PICO-8 and TIC-80 hand you a
scripting language and interpret it at runtime. gero-lang keeps the
feel — `let`, `do … end`, no semicolons — and compiles instead, so
what ships is bytecode rather than source. Types are checked before
the cart runs: a `match` that misses an enum variant is a compile
error, not a nil at the wrong moment. Nothing about your program is
discovered on the player's machine.

**Against C for retro targets.** CC65 and its kin give you a systems
language on an 8-bit machine, and a type system from 1989. gero-lang
gives you `Vec(T)`, tuples, enums with payloads, exhaustive pattern
matching, and `T?` optionals instead of a null you have to remember to
check — while still emitting bytecode you can read back instruction by
instruction with `gero disasm`.

**Against Zig or Rust plus an engine.** Those are better languages
than this one, and that is not the axis. A gero cart is a `.gx`: one
file, byte-identical on every machine that builds it, running on a VM
whose format is frozen (`docs/versioning.md` §6). The whole toolchain
— assembler, compiler, disassembler, formatter, test runner, bench
runner, language server — is one binary with no dependencies. And when
the language needs something the machine cannot do, the machine is
right here: the ISA and the language were designed together, and
`asm "..."` reaches the instruction directly.

**What it is not.** Not self-hosting, not general-purpose, not a web
runtime. No async, no traits, no user-defined generics, no floats.
Those absences are choices, and
[`docs/gero-lang.md`](./docs/gero-lang.md) §9 gives the reasoning for
each.

| | Lua on a console | C (CC65 &co) | gero-lang |
|---|---|---|---|
| Runs as | interpreted source | native 8-bit code | bytecode on a specified VM |
| Errors found | at play time | at compile time, narrowly | at compile time, incl. exhaustiveness |
| Distributes as | source | a binary per target | one `.gx`, byte-identical everywhere |
| Drops to asm | rarely, if at all | inline asm | `asm "..."`, one instruction |
| Toolchain | the console | assembler + linker + tools | one binary |

The full language reference is
[`docs/gero-lang.md`](./docs/gero-lang.md). For when to write asm
instead — and the measured cost of each —
see [`docs/asm-vs-lang.md`](./docs/asm-vs-lang.md).

## What's here

| Command | Purpose |
|---------|---------|
| `gero new <name>` / `gero init` | Scaffold a fresh project / initialize the cwd (cargo-style) |
| `gero build` | Project-aware compile — reads `gero.toml`, writes `out/<optimize>/<name>.gx` |
| `gero asm <file.gas>` | One-shot assemble — `.gas` source → `.gx` bytecode image |
| `gero compile <file.gr>` | Compile a gero-lang module (and its `use` imports) → `.gx` |
| `gero run <file.gx>` | Execute a `.gx` until `hlt` |
| `gero check [paths…]` | Parse + codegen-validate without writing a `.gx` (LSP-style smoke) |
| `gero fmt [paths…]` | Canonical formatter for `.gas` + `.gr` (`--check` for CI) |
| `gero test [pattern]` | Walk `[test].include`, diff stdout vs `.expected` golden files |
| `gero disasm <file.gx>` | `.gx` → asm (round-trip-safe; CI-gated) |
| `gero info <file.gx>` | Pretty-print a `.gx` header |
| `gero repl` | Interactive gero-lang prompt — declarations persist across inputs |
| `gero lsp` | Language server for `.gas` + `.gr` — diagnostics and format-on-save over stdio |

Run `gero <subcommand> --help` for per-command flags, or
[`docs/cli.md`](./docs/cli.md) for the full reference.

## Learn more

- [examples/asm/](./examples/asm/) — five worked programs covering
  loops, recursion, banks, and SRAM
- [docs/asm.md](./docs/asm.md) — assembler syntax + directives
- [docs/isa.md](./docs/isa.md) — ISA reference (opcodes, memory map,
  `.gx` format)
- [docs/cli.md](./docs/cli.md) — full CLI reference
- [docs/asm-cookbook.md](./docs/asm-cookbook.md) — recipes for
  loops, banking, SRAM, IRQs, fixed-point, and more
- [docs/tooling.md](./docs/tooling.md) — editor setup, CI recipes,
  pre-commit hooks
- [docs/lsp.md](./docs/lsp.md) — language-server scope and
  per-editor wiring (Neovim, VS Code, Helix)
- [examples/lang/](./examples/lang/) — seven worked `.gr` programs
  covering recursion, loops, payload-carrying enums, and `match`
- [docs/gero-lang.md](./docs/gero-lang.md) — gero-lang spec (types,
  classes, pattern matching, annotations, the compilation model)
- [docs/gero-lab.md](./docs/gero-lab.md) — browser playground spec —
  the wasm engine boundary, worker protocol, and debugger cockpit

## Use as a library

```bash
zig fetch --save git+https://github.com/salty-max/gero
```

Then in your `build.zig`:

```zig
const gero = b.dependency("gero", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("gero", gero.module("gero"));
```

Compiling a `.gr` is four steps, each one owning its output:

```zig
const gero = @import("gero");

var stream = try gero.lang.tokenize(allocator, source);
defer stream.deinit();

var tree = try gero.lang.parse(allocator, source, stream);
defer tree.deinit();

var checked = try gero.lang.typecheck(allocator, source, &tree.program);
defer checked.deinit();
if (checked.diagnostics.len > 0) return report(checked.diagnostics);

var compiled = try gero.lang.compile(allocator, source, &checked, .{});
defer compiled.deinit();
// compiled.image is a `.gx` — hand it to gero.vm, or write it out.
```

Diagnostics are collected rather than returned at each step, so one
pass reports everything it found. For a multi-file program, start with
`gero.lang.resolveUseImports` and feed its fused source to `tokenize`.
Assembly is the same shape through `gero.asm_`, and `gero.vm` runs the
result. Every export carries its own example.

## Status

Shipped features land in [`CHANGELOG.md`](./CHANGELOG.md).
Open work is tracked on the
[project board](https://github.com/salty-max/gero/projects).
Editor tooling lives in [`editors/`](./editors/) as submodules: a
tree-sitter grammar per language, plus the VS Code extension.

The gtx-16 fantasy console is built in its own repo and consumes gero
as a library; its contract lives in [`docs/gtx-16.md`](./docs/gtx-16.md).
The `gero-lab` browser playground is specified in
[`docs/gero-lab.md`](./docs/gero-lab.md) and belongs to this repo — it
builds against the working tree so the playground can never lag the
toolchain it demonstrates.

## Compatibility

- **Zig**: 0.16.0 minimum (pinned in `build.zig.zon`)
- **Zero runtime dependencies** — pure Zig, no C deps, no FFI
- **Cross-targets** compiled on every PR: `x86_64-linux`,
  `aarch64-macos`, `x86_64-windows`, `aarch64-windows`, `wasm32-wasi`

### Bytecode

The `.gx` format is at **1.0**, and **frozen** from there. Within a
format major a file runs on any gero that speaks that major — an older
file on a newer build and a newer file on an older one, because every
minor bump is additive by rule.

A file from any other major is **refused**, never run and hoped for:

```
built for .gx format 0.4, but this build speaks 1.0 — the majors differ, so it would not run correctly
```

Both directions are refused, and the lower one is why major 1 exists.
A `0.x` archive is well-formed; its instructions simply address a
memory map that moved. Accepting it would mean running it wrongly, in
silence.

The format version is independent of this package's version — `gero`
is at `0.2.0` and the format is at `1.0`, and neither implies the
other. What counts as additive versus breaking, what the freeze
commits to, and what enforces it rather than intending it are in
[`docs/versioning.md`](./docs/versioning.md) §6.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for branching, commit
conventions, the self-review loop, and the required toolchain.

---

License: [MIT](./LICENSE).
