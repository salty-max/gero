# Changelog

All notable changes to gero are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project will adhere to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
from v1.0.0 onward.

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
