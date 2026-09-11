# The Gero Book

This book teaches **Gero** — the high-level language for the Gero
virtual machine — by building one program from nothing to something
you could ship.

It assumes you can use a terminal. It does not assume you have written
assembly, targeted a console, or heard of a bytecode VM. Where a
chapter needs one of those ideas, it explains it.

## The other book

**The Gero Machine** teaches the VM itself and its assembly language:
registers, addressing, interrupts, banking, counting cycles.

It is not the sequel to this one. The two languages are peers — they
compile to the same bytecode. [Gero and assembly](addendum-b-assembly.md)
has the measured comparison. If what you want is to understand how an
8- or 16-bit machine actually works, start there instead. Nothing in
this book is a prerequisite.

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
5. [Collections](05-collections.md) — tuples, arrays, `Vec`, and what
   each costs.
6. [Enums and match](06-enums-and-match.md) — payloads, and a missing
   arm as a compile error.
7. [Classes](07-classes.md) — fields, methods, `self`.
8. [Modules](08-modules.md) — `use`, `gero.toml`, `gero build`.
9. [Numbers that are not integers](09-fixed.md) — `fixed`, and where
   integer division loses the answer.
10. [Testing and measuring](10-testing.md) — `@test`, `@bench`.
11. [Reaching the machine](11-reaching-the-machine.md) — `asm`,
    `@bank`, `@interrupt`.
12. [A cart, end to end](12-a-cart.md) — the fight, shipped.

Addenda: [Installing Gero](addendum-a-installing.md),
[Gero and assembly](addendum-b-assembly.md).

## How to read it

Type the code. Every block in this book is compiled by CI on every
change, so if something here does not work, the book is wrong and not
you — and the build would have caught it. In the lab, **Run** on a
block is the same loop.
