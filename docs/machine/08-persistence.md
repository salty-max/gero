# 8. Persistence

Every program in this book has forgotten everything the moment it halted.
Registers, memory, the lot — gone, and the next run starts from the image
again. For most of what we have written that was the right behaviour, and for
anything a person uses twice it is not.

This chapter is about the small part of a machine that remembers, and the
interesting thing is how little machinery it takes: no filesystem, no
serialisation format, no new instructions. It reuses the banks from the last
chapter and adds one number to the header.

## A bank that survives

The header field `sram_bank_count` marks the **last N banks** of a program as
battery-backed. Nothing else changes. They are switched with `mb`, addressed
through the same window, read and written with the same instructions. The
difference is entirely in what happens around the edges of a run: the host
loads them from disk at boot, and writes them back when the program finishes
or asks.

The name is a piece of history worth keeping. A cartridge with saved games
held ordinary static RAM and a watch battery soldered beside it, so the chip
kept its contents while the console was off. When the battery died, years
later, the saves went with it. The mechanism here is that arrangement with the
battery replaced by a file.

Because the last banks are the persistent ones, a program with one bank and
`sram_banks $01` has made that single bank its save data:

```asm
const PRINT = $10
const FLUSH = $21

sram_banks $01

main:
  mov $00, mb
  mov &BE00, r1
  cmp r1, 'S'
  jeq .returning

  mov 'S', r1
  mov r1, &BE00
  int FLUSH
  mov 'n', r1
  int PRINT
  mov $0A, r1
  int PRINT
  hlt

.returning:
  mov 'o', r1
  int PRINT
  mov $0A, r1
  int PRINT
  hlt

bank $00
```

Assemble it and run it twice:

```bash
gero asm remember.gas
gero run remember.gx
gero run remember.gx
```

```text
n
o
```

The first run finds nothing at the start of the bank, writes a marker, asks
for a flush, and reports that it is new. The second run finds the marker and
reports that it has been here before. Delete `remember.sav` and it prints `n`
again.

That is the entire mechanism, and it is worth sitting with for a moment: the
program contains no code for saving or loading. It writes to memory and reads
from memory. The persistence is in *which* memory.

## Asking for a flush

`int $21` is the request to write the persistent banks out now. Like `int $10`
it is a host convention rather than a processor feature — the machine has no
idea what a disk is — and the host decides where the bytes go. The `gero`
command-line tool puts them in a `.sav` file beside the `.gx`.

The host also flushes when the program halts, which raises a fair question:
why ask at all?

Because halting is the case you can count on least. A program that is
interrupted, that faults, or that runs on hardware somebody switches off does
not reach its `hlt`. `int $21` is what makes the difference between "this will
be saved when we finish" and "this is saved now", and the moments worth
spending it on are the ones a person would be upset to repeat — the end of a
level, a purchase, a checkpoint. Not every frame: writing out 16 KB is the
most expensive thing in this book, and doing it constantly costs far more than
the crash it is insuring against.

## What a save actually is

Look at the file the program produced:

```bash
xxd -l 16 remember.sav
```

```text
00000000: 5300 0000 0000 0000 0000 0000 0000 0000  S...............
```

16,384 bytes, of which one is interesting. `$53` is `'S'`, sitting at offset 0
because the program wrote to `$BE00` and the window begins there.

There is no structure in that file beyond what the program puts in it. It is
the bank, byte for byte. A save format, on this machine, is whatever layout
your program agrees with itself — where the marker lives, what the fields are,
how long they are. Nothing validates it and nothing describes it.

Which puts a real obligation on the program: it is reading data that a
*previous version of itself* wrote. Change the layout between releases and the
old save is still there, still the right size, still loading, and now being
read as something it is not. This is why saves in practice begin with a
marker and a version number. The marker says these bytes came from this
program at all; the version says which layout they are in, so a program can
recognise an old save and either convert it or decline it. The one-byte check
in the example above is the smallest version of that idea.

A save whose length does not match the program's persistent banks is refused
by the toolchain rather than loaded as far as it goes, on the same reasoning:
a half-restored save is a corrupted one, and the program has no way to tell
that what it is reading is partly its own state and partly nothing.

## Where this sits in the machine

It is worth naming what has not appeared in this chapter. There is no file
API, no notion of a save slot, no directory, no format. The program cannot ask
how large the save is or whether one exists — it can only look at the bytes and
decide for itself, which is what the marker check is doing.

That is characteristic of the level you are working at, and of the era these
machines come from. The host provides the smallest possible service: these
banks are the ones that persist, here is a request to write them out now.
Everything a person would recognise as saving — slots, names, timestamps,
"are you sure?" — is built on top, by the program, out of bytes it lays out
itself.

The exact rules for which banks persist, when the host loads and stores them,
and how a dev host may differ from one emulating real hardware are in
[`isa.md` §3.2.1](../isa.md).

## What you now know

Persistence is the bank mechanism with one header field changed: the last N
banks are loaded at boot and written back at exit, and are otherwise ordinary
memory. `int $21` requests a flush at a moment of the program's choosing,
which matters because halting cleanly is the case you can rely on least. A
save file is the bank verbatim, with no structure but the program's own, which
makes a marker and a version number the program's responsibility rather than a
nicety.

That completes the machine's structure — the parts a program has to respect
rather than merely use. What remains is making it fast, reaching the world
outside it, and reading programs somebody else wrote.
