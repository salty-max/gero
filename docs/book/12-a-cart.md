# 12. A cart, end to end

The program the last eleven chapters were growing is a directory.

```
fight/
  gero.toml
  src/
    main.gr
    fighter.gr
    items.gr
  tests/
    heal.gr
```

`gero.toml` names it and points at the entry:

```
[package]
name = "fight"
version = "0.1.0"

[build]
entry = "src/main.gr"

[test]
include = ["tests/"]
```

`src/fighter.gr` is the class. `src/items.gr` is the enum and
`describe`. `src/main.gr` puts them together:

```gero
use Fighter from "./fighter"
use Item from "./items"
use describe from "./items"

def main()
  let ryu = Fighter("Ryu", 30)
  ryu.take_damage(7)
  print ryu.hp
  ryu.heal(15)
  print ryu.hp
  print describe(Item.Potion(15))
end
```

From that directory:

```bash
gero test
gero build
gero run out/debug/fight.gx
```

```
running 1 test
test heal_caps_at_max ... ok

1 passed
```

```
23
30
potion
```

That is the cart. Source in, one file out, the file runs. The
test is not in the file — release strips `@test` and `@bench`.
What ships is `out/debug/fight.gx`, or `out/release/fight.gx` if
you asked for it.

The same program lives at `examples/lang/fight/` in the Gero
repository. Copy it, change the name, add a second fighter. The
loop has not changed since chapter 1: compile, run, read the
bytes back if you want to.

The Gero Machine is the other book, for the layer this one
reached in through `asm` and `@interrupt`. You do not have to
have read it. You can.
