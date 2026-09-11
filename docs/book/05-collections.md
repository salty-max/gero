# 5. Collections

Ryu is still four loose variables. Before he can carry a bag, we
have to pick a place for the things in it to live. Gero has three,
and they cost different amounts.

## A pair you already know

Chapter 4 returned `(bool, i16)` — did the attack land, and for how
much. That is a **tuple**: a handful of values of mixed types, sitting
in the same slots a local would. No heap, no length, no growing.
Two, three, or four elements; past that, give the thing a name.

```gero
def main()
  let hit: (bool, i16) = (true, 7)
  print hit.0
  print hit.1
end
```

`true` then `7`. `.0` and `.1` are the slots. You have already
destructured one with `let (hit, dmg) = attack(...)`.

## A row of the same thing

An **array** is a fixed number of the same type. The length is part
of the type — `[i16; 4]` is four signed integers, always, and the
compiler knows that before the program runs.

```gero
def main()
  let party: [i16; 2] = [30, 30]
  print party[0]
  party[1] -= 7
  print party[1]
end
```

`30` then `23`. Assignment copies the whole array. Passing one to a
function copies it too. Four `i16`s are eight bytes; you can know
that without a profiler.

A constant index that does not fit — `party[4]` on an array of two —
is a compile error. A runtime index that does not fit faults.

`1..=n` was the counting range; `0..n` is the indexing one. Walking
an array is the latter:

```gero
def main()
  let scores: [i16; 3] = [10, 20, 30]
  for s in scores
    print s
  end
end
```

`10`, `20`, `30`.

Use an array when you know the count at compile time: a party of four,
a palette of sixteen, the four directions.

## A bag that grows

A **`Vec`** is a length that is allowed to change. The value itself
is six bytes — a pointer, a length, a capacity — and the items live
on the heap, which on this machine is the rest of the 64 KB after
your program.

```gero
def main()
  let bag: Vec(i16) = Vec.new()
  bag.push(15)
  bag.push(15)
  print bag.len()
  print bag.at(0)
  for n in bag
    print n
  end
end
```

`2`, `15`, then `15` and `15` again from the loop. `push` appends and
grows the buffer when it is full (it doubles). `at` faults if the
index is out of range; `get` returns `nil` instead. `pop` takes from
the end and also returns `nil` when the bag is empty — more on that
the moment we have something typed to put in it.

`Vec.from([1, 2, 3])` builds one already filled. `Vec.with_capacity(64)`
builds an empty one that will not reallocate before the sixty-fifth
`push`.

## What each costs

A tuple is the cheapest: it is the values, in place. An array is
cheap if `N` is small and known — it is still the values, in place,
copied when you pass it. A `Vec` is a 6-byte handle plus a heap
buffer that grows. The handle copies; the buffer does not. Two
variables holding the same `Vec` see the same items.

On 64 KB that difference is the whole decision. A party of four hit
points is an array. An inventory that gains and loses items is a
`Vec`. A function that answers two questions is a tuple.

Ryu's bag is a `Vec`. Next we say what is *in* it.

---

**Next:** [Enums and match](06-enums-and-match.md) — a potion is not
just a number.
