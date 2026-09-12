# Gero and assembly

The machine has two languages. They solve different parts of the same problem
and produce the same `.gx` bytecode.

**Gero** gives names to rules through types, functions, classes, and modules.
The compiler chooses instructions for those rules. **Assembly** lets the
programmer choose each instruction directly. That control matters when exact
bytes or cycles matter; it adds work everywhere else.

A measured example makes the trade concrete.

## The same calculation

Both programs below add the integers from 1 through 100 and print `5050`.

The assembly version includes the setup, loop, output calls, and halt:

```asm
const PRINT_INT = $02
const NEWLINE   = $04

main:
  mov $0064, r1
  call sum_to
  sys PRINT_INT
  sys NEWLINE
  hlt

sum_to:
  mov $0000, acu
.loop:
  cmp r1, $0000
  jeq .done
  add r1, acu
  dec r1
  jmp .loop
.done:
  ret
```

The Gero version states the same loop with a parameter, a local binding, and an
inclusive range:

```gero
def sum_to(n: i16) -> i16
  let total: i16 = 0
  for i in 1..=n
    total += i
  end
  return total
end

def main()
  print sum_to(100)
end
```

The two programs have the same observable result, but the machine performs
different amounts of work:

| Measurement | Assembly | Gero |
|---|---:|---:|
| Cycles through the printed result | 509 | 1520 |
| Bytes for the sum routine | 20 | 95 |
| Whole image | 32 | 4712 |

The assembly loop keeps its counter and total in registers because the author
chose those locations. The compiled loop uses a general function frame because
the compiler must preserve the rules of arbitrary Gero functions. That
explains much of the cycle and routine-size difference.

The whole-image comparison needs more care. Even a Gero program that only
prints `5050` includes roughly 4.6 KB of runtime code, mostly integer
formatting. A larger program pays that base cost once. The useful comparison
for one additional routine is therefore 20 bytes against 95, not 32 against
4712.

Measurements need context. A difference of a thousand cycles is irrelevant in
a menu that waits for a button and decisive in a routine that must finish
before the next scanline.

## Choose from the problem

Use Gero when the program is mainly about relationships and rules: a battle
system, save data, scenes, or an inventory. Names and checked boundaries save
more work than hand-selected instructions.

Use assembly when the implementation itself is the problem: a sprite blitter,
a chiptune mixer, a small interrupt handler, or a loop with a fixed cycle
budget.

Use `asm "..."` inside Gero when one instruction is missing from the high-level
language. The narrow bridge lets a larger program stay readable while exposing
the one machine operation it needs.

Performance work should begin with a measurement. Write the clear version,
benchmark the relevant operation, inspect its disassembly, and only replace it
when the cost matters in its real context.

Neither language is the real one. The cart is the artifact, and both languages
are ways of creating it.

For the complete comparison and interoperability rules, see
[`asm-vs-lang.md`](../asm-vs-lang.md). To learn the instruction-level side from
the beginning, continue with **The Gero Machine**.
