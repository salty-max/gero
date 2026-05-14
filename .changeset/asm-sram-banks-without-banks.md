---
bump: patch
---

`gero asm` / `gero build` / `gero check` now report a clean
diagnostic ([E017] `sram_banks` count exceeds declared `bank`
count) when a `.gas` file declares `sram_banks N` without enough
matching `bank` directives, instead of panicking in `vm.parseGx`
on the just-emitted image. Codegen catches the loader invariant
(`sram_bank_count <= bank_count`) at layout time and points the
caret at the offending `sram_banks` directive.
