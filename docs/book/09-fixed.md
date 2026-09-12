# 9. Numbers that are not integers

Ken's attacks currently remove ten hit points. Suppose Ryu's armor blocks one
quarter of each hit. “One quarter” is a fraction, and the machine only has
integer arithmetic.

This is the problem fixed-point numbers solve.

## Why integer division loses information

An integer-only calculation can express 25 percent as a ratio:

```gero
def main()
  let power: i16 = 10
  let remaining = power * 75 / 100
  print remaining
end
```

The program keeps 75 percent of the attack and prints 7. The multiplication
happens before division, but the final division still discards the remainder.
The exact intermediate answer, 7.5, cannot be stored in an integer.

Sometimes that truncation is exactly the rule a game wants. The weakness is
that `75` and `100` carry no unit: a reader must infer that they encode a
percentage, and every calculation must choose a scale consistently.

## Fixed point stores an implied fraction

A `fixed` value uses the same 16 bits as an `i16`, but interprets them
differently. Eight bits hold the whole-number part and eight hold fractions in
steps of 1/256.

```gero
def main()
  let half: fixed = 0.5
  let one_and_half: fixed = 1.5
  print half
  print one_and_half
end
```

`1.5` is stored as the integer 384. Dividing 384 by the fixed scale, 256,
gives 1.5. The binary point is implied; it is not stored separately.

Gero applies that scale when it multiplies and divides, so source code uses the
ordinary arithmetic operators:

```gero
def main()
  let power: fixed = 10.0
  let blocked: fixed = 0.25
  let remaining = power * (1.0 - blocked)
  print remaining
end
```

The program prints `7.500`. The expression follows the rule directly: keep one
minus the blocked fraction, then multiply power by it.

## Converting is a decision

Hit points are integers in our fight, so fractional damage must eventually
become an integer. A cast with `as` makes that boundary visible:

```gero
def reduced_damage(power: i16, blocked: fixed) -> i16
  let remaining: fixed = 1.0 - blocked
  return ((power as fixed) * remaining) as i16
end

def main()
  print reduced_damage(10, 0.25)
end
```

The first cast turns 10 into the fixed value `10.0`. The multiplication
produces `7.5`. The final cast converts back to `i16` by truncating toward
zero, so the function returns 7.

This is useful even though the final answer is an integer. The types expose
where the fraction exists and the cast records where the program deliberately
discards it.

## Precision and range are finite

Fixed point is predictable, not exact for every decimal:

```gero
def main()
  let tenth: fixed = 0.1
  print tenth
end
```

The output is `0.101`. One tenth is not a whole number of 1/256 steps, so the
compiler stores the nearest representable value. Repeated calculations can
accumulate that small difference.

The other trade is range. An 8.8 `fixed` value covers roughly -128 through
127.996. A world position that can reach 500 does not fit. A common design is
to keep whole units in an `i16` and use a fixed value only for the sub-unit
remainder:

```gero
def main()
  let x: i16 = 200
  let sub: fixed = 0.8

  sub += 0.35
  while sub >= 1.0
    sub -= 1.0
    x += 1
  end

  print x
  print sub
end
```

The whole position becomes 201 and the remainder prints as approximately
`0.152`. The representation is small and deterministic; the program chooses
how to handle its limits.

Use `fixed` when the value is naturally a small fraction, scale, velocity, or
ratio. Use an integer with a named unit when exact counting or a wider range is
more important.

## Armor changes the fight

Add `reduced_damage` to `src/fighter.gr` after the class, then import it in
`src/main.gr`:

```gero
use Fighter from "./fighter"
use reduced_damage from "./fighter"
use Item from "./items"
use heal_from from "./items"
```

Replace Ken's attack with the armored calculation:

```gero
if ken.alive()
  ryu.take_damage(reduced_damage(ken.power, 0.25))
end
```

Ken now deals 7 damage instead of 10. Ryu reaches the potion one turn later
and survives long enough to finish the fight:

```text
turn 1: Ken has 28 hp
turn 2: Ken has 21 hp
turn 3: Ken has 14 hp
Ryu drinks a potion and has 15 hp
turn 4: Ken has 7 hp
turn 5: Ken has 0 hp
Ryu wins with 8 hp
```

The new type did not merely change a notation. It let us state an armor rule,
choose where fractional information is discarded, and change the outcome of
the program.

## What you learned

Fixed-point numbers store fractions by giving an integer an implied scale.
They make small ratios cheap and deterministic, but their precision and range
are limited. Conversions between integers and fixed point mark decisions about
where fractions begin and end.

---

**Next:** [Testing and measuring](10-testing.md) — turning the fight's rules
into checks the machine can repeat.
