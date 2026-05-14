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
| `gero asm` | `.gas` source → `.gx` bytecode image |
| `gero run` | Execute a `.gx` |
| `gero disasm` | `.gx` → asm (round-trip-safe; CI-gated) |
| `gero info` | Pretty-print a `.gx` header |
| `gero test` | Walk `tests/asm/programs/`, diff stdout vs `.expected` golden files |

Run `gero <subcommand> --help` for per-command flags.

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
- [docs/gero-lang.md](./docs/gero-lang.md) — high-level language spec
  (v0.2.0, not yet implemented)

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

## Roadmap

- ✅ VM kernel — 16-bit register machine, banked memory, IRQs
- ✅ Assembler — built on [knit](https://github.com/salty-max/knit)
- ✅ Disassembler — round-trip-safe
- ✅ CLI — `asm` / `run` / `disasm` / `info` / `test`
- ⏳ Gero language compiler — Lua-flavored, gradually typed (v0.2.0)
- ⏳ Bytecode freeze + cross-target perf pass (v1.0.0)

The gtx-16 fantasy console and the `gero-lab` web playground are out
of scope for this repo — they consume gero as a library.

## Compatibility

- **Zig**: 0.16.0 minimum (pinned in `build.zig.zon`)
- **Zero runtime dependencies** — pure Zig, no C deps, no FFI
- **Cross-targets** compiled on every PR: `x86_64-linux`,
  `aarch64-macos`, `x86_64-windows`, `aarch64-windows`, `wasm32-wasi`

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for branching, commit
conventions, the self-review loop, and the required toolchain.

---

License: [MIT](./LICENSE).
