# Benches

A small corpus with committed baselines, so a performance regression
fails a gate instead of being noticed months later.

Run them with:

```bash
zig build bench-check
```

## Two numbers, gated differently

**Cycles are exact.** The VM retires one cycle per instruction and is
deterministic, so the same image always produces the same count. A
change here means the emitted program changed — codegen, the ISA, or
an example — and never the machine it ran on. The gate demands an
exact match and the diff names the program.

**Throughput is a floor.** Wall-clock rate depends on the machine, the
build mode and what else is running, so an exact target would flake.
The floor sits an order of magnitude below what these produce on a
developer machine, which makes it useless for spotting a few percent
and reliable for spotting a collapse.

That split is not theoretical. The VM's read path once took its 64 KB
address space *by value*, copying the whole thing for every byte read,
and ran at 0.18 M instructions/sec against the ~50 it manages now. No
test failed: every program produced exactly the right answer, slowly.
A cycle baseline would not have caught it either — the instruction
counts were correct. Only a throughput floor catches that class of
bug, which is why one is here.

## The corpus

| Bench | What it exercises |
|---|---|
| `dispatch.gas` | The fetch-decode-execute loop with nothing else in it — the cost of dispatch itself |
| `call.gas` | `call` / `ret`, so the stack traffic a flat ALU loop never touches |
| `memory.gas` | Zero page, absolute and indexed addressing at equal weight |

Each runs a few million instructions: long enough that throughput is
measurable, short enough that the gate stays inside a second.

## Re-blessing

A cycle count moving is not automatically wrong, but it must be
deliberate. Say in the PR which change moved it and why, then edit the
row. A rate below the floor is different — profile before touching the
number, because the floor is low enough that reaching it is a real
regression rather than a slow afternoon.

The benches build their own `ReleaseFast` binary. A Debug VM runs
roughly ten times slower, which is under the floor, so benching a
Debug build would measure the build.
