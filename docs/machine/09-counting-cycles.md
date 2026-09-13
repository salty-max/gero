# 9. Counting cycles

A machine like this one runs inside a fixed budget. A console drawing sixty
frames a second has a sixtieth of a second to produce each one, and the budget
does not care how elegant the program is. Either the work fits or the frame is
late.

That constraint is what people mean when they call this kind of programming
old school, and it is also what makes it satisfying: the question "is this fast
enough?" has an actual answer, and you can go and get it. This chapter is about
getting it, and then about spending it well.

## Measure before you change anything

Start with the discipline, because it is the part people skip. Intuition about
what a program costs is unreliable, and it is unreliable in a specific
direction: we notice the code that looks complicated and miss the code that
runs many times. A loop of three simple instructions costs more than an
elaborate routine called once.

So measure first. `gero run --cycles` reports what a program cost when it
halts:

```bash
gero run sum.gx --cycles
```

Before you trust that number, know what it counts. The VM advances one cycle
per instruction executed. There is no per-instruction cost model here — a
`divs` and a `mov` each count one — so the figure is *instructions retired*
rather than a prediction of time on silicon, where a divide costs many times
what a move does.

And an `int` serviced by the host is not counted, because it is not the
program's work. Printing a character is the terminal's business; a program
that prints inside a loop will show a lower number than its real cost. `sys`
calls are different: they are instructions the VM itself executes, and they
count.

That is a limitation, and it is worth stating plainly rather than working
around, because it tells you what the tool is for. It answers "does my program
execute fewer instructions than it did?" precisely and repeatably. It does not
answer "will this fit in a frame on real hardware?". Knowing which question
your measurement answers is most of the skill.

The count is deterministic — the same image always produces the same number —
so two measurements are directly comparable. That is what makes the rest of
this chapter possible.

## A loop, measured

Here is a program that sums the numbers from 10 down to 1 and prints the
result as a character:

```asm
const PRINT = $10

main:
  mov $0000, r2
  mov $000A, r1
.loop:
  add r1, r2
  dec r1
  cmp r1, $00
  jne .loop
  add '0', r2
  mov r2, r1
  int PRINT
  hlt
```

```text
g
```

The sum is 55, and 55 plus 48 is 103, which is `g` — the character arithmetic
from chapter 2, and a reminder that printing a number above nine takes more
work than this program does.

```bash
gero run sum.gx --cycles
```

```text
cycles: 45
```

Forty-five instructions for ten additions. That ratio is the interesting part:
most of what the program did was not the addition.

## Three instructions doing one job

Look at what the loop spends itself on. Each pass runs `add`, `dec`, `cmp`,
`jne` — one instruction of work and three of bookkeeping. The bookkeeping is
counting down and deciding whether to go round again.

That pattern is so common that the instruction set has an instruction for it.
`djnz` decrements a register and branches if the result is not zero, which is
`dec`, `cmp` and `jne` collapsed into one:

```asm
const PRINT = $10

main:
  mov $0000, r2
  mov $000A, r1
.loop:
  add r1, r2
  djnz r1, .loop
  add '0', r2
  mov r2, r1
  int PRINT
  hlt
```

```text
g
```

```text
cycles: 25
```

Forty-five down to twenty-five, for identical output. The arithmetic is worth
checking rather than accepting: two instructions removed from a loop body that
runs ten times is twenty instructions, and 45 − 20 = 25. The measurement
agrees with the reasoning, which is how you know you understand what happened
rather than having got lucky.

Notice also what made the win large. `djnz` saves two instructions, which is
nothing on its own. It saved twenty because it was inside a loop. The first
question to ask of any optimisation is not how clever it is but how many times
it happens.

## Work that did not need repeating

The second kind of win comes from noticing that a loop is doing something the
same way every time.

```asm
const PRINT = $10

main:
  mov $0000, r2
  mov $000A, r4
.loop:
  mov $0005, r1
  add r1, r2
  djnz r4, .loop
  mov r2, r1
  int PRINT
  hlt
```

```text
2
```

