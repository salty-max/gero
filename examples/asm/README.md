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

A clean run produces no diff and exits 0. (`zig build test-examples`
will land in #48 to bundle this into CI.)

## Deferred examples

Two programs from the original #47 plan are not here yet — the
assembler doesn't support bank or SRAM emission in v0.1
(`codegen.zig` hardcodes both header bytes to 0). They land when the
asm grows those features:

- `banks.gas` — multi-bank program with cross-bank `call`.
- `save.gas` — write to SRAM + `int $21` flush, demonstrating
  persistence to a `.sav` file.

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
