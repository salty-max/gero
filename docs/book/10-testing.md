# 10. Testing and measuring

`heal` caps at `max_hp`. That is a sentence you can believe until
someone edits the method. A **test** is that sentence, run by the
machine.

In the fight cart, `tests/heal.gr`:

```gero
use Fighter from "../src/fighter"
use test

@test
def heal_caps_at_max()
  let ryu = Fighter("Ryu", 30)
  ryu.take_damage(7)
  test.assert_eq(ryu.hp, 23)
  ryu.heal(15)
  test.assert_eq(ryu.hp, 30)
end
```

`gero.toml` already named the entry. Tests need their own walk:

```
[test]
include = ["tests/"]
```

```bash
gero test
```

```
running 1 test
test heal_caps_at_max ... ok (5.0 ms)

1 passed (5.0 ms)
```

The milliseconds are whatever the machine took. The `ok` is the
point.

Each `@test` def is the entry point of its own run, on a fresh
machine. A clean `hlt` passes. `test.assert_eq` prints and halts
on a mismatch, and that halt is a failure. `assert(cond)` is
always in scope and always compiled — use it for invariants the
shipped cart must never break. `@test` functions are left out of
release builds; they cost nothing on the cart.

Filter by name the same way you would a file:

```bash
gero test heal
```

## Measuring

`@bench` is the same shape, aimed at cycles rather than at a
boolean. The runner executes the body a thousand times on a fresh
machine each time and reports what the VM counted:

```gero
use Fighter from "../src/fighter"

@bench
def bench_take_damage()
  let ryu = Fighter("Ryu", 30)
  ryu.take_damage(7)
end
```

```bash
gero bench
```

```
running 1 benchmark, 1000 iterations each
bench bench_take_damage ... ok  (avg 79 cyc, min 79 cyc, max 79 cyc)
```

The three numbers are equal because the VM is deterministic — same
image, same start, same count. A spread between min and max would
mean the body itself varies, not that the clock is noisy.
`--iter=N` changes the repetition. `@bench` is also stripped from
release.

Seventy-nine cycles is a number you can bring to a scanline. The
addendum on assembly is where 3× stops being abstract.

---

**Next:** [Reaching the machine](11-reaching-the-machine.md) — one
instruction the compiler will not emit, and the other book.
