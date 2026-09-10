# The Gero Book

This book teaches **gero-lang** — the high-level language for the Gero
virtual machine — by building one program from nothing to something
you could ship.

It assumes you can use a terminal. It does not assume you have written
assembly, targeted a console, or heard of a bytecode VM. Where a
chapter needs one of those ideas, it explains it.

## The other book

[**The Gero Machine**](../machine/README.md) teaches the VM itself and
its assembly language: registers, addressing, interrupts, banking,
counting cycles.

**It is not the sequel to this one.** The two languages are peers —
they compile to the same bytecode, and
[`asm-vs-lang.md`](../asm-vs-lang.md) has the measured comparison. If
what you want is to understand how an 8- or 16-bit machine actually
works, start there instead. Nothing in this book is a prerequisite.

Read this one if you want to make something. Read that one if you want
to know what the machine is doing.

## Contents

1. [What Gero is](01-what-gero-is.md) — the machine in one page, and a
   program running before anything is explained.
2. [Values and types](02-values-and-types.md) — `let`, `const`, the
   integer types, and why there are no floats.
3. [Control flow](03-control-flow.md) — `if`, `while`, `for`, ranges.
4. [Functions](04-functions.md) — parameters, returns, and returning
   more than one thing.

*Chapters 5–12 are outlined in the tracking issue and land next: collections,
enums and `match`, classes, modules, fixed-point, testing, reaching
the machine, and the finished cart.*

## How to read it

Type the code. Every block in this book is compiled by CI on every
change, so if something here does not work, the book is wrong and not
you — and the build would have caught it.

When a chapter needs a rule stated precisely — the exact grammar, the
full list of operators, every diagnostic code — it links to
[`gero-lang.md`](../gero-lang.md) rather than repeating it. That spec
is the authority; this book is the path through it.
