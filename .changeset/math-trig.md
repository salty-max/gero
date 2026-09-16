---
bump: major
---

`math` gains trigonometry, rounding and sign, and two functions lose a
qualifier they never needed.

**`fixed_sin` is now `sin`, and takes turns rather than degrees.**
The prefix existed to say "the fixed-point one", but there is no
integer sine to distinguish it from — a sine returning an integer is
meaningless without a scale. `sqrt_fixed` becomes `sqrt`, dispatching
on type the way `abs`, `min` and `clamp` already do. The module was
also inconsistent with itself, carrying the qualifier as a prefix on
one name and a suffix on the other.

Angles are **turns**: one full turn is `1.0`, so a quarter is `0.25`.
On a fixed-point machine this is not a matter of taste. A turn is
exactly the whole part of a Q16.16 value, so the fraction *is* the
angle — wrapping costs a mask where degrees cost a `mod 360` on every
call, and the quarter turns come out exact rather than depending on
360 dividing evenly.

```gero
math.sin(0.25)      -- 1.0, exactly
math.sin(2.25)      -- also 1.0; wrapping is free
math.cos(0.0)       -- 1.0
```

New:

| | |
|---|---|
| `sin` / `cos` | Turns in, Q16.16 out. Within 0.17%, exact at every quarter turn. |
| `atan2(y, x)` | The direction of `(x, y)` in turns, counter-clockwise from `+X`. Within 0.45°, exact on all eight compass directions, and `atan2(0, 0)` is `0`. |
| `flr` / `ceil` | Round down / up. Not `as i16`, which truncates toward zero — they disagree on every negative value with a fraction. |
| `sgn` | `-1`, `0` or `1` in the operand's own type. |
| `sqrt` | Now integer as well as fixed. |

`atan2` takes `i16` deltas because that is what a caller has: the
vector between two positions. It applies no screen-space inversion —
a caller whose Y axis points down passes a down-positive `y` and gets
the angle it means, which is the only way one function serves both
conventions.

Every one is evaluable in a `bake` body, and the compile-time result
matches the runtime bit for bit — verified by a test that prints a
baked constant beside the same call made live.
