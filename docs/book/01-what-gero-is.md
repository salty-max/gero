# 1. What Gero is

## Run something first

Make a file called `hello.gr`:

```gero
def main()
  print "Hello, gero!"
end
```

Compile it and run it:

```bash
gero compile hello.gr -o hello.gx
gero run hello.gx
```

```
Hello, gero!
```

That is the whole loop. Source in, one file out, run the file.

## What just happened

`gero compile` did not produce a program your computer can run. Open
`hello.gx` and you will not find machine code for your laptop. It is
**bytecode** — instructions for a machine that does not physically
exist, and that `gero run` pretends to be.

That machine is small enough to describe in a paragraph. It has
sixteen registers, each holding a 16-bit number. It has 64 KB of
memory, addressed `0x0000` to `0xFFFF`, and that is all the memory
there will ever be. It executes about a hundred instructions, one at a
time, until it hits `hlt`.

That is it. There is no operating system underneath, no filesystem, no
processes, no dynamic linking. When your program starts, the machine
has been zeroed, your program has been copied into memory at address
zero, and execution begins.

## Why do it this way

Because the constraint is the point.

Modern programming rests on abstractions that are worth having and
that also hide the machine completely. You allocate without thinking
about where. You call a library without thinking about its size. The
computer is fast enough that you are usually right not to care.

Gero takes that away deliberately. 64 KB is not a lot. When your cart
grows past it you cannot ask for more — you switch a bank, which means
deciding what is worth having in memory at a given moment. When a loop
is slow you cannot wait for a faster machine; you count the
instructions and make it shorter.

This is how games were written for the machines this VM is modelled
on — the 6502, the Z80, the 68000. The claim is not that it was better.
It is that the constraint produces a different kind of thinking, and
that thinking is worth having.

## What a cart is

`hello.gx` is a **cart**: one file, self-contained, that any Gero of
the same format version will run identically.

Identically is a strong word and it is meant literally. The same
source compiles to the same bytes on Linux, macOS and Windows — CI
checks that on every change against a corpus of blessed images. The
format is frozen at 1.0, so a cart built today runs on later versions
of the VM, and one built for an incompatible machine is refused rather
than run wrongly. [`versioning.md`](../versioning.md) §6 is the exact
promise.

For a cart, that matters more than it might sound. You are shipping an
artifact, not a build recipe.

## The two languages

Gero has two, and they produce the same bytecode.

**gero-lang** is what this book teaches. It reads like Lua, it is
typed at the boundaries, and it compiles ahead of time:

```gero
def sum_to(n: i16) -> i16
  let total: i16 = 0
  for i in 1..=n
    total += i
  end
  return total
end
```

**Assembly** is the machine's own language, one mnemonic per
instruction:

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

Both of those sum `1..n`. The assembly version is about three times
faster and a fifth the size, and the gero-lang version is the one you
would rather read six months from now. Neither is the "real" one —
[`asm-vs-lang.md`](../asm-vs-lang.md) has the measured numbers and the
rule for choosing.

This book stays in gero-lang until chapter 11, where the two meet.

## The tools

One binary does everything:

```bash
gero compile prog.gr -o prog.gx   # gero-lang → bytecode
gero run prog.gx                  # execute it
gero fmt prog.gr                  # canonical formatting, no options
gero check prog.gr                # errors without producing a file
gero disasm prog.gx               # bytecode → readable assembly
gero test                         # run @test functions
```

`gero disasm` is worth trying now, even though nothing in it will mean
much yet:

```bash
gero disasm hello.gx
```

Nothing is hidden. Whatever the compiler did to your program, you can
read back.

## What you need

```bash
brew install salty-max/tap/gero
```

or build from source — [`tooling.md`](../tooling.md) covers editor
setup for syntax highlighting and inline errors, which is worth ten
minutes before chapter 2.

---

**Next:** [Values and types](02-values-and-types.md) — what a program
can hold, and why there are no floating-point numbers.
