# Changelog

All notable changes to gero are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project will adhere to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
from v1.0.0 onward.

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
