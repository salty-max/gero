# Gero

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![Zig 0.16+](https://img.shields.io/badge/Zig-0.16%2B-f7a41d.svg)](https://ziglang.org/download/)

A 16-bit virtual machine, assembler, disassembler, and Lua-style
language compiler — all in pure Zig. Foundation for the gtx-16 fantasy
console and other Gero-ecosystem consumers.

> **Day 1.** The repo just landed with full tooling but no library
> code yet. The VM kernel, assembler, disassembler, and language
> compiler will land as separate PRs. See [CLAUDE.md](./CLAUDE.md) for
> the conventions every change must follow.

## Roadmap

- **VM** — 16-bit register machine + bytecode interpreter
- **ISA spec** — bytecode contract, lives in `docs/isa.md`
- **Assembler** — text → bytecode, built on [knit](https://github.com/salty-max/knit)
- **Disassembler** — bytecode → text
- **Gero language** — Lua-style syntax, compiles to bytecode

Out of scope for this repo: the gtx-16 fantasy console and the
`gero-lab` web playground — they consume gero as a library.

## Compatibility

- **Zig minimum**: 0.16.0 (pinned in `build.zig.zon`)
- **Zero runtime dependencies** — pure Zig, no C deps, no FFI
- **Cross-targets** compiled on every PR: `x86_64-linux`,
  `aarch64-macos`, `x86_64-windows`, `aarch64-windows`, `wasm32-wasi`

## Development

Three external tools, all single-binary installs:

```bash
# macOS (Homebrew)
brew install zig lefthook convco
```

After cloning:

```bash
lefthook install                  # wires git hooks
zig build --help                  # list every dev command
zig build ci                      # what CI runs end-to-end
```

| Step | Purpose |
|------|---------|
| `zig build` | Build the library |
| `zig build test` | Run native tests (Debug) |
| `zig build test-modes` | Run tests in all four release modes |
| `zig build test-all` | Cross-target compile gate |
| `zig build lint` | Format + every static check |
| `zig build ci` | lint + test-modes + test-all |
| `zig build changeset` | Scaffold a new changeset |

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for branching, commit
conventions, the self-review loop, and the required toolchain.

---

License: [MIT](./LICENSE).
