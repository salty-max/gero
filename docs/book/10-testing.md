# 10. Testing and measuring

The fight contains rules that prose alone cannot protect. Healing must stop at
`max_hp`. Damage must stop at zero. Armor must reduce ten points of power to
seven damage.

A **test** is an executable example of a rule. It prepares a situation,
performs an action, and checks the result.

## Write a test that passes

Create `tests/heal.gr` beside the `src` directory:

```gero
use Fighter from "../src/fighter"
use test

@test
def heal_caps_at_max()
  let ryu = Fighter("Ryu", 30, 7)
  ryu.take_damage(7)
  test.assert_eq(ryu.hp, 23)
  ryu.heal(15)
  test.assert_eq(ryu.hp, 30)
end
```

The `@test` annotation marks the function for the test runner. The function
name describes the behavior rather than the implementation.

The body has three stages:

1. **Arrange:** construct a fighter and put it at 23 hit points.
2. **Act:** heal it by 15.
3. **Assert:** check that the result is capped at 30.

`test.assert_eq(actual, expected)` continues when the values are equal. When
they differ, it prints a diagnostic and fails this test run.

Tell the manifest where tests live:

```toml
[test]
include = ["tests/"]
```

Then run them from the project directory:

```bash
gero test
```

```text
running 1 test
test heal_caps_at_max ... ok

1 passed
```

Each test starts on a fresh virtual machine. State left by one test cannot
change the next one, and the order of the tests should not matter.

## Watch a test fail

A test is only useful if it can detect the wrong behavior. Change the final
expected value to 31. This version is deliberately wrong:

```gero
use Fighter from "../src/fighter"
use test

@test
def heal_caps_at_max()
  let ryu = Fighter("Ryu", 30, 7)
  ryu.take_damage(7)
  ryu.heal(15)
  test.assert_eq(ryu.hp, 31)
end
```

The test runner reports a failed assertion and exits unsuccessfully. Restore
the expected value to 30 and run it again. This fail-then-pass check proves
that the test observes the behavior it claims to protect.

## Test boundaries, not just ordinary cases

Most bugs live near boundaries: zero, the maximum, an empty collection, or the
first value on the other side of a condition. Add two more tests to the same
file:

```gero
use Fighter from "../src/fighter"
use reduced_damage from "../src/fighter"
use test

@test
def heal_caps_at_max()
  let ryu = Fighter("Ryu", 30, 7)
  ryu.take_damage(7)
  test.assert_eq(ryu.hp, 23)
  ryu.heal(15)
  test.assert_eq(ryu.hp, 30)
end

@test
def damage_stops_at_zero()
  let ryu = Fighter("Ryu", 30, 7)
  ryu.take_damage(40)
  test.assert_eq(ryu.hp, 0)
  test.assert_eq(ryu.alive(), false)
end

@test
def armor_reduces_damage()
  test.assert_eq(reduced_damage(10, 0.25), 7)
end
```

The first test checks the upper boundary, the second checks the lower one, and
the third pins the conversion from fractional to integer damage.

```text
running 3 tests
test heal_caps_at_max ... ok
test damage_stops_at_zero ... ok
test armor_reduces_damage ... ok

3 passed
```

Use `gero test armor` to run only tests whose names contain `armor`. Filtering
is convenient while working on one rule; run the full suite before shipping.

## Assertions inside the cart

`test.assert_eq` belongs in `@test` functions. Gero also provides
`assert(condition)` for an invariant that the running cart must enforce.

An **invariant** is a fact that should remain true throughout a part of the
program. If reaching a particular line while `hp < 0` would mean the program
is internally inconsistent, an assertion can stop there instead of allowing
the bad state to spread.

Tests are excluded from ordinary builds. Runtime assertions remain in the
cart because they protect the program while it runs.

## Measure work with a benchmark

Correctness asks whether the answer is right. A **benchmark** asks how much
work the answer takes.

Add this function to `tests/heal.gr`:

```gero
@bench
def bench_construct_and_take_damage()
  let ryu = Fighter("Ryu", 30, 7)
  ryu.take_damage(7)
end
```

Run it with:

```bash
gero bench
```

```text
running 1 benchmark, 1000 iterations each
bench bench_construct_and_take_damage ... ok  (avg 87 cyc, min 87 cyc, max 87 cyc)
```

The VM counts its own instruction cycles, so the result does not depend on
whether the host computer was briefly busy. Every iteration starts from a
fresh machine. The benchmark name is deliberately precise: its 87 cycles
include constructing the fighter as well as applying damage.

Change one thing at a time when comparing benchmarks. If you change both the
algorithm and the setup, the new number cannot tell you which change mattered.

## What you learned

A test turns expected behavior into a repeatable check. Good tests arrange a
situation, act on it, and assert an observable result, especially at boundary
values. A benchmark measures a named piece of work in deterministic VM cycles.
Together they replace “this should still work” with evidence.

---

**Next:** [Reaching the machine](11-reaching-the-machine.md) — inspecting the
layer beneath the language and using its narrow escape hatches.
