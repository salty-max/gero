# 5. Collections

A single binding holds one value. Programs often need several related values:
the hit points of every party member, the items in a bag, or the two answers
returned by an attack.

A **collection** groups values so they can be stored and processed together.
Gero has several collection shapes because “several values” can mean different
things.

## Tuples: a few positions with different meanings

Chapter 4 returned whether an attack hit and how much damage it dealt:

```gero
def main()
  let result: (bool, i16) = (true, 7)
  print result.0
  print result.1
end
```

A **tuple** has a fixed number of positions. The values may have different
types, and the type records each position in order. Here, `(bool, i16)` means
that position 0 is a Boolean and position 1 is a signed integer.

Positions are useful when their relationship is obvious and local. Names are
clearer as soon as the tuple arrives:

```gero
def main()
  let result: (bool, i16) = (true, 7)
  let (hit, damage) = result
  print "hit: $(hit), damage: $(damage)"
end
```

The line prints `hit: 1, damage: 7`. Boolean values are written as `true` and
`false` in source; the default output format renders them as the machine values
1 and 0.

Gero tuples can contain up to four values. Beyond that, numeric positions make
code hard to read; a named type is a better model.

## Arrays: a fixed number of one type

An **array** stores a fixed number of values of the same type:

```gero
def main()
  let party_hp: [i16; 2] = [30, 35]
  print party_hp[0]
  party_hp[1] -= 7
  print party_hp[1]
end
```

The type `[i16; 2]` says both what each element is and how many elements exist.
The length is known when the program is compiled and cannot change later.

An **index** selects a position. Indexes begin at zero, so this array has
positions 0 and 1. A constant index such as `party_hp[2]` cannot be valid, and
the compiler rejects it. When an index is calculated while the program runs,
a debug build checks it and faults if it is outside the array.

You can process each value without writing an index:

```gero
def main()
  let party_hp: [i16; 3] = [30, 35, 18]
  for hp in party_hp
    print hp
  end
end
```

The loop binds each element to `hp` in order. Use an index when the position
itself matters; use direct iteration when you only need the values.

Arrays are values. Assignment and parameter passing copy all their elements:

```gero
def hurt_first(party: [i16; 2]) -> [i16; 2]
  party[0] -= 7
  return party
end

def main()
  let original: [i16; 2] = [30, 35]
  let changed = hurt_first(original)
  print original[0]
  print changed[0]
end
```

The output is 30 and then 23. `hurt_first` changes its local copy and returns
that copy; `original` remains unchanged. Copying two integers is cheap.
Copying a large array on every function call may not be, which is one reason
the size appears in its type.

Use an array when the count is part of the program's design: four party slots,
sixteen palette entries, or three difficulty settings.

## `Vec`: a collection whose length can change

An inventory grows when the player finds an item and shrinks when one is used.
Its length is runtime state, so a fixed array is the wrong shape. A **`Vec`**
manages a growable sequence:

```gero
def main()
  let healing: Vec(i16) = Vec.new()
  healing.push(6)
  healing.push(15)

  print healing.len()
  print healing.at(0)

  for amount in healing
    print amount
  end
end
```

`Vec(i16)` means a vector whose elements are all `i16` values. `Vec.new()` is
empty, so the annotation tells the compiler which element type future calls
to `push` must accept.

After two pushes, `len()` returns 2 and `at(0)` returns the first value, 6.
Like array access, `at` checks its index in a debug build. `Vec` also provides
`get` and `pop`, which return an **optional** value: either an element or `nil`
to mean that no element was present. Our fight iterates known elements instead,
so it does not need to unwrap an optional. [`lang.md`](../lang.md#341-nullable-types-t)
defines the complete `T?` syntax.

A `Vec` value occupies six bytes: an address, a current length, and a
**capacity**. The address points to a separate buffer holding the elements.
Capacity is the number of elements that fit in the current buffer. When a
`push` would exceed it, the vector allocates a larger buffer and moves its
elements there.

This distinction is a general programming idea:

- **Length** is how many elements the collection contains now.
- **Capacity** is how many elements its current storage can hold before it
  must grow.

`Vec.with_capacity(16)` creates an empty vector with room for sixteen elements.
It can avoid repeated allocation when you already know a useful upper bound.

A vector owns its backing buffer. Moving a vector into another binding,
passing it to a function, or returning it transfers that handle instead of
copying every element. Do not read or write the old, **moved-from** vector;
its behavior is undefined. This ownership rule keeps one authoritative length,
capacity, and buffer while avoiding a potentially large element copy.

## Choosing a shape

The question is not which collection is best. The question is which fact is
fixed.

| Need | Shape |
|---|---|
| A few related values with different types | tuple |
| A known number of values of one type | array |
| A number of values that changes while running | `Vec` |

Ryu's inventory changes, so it will be a `Vec`. The healing amounts inside it
are still only numbers, though. A `6` cannot tell us whether it means a potion,
a key, or six coins.

## What you learned

Collections turn many values into one value that can be stored, passed, and
processed. Tuples distinguish positions by type, arrays fix both element type
and length, and vectors move ownership of growable storage. Their different
copying and allocation costs follow from those different jobs.

---

**Next:** [Enums and match](06-enums-and-match.md) — representing which kind of
item a value is.
