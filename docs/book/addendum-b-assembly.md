# Gero and assembly

The machine has two languages. They produce the same bytecode. Neither
is the real one.

**Gero** is what the rest of this book teaches — types, functions,
the program as rules. **Assembly** is the machine's own language, one
mnemonic per instruction. You write it when you need to know exactly
which bytes run.

## The same routine

Sum `1..100` and print the result. Both of these print `5050`.

```asm
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

Measured on the same VM, not estimated:

- **Cycles** to print `5050`: 509 in asm, 1520 in Gero. Three times
  is a real cost in a raster interrupt and irrelevant everywhere else.
- **The routine**: 20 bytes against 95. The same ratio, for the same
  reason — the compiled loop goes through frame slots because it
  cannot prove nothing else needs the registers.
- **The image**: 32 bytes against 4712. That last number is the
  misleading one. A Gero program that only prints `5050` is already
  about 4.6 KB of runtime, paid once. The sum routine added 95. On a
  cart, the up-front cost is paid once and the per-routine cost is
  what matters.

## Which one to reach for

A battle system, a save format, the rules of the game — Gero. The
program is about what it does.

A sprite blitter, a chiptune player, a scanline effect — asm. You
are counting cycles, and 3× is the difference between fitting in the
frame and not.

An interrupt handler — short ones in asm; longer ones in Gero with
`@interrupt`, which saves and restores the registers a handler must
not clobber.

One instruction the compiler will not emit — `asm "..."` inside a
Gero function. One instruction, no labels, no control flow. The
bridge exists for exactly that, and stops there on purpose.

The two mix in one program. They produce the same `.gx`, so nothing
is lost at the boundary.

The Gero Machine — the other book — is the place that teaches
assembly as a language, not as a comparison.
