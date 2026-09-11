# asm, Gero, and the bytecode between them

Three layers, and none of them replaces another. This document exists
because the obvious reading — a high-level language arrived, so the
assembler is legacy — is wrong, and acting on it costs you the thing
each layer is good at.

---

## 1. The three layers

```
   Gero (.gr)          asm (.gas)
          \                    /
           \                  /
            +--> bytecode <--+          the .gx image
                     |
                     v
                 the VM
```

**Bytecode is the artifact.** A `.gx` is what the VM runs, what a cart
distributes, and what `gero disasm` reads back. Both front-ends emit
it, and neither is privileged: an image assembled by hand and one
compiled from Gero are the same kind of file, with the same
header and the same guarantee behind it (`docs/versioning.md` §6).

**asm is the machine's own language.** One mnemonic, one instruction,
no hidden work. You write it when you need to know exactly which bytes
run: an interrupt handler, a blitter, a routine you are counting
cycles for, or a lesson about how a CPU actually works.

**Gero is the application language.** Types, classes, modules,
pattern matching, `Vec(T)`. You write it when the program is about
what it does rather than how the machine does it — game logic, state
machines, the ninety per cent of a cart that is not a hot loop.

The layers meet in one place: `asm "..."` (`lang.md` §4.11) drops a
single assembly instruction into a `.gr` function. It is a bridge, not
a scripting hatch — one instruction, no labels, no control flow.

---

## 2. The same routine, both ways

Sum `1..100` and print the result. Both programs below print `5050`.

**asm** — `sum.gas`:

```asm
const PRINT_INT = $02
const NEWLINE   = $04

main:
  mov $0064, r1              ; n = 100
  call sum_to
  sys PRINT_INT              ; write acu as signed decimal
  sys NEWLINE
  hlt

; sum_to(r1) -> acu : sum of 1..r1, counting down.
sum_to:
  mov $0000, acu
.loop:
  cmp r1, $0000
  jeq .done
  add r1, acu                ; acu += r1
  dec r1
  jmp .loop
.done:
  ret
```

**Gero** — `sum.gr`:

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

Measured, not estimated — `gero asm sum.gas` and
`gero compile sum.gr`, run to `hlt` on the same VM:

| | asm | Gero |
|---|---|---|
| Cycles to print `5050` | **509** | **1520** |
| The routine's own bytes | **20** | **95** |
| Whole image | 32 B | 4712 B |

Three numbers, three different lessons.

**Cycles: 3×.** That is the price of a compiler that does not know
what you know. The asm loop keeps the accumulator in `acu` and the
counter in `r1` because you put them there; the compiled loop moves
through frame slots because it cannot prove nothing else needs them.
Three times is a real cost in a raster interrupt and irrelevant
everywhere else.

**The routine: 20 bytes against 95.** The same ratio, for the same
reason.

**The image: 32 bytes against 4712.** This one is the misleading one,
and it is worth being precise. A `.gr` that does nothing but
`print 5050` already compiles to **4617 bytes** — that is the runtime,
mostly integer formatting, and every Gero program pays it once.
The sum routine added 95. So the honest reading is not "Gero is
147× larger"; it is "Gero costs about 4.6 KB up front and then
roughly 4× per routine". On a cart with banks (`docs/isa.md` §3.2),
the up-front cost is paid once and the per-routine cost is what
matters.

---

## 3. Which one to reach for

| You are writing | Reach for | Because |
|---|---|---|
| A J-RPG, its battle system, its save format | Gero | The program is about rules, not registers. Classes, enums with payloads, and exhaustive `match` are the shape of that problem. |
| A sprite blitter, a chiptune player, a scanline effect | asm | You are counting cycles, and 3× is the difference between fitting in the frame and not. |
| An interrupt handler | asm, or Gero's `@interrupt` | Short handlers in asm; longer ones in Gero, which saves and restores the registers a handler must not clobber. |
| Cross-bank code on a banked cart | either | Gero's `@bank` emits the trampoline for you; asm gives you the `mb` write and the responsibility. |
| One instruction the compiler will not emit | `asm "..."` inside Gero | The bridge exists for exactly this, and stops at one instruction on purpose. |
| Learning how an 8/16-bit machine felt | asm | That is the point of the exercise. The ISA is small enough to hold in your head (`docs/isa.md` §5). |

The two mix freely inside one program: Gero calls into asm
through `asm "..."`, and an asm program can `include` a file that a
Gero build also uses for its constants. They produce the same
bytecode, so nothing is lost at the boundary.

---

## 4. What does not change between them

Whichever front-end wrote it, a `.gx`:

- runs on any gero that speaks its format major, and is refused
  rather than mis-run by one that does not (`docs/versioning.md` §6);
- disassembles back to readable asm, with symbol names when the
  image carries a debug section (`docs/isa.md` §7.3);
- addresses the same memory map, with the same bank window and the
  same IO page (`docs/isa.md` §3.1);
- compiles to the same bytes on every host — the golden corpus checks
  that on Linux, macOS and Windows on every change.

That last one is why the layers can coexist without a story about
which is canonical. There is one machine underneath, and both
languages are ways of writing for it.

---

## See also

- [`isa.md`](isa.md) — the machine both languages target
- [`asm.md`](asm.md) — the assembly language
- [`lang.md`](lang.md) — the high-level language, and §9 for
  what it deliberately is not
- [`asm-cookbook.md`](asm-cookbook.md) — worked asm recipes
