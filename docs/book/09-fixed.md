# 9. Numbers that are not integers

Ken's attacks currently remove ten hit points. Suppose Ryu's armor blocks one
quarter of each hit. “One quarter” is a fraction, and so far every number in
the fight has been an integer.

This chapter introduces fixed-point numbers. Along the way, we will separate a
number's meaning from its representation, decide where rounding belongs in a
program, and look at the cost of arithmetic on a small machine.

## Why integer division loses information

An integer-only calculation can express 25 percent as a ratio:

```gero
def main()
  let power: i16 = 10
  let remaining = power * 75 / 100
  print remaining
end
```

This prints `7`. Multiplication happens before division, which preserves more
information than `power / 100 * 75`, but the final division must still produce
an integer. It discards the remainder of 750 divided by 100.

That may be the rule a game wants. The harder problem is that `75` and `100`
do not say what they mean. They might be percentages, cents, frames, or map
units. Every calculation has to remember the same unwritten scale.

A type can make the scale part of the program.

## Fixed point gives an integer a scale

A `fixed` value is a signed 32-bit integer interpreted with 16 fractional
bits. This representation is called **Q16.16**: 16 bits describe whole units
and 16 bits describe fractions of a unit.

The scale is 65,536. To encode `1.5`, the compiler stores
`1.5 * 65,536`, which is 98,304. The binary point is implied by the type; it
does not occupy a separate field in memory.

```gero
def main()
  let half: fixed = 0.5
  let one_and_half: fixed = 1.5
  let world_x: fixed = 200.8

  print half
  print one_and_half
  print world_x
end
```

The program prints:

```text
0.500
1.500
200.800
```

Gero manages the scale when it performs arithmetic, so the source code uses
the same operators as other numeric types:

```gero
def main()
  let power: fixed = 10.0
  let blocked: fixed = 0.25
  let remaining = power * (1.0 - blocked)
  print remaining
end
```

This prints `7.500`. The expression mirrors the rule: subtract the blocked
fraction from one, then multiply the attack power by what remains.

## Types describe which operations make sense

An `i16` and a `fixed` value can both contain the bit pattern for a small
whole number, but they give those bits different meanings. Gero therefore
requires an explicit cast at the boundary between them.

```gero
def reduced_damage(power: i16, blocked: fixed) -> i16
  let remaining: fixed = 1.0 - blocked
  let scaled_power: fixed = power as fixed
  return (scaled_power * remaining) as i16
end

def main()
  print reduced_damage(10, 0.25)
end
```

`power as fixed` applies the Q16.16 scale, turning the integer `10` into
`10.0`. The multiplication produces `7.5`. The final cast rounds toward zero,
so the function returns the integer `7`.

That final cast is a policy decision. If every hit is converted separately,
two attacks that each calculate to `7.5` deal 14 integer hit points. If the
game accumulates damage as `fixed` and converts only after both attacks, they
deal 15. Neither rule is universally correct. Keeping the cast visible makes
the chosen rule reviewable.

## Range and precision share a bit budget

Q16.16 can represent values from `-32768.0` through approximately
`32767.99998`. Adjacent values differ by `1 / 65536`, or approximately
`0.00001526`.

This is enough range for a position to cross a large game map while retaining
subpixel movement:

```gero
def main()
  let x: fixed = 200.8
  let velocity: fixed = 0.35
  x += velocity
  print x
end
```

The result prints as `201.150`. The stored result is close to 201.15; the
default formatter shows three digits after the decimal point.

Finite precision means that many decimal fractions have no exact binary
representation. The compiler stores the nearest Q16.16 value:

```gero
def main()
  let tenth: fixed = 0.1
  print tenth
end
```

This prints `0.100`, while the stored value is approximately
`0.1000061`. Printing fewer digits can hide a small representation error; it
does not remove it. Repeated calculations can accumulate such differences.

The same limit exists in every finite numeric representation. Integer cents
cannot represent half a cent, and binary floating point cannot represent every
decimal fraction either. Choose a representation whose step size and range
fit the rules of the program.

## Overflow and operation order still matter

Arithmetic wraps if a result leaves the `fixed` range. A calculation can
overflow in an intermediate step even when a rearranged formula would produce
an in-range answer. Multiplication and division can also discard low
fractional bits when they restore the Q16.16 scale.

These facts make operation order part of program design:

- Multiply before dividing when that preserves a useful remainder and the
  product stays in range.
- Divide first when it prevents an overflowing product and the lost precision
  is acceptable.
- Keep units consistent. A position, a velocity per frame, and a duration in
  frames can combine; a raw palette index cannot become a distance merely
  because both use numbers.
- Test values near zero and near the largest magnitude the program permits.

Names help carry those decisions:

```gero
let distance_px: fixed = 1200.0
let duration_frames: fixed = 40.0
let speed_px_per_frame = distance_px / duration_frames
```

The compiler checks types. Names explain units to people.

## Arithmetic has a machine cost

The VM has 16-bit registers, so a `fixed` value occupies a pair of words.
Addition and subtraction operate on the low word and carry into the high word.
Comparisons inspect both words. Multiplication combines several 16-bit partial
products.

General division does considerably more work: it computes a 32-bit quotient
with a software loop. The compiler replaces division by an exact power-of-two
constant, such as `value / 2.0` or `value / 0.5`, with shifts while preserving
rounding toward zero.

The benchmark in `examples/lang/fight/tests/fixed_bench.gr` records the cycle
count of one small expression in each benchmark body:

| Benchmark | VM cycles |
|---|---:|
| addition | 20 |
| multiplication | 60 |
| general division | 635 |
| division by `2.0` | 18 |
| comparison | 34 |
| fixed-argument identity call | 15 |

These counts include loading the local operands and leaving the benchmark
function, so use them to compare these particular bodies rather than as a
price attached to one opcode. The important shape is clear: general division
costs about thirty times as much as addition, while division by `2.0` takes the
short shift path.

This leads to a useful performance rule: calculate constant ratios during
setup when possible, then multiply inside a per-frame loop. Measure before
making a less readable transformation, and keep general `fixed` division out
of a hot loop when the cycle budget is already tight.

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

Ken deals 7 damage per attack. Ryu reaches the potion one turn later and
survives long enough to finish the fight:

```text
turn 1: Ken has 28 hp
turn 2: Ken has 21 hp
turn 3: Ken has 14 hp
Ryu drinks a potion and has 15 hp
turn 4: Ken has 7 hp
turn 5: Ken has 0 hp
Ryu wins with 8 hp
```

The type lets the program state the armor rule directly. The casts show where
fractional information begins and where the game deliberately discards it.

## What you learned

A fixed-point number stores an integer together with an implied scale. Gero's
Q16.16 `fixed` type uses four bytes, covers roughly -32,768 through 32,768,
and represents fractions in steps of 1/65,536. Its arithmetic is deterministic,
but precision, range, overflow, rounding policy, and operation cost remain
choices the programmer must understand.

---

**Next:** [Testing and measuring](10-testing.md) — turning the fight's rules
into checks the machine can repeat.
