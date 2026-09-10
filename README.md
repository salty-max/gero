# Gero

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![Zig 0.16+](https://img.shields.io/badge/Zig-0.16%2B-f7a41d.svg)](https://ziglang.org/download/)

A 16-bit virtual machine, assembler, disassembler, and Lua-style
language compiler — all in pure Zig. Foundation for the gtx-16 fantasy
console and other Gero-ecosystem consumers.

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