```text
cycles: 34
```

The loop adds five, ten times, giving fifty — which prints as `2`, fifty being
the character for that digit. But look at `mov $0005, r1`. It puts the same
value in the same register on every pass. Nothing in the loop changes `r1`, so
nine of those ten moves accomplish exactly nothing.

Lift it out:

```asm
const PRINT = $10

main:
  mov $0000, r2
  mov $000A, r4
  mov $0005, r1
.loop:
  add r1, r2
  djnz r4, .loop
  mov r2, r1
  int PRINT
  hlt
```

```text
2
```

```text
cycles: 25
```

Thirty-four to twenty-five. Again the arithmetic checks: ten moves removed,
one added outside, so nine instructions saved.

This is **hoisting**, and the reason to name it is that compilers do it for
you and assembly does not. Writing the load inside the loop is the natural way
to express "this loop adds five", and it is the assembler's job to take
instructions literally. Every repetition you did not intend is one you have to
notice yourself.

## When the measurement measures something else

The third example is the most useful, because it goes slightly wrong.

A classic optimisation replaces a division by a power of two with a shift.
Dividing by two and shifting right by one bit compute the same thing, and on
real hardware the shift is dramatically cheaper — division is among the most
expensive operations a processor does, often by an order of magnitude.

Here is a loop that divides, ten times over:

```asm
const PRINT = $10

main:
  mov $0008, r3
  mov $000A, r4
.loop:
  mov $0040, r1
  mov $0002, r2
  divs r2, r1
  dec r4
  cmp r4, $00
  jne .loop
  add '0', r1
  int PRINT
  hlt
```

```text
P
```

```text
cycles: 64
```

And the same thing with a shift:

```asm
const PRINT = $10

main:
  mov $0008, r3
  mov $000A, r4
.loop:
  mov $0040, r1
  shr r1, $01
  dec r4
  cmp r4, $00
  jne .loop
  add '0', r1
  int PRINT
  hlt
```

```text
P
```

```text
cycles: 54
```

Ten cycles saved — and not one of them came from avoiding the division.

Count it through. The divide needed its divisor in a register, so the first
version runs an extra `mov` on every pass: ten instructions across ten
iterations. The `divs` itself became a `shr`, one instruction for one
instruction, and under a counter that charges one per instruction those weigh
the same.

So the measurement is correct and the conclusion a careless reader would draw
from it is wrong. On real hardware this change is worth far more than ten
cycles; here the tool cannot see the part that matters, and reports only the
instruction it happened to eliminate along the way.

Sit with that, because it generalises well beyond this machine. A measurement
tells you about the thing it measures. Improving the number is only the same
as improving the program when the number is a faithful model of the cost you
care about — and knowing where your model stops being faithful is what
separates measuring from cargo-culting. Here the boundary is precise and
written down: one count per instruction, host interrupts excluded.

## Spending the budget

Three wins, and they were not equally interesting. `djnz` was a smaller
instruction set doing more per instruction. Hoisting was work that never
needed doing. The shift was a real improvement the tool mostly could not see.

What they share is that each came from looking at what ran *often*, not at
what looked expensive. That is the habit worth taking from this chapter, and
it is why measuring comes first: the loop is almost never where you expected,
and forty-five instructions to perform ten additions is the kind of ratio you
only find by asking.

The other habit is knowing when to stop. A program that fits its budget is
finished, and cycles saved past that point buy nothing at all. The budget is
the point — not a smaller number.

## What you now know

`gero run --cycles` reports instructions retired, deterministically, with host
interrupts excluded and no per-instruction cost model — which makes it exact
for comparing two versions of a program and silent about what a divide really
costs. Optimisations pay in proportion to how often they run, so the loop is
where to look. `djnz` collapses a counted loop's bookkeeping; hoisting removes
repetition you did not intend; strength reduction is real even where this tool
cannot price it. And the value of a measurement depends entirely on knowing
what it does not include.

The next chapter goes back to something we have used since chapter 2 without
examining it: how a program reaches anything outside itself.
