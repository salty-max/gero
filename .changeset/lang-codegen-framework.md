---
bump: minor
---

Closes #193. First slice of the gero-lang codegen — the framework
that downstream slices hang instruction selection / register
allocation / annotation lowering off.

**What it does today**

- New module `src/lang/codegen.zig`:
  - `pub const Compiled` — `{ image: []u8, diagnostics: []Diagnostic, allocator }` with `deinit` + `hasErrors`.
  - `pub const Options` — `entry_name: []const u8 = "main"`, `debug_symbols: bool = true`.
  - `pub fn compile(allocator, source, *CheckedProgram, opts) !Compiled` — walks the typed AST, locates the entry `def`, and emits a `.gx` archive ready for `gero.vm.parseGx`.
- Public boot-layout constants per ISA §7:
  - `pub const ivt_base: u16 = 0x1000;`
  - `pub const code_base: u16 = 0x1100;`
  - `pub const data_base: u16 = 0x2000;`
- Header emission per ISA §7.1 — magic `"GERO"`, version `0x0001`, entry-point + image-size carried, bank / SRAM / debug fields zeroed until later slices wire them.

**Entry-def emission**

For the smoke test (`def main() end`) the entry def's body is
empty — codegen synthesizes a single `hlt` (0xFF) at
`code_base`. The VM boots, fetches `hlt`, halts in one dispatch
step.

Real instruction selection for statements / expressions /
primitives / fixed-point is the next slice's scope (#194).

**Public surface**

Three new re-exports on `gero.lang`:

- `Compiled`
- `CompileOptions`
- `compile`

Plus the `codegen` module barrel for the boot-layout constants.

**Tests**

4 new tests in `tests/lang/codegen.test.zig`:

- `def main() end` → valid `.gx` with header carrying
  `entry_point = 0x1100`, byte at entry = `0xFF`.
- VM boots the image, single dispatch step returns
  `StepResult.halted`.
- Missing entry def → `error.EntryNotFound`.
- Custom `entry_name` resolves a non-`main` entry.

**Out of scope (later slices)**

- Real instruction selection — #194.
- Register / stack-slot allocator — #194 / dedicated slice.
- Calling convention + closures + vtable dispatch — #196.
- Annotation lowering (`@bank` / `@addr` / `@interrupt`) — #197.
- Debug-symbol section emission — codegen follow-up.
- `gero build foo.gr → foo.gx` CLI wiring — follow-up.
