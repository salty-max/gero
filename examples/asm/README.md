# Example asm programs

Short, deterministic `.gas` programs exercising different slices of
the ISA. Each one ships with a `<name>.expected` golden output file —
re-runnable as a smoke test for the assembler + VM pipeline.

## Programs

| File | What it tests | Expected output |
|---|---|---|
| `hello.gas` | `mov8` indexed-load over a NUL-terminated `data8` string + `int $10` print + `hlt` | `Hello, gero!\n` |
| `counter.gas` | `inc` / `cmp` / `jne` (flag-driven loop), char literals as immediates, imm8 narrowing | `0123456789ABCDEF\n` |
| `fib.gas` | recursive Fibonacci — `call` / `ret` + stack discipline + `add reg, reg` + hex-digit conversion sub-routine | `37\n` (fib(10) = 55 = `$37`) |
| `banks/main.gas` | multi-bank cart with cross-bank calls — base image trampolines into bank 0 and bank 1 via `mb` register | `Hi!\n` |
| `save.gas` | SRAM write + `int $21` flush — produces a 16 KB `.sav` file with `"SAV\0"` at offset 0 | `OK\n` (plus `save.sav` written to disk) |

## Run one

```bash
zig build              # builds zig-out/bin/gero
./zig-out/bin/gero asm examples/asm/hello.gas -o examples/asm/
./zig-out/bin/gero run examples/asm/hello.gx
# → Hello, gero!
```

## Diff against the golden output

```bash
./zig-out/bin/gero run examples/asm/hello.gx | diff - examples/asm/hello.expected
```

A clean run produces no diff and exits 0. To drive every example
at once:

```bash
zig build test-examples
```

That step is wired into `zig build ci` and runs on every PR.

## Operand order

Every binary instruction reads as `<op> src, dst` — the first
operand is the source, the second is the destination modified
in-place. See `docs/asm.md §2.4` for the full convention. Quick
reference:

```asm
mov $10, r1     ; r1 ← $10
mov r2, r1      ; r1 ← r2
add $10, r1     ; r1 += $10
add r2, r1      ; r1 += r2
```

`cmp` / `tst` / shifts are intentionally different — see the spec.
