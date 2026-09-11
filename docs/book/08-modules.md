# 8. Modules

One file held the enum, the class, and `main`. That is fine until it
is not. Each `.gr` file is a **module**. Names in one are invisible
to another until you `use` them.

## Splitting the fight

Three files, next to each other.

`src/items.gr`:

```gero
enum Item
  case Potion(amount: i16)
  case Ether
end

def describe(item: Item) -> str
  match item
    case Item.Potion(_) => return "potion"
    case Item.Ether => return "ether"
  end
end
```

`src/fighter.gr`:

```gero
class Fighter
  let name: str
  let hp: i16
  let max_hp: i16

  def init(self, name: str, hp: i16)
    self.name = name
    self.hp = hp
    self.max_hp = hp
  end

  def take_damage(self, amount: i16)
    self.hp -= amount
    if self.hp < 0
      self.hp = 0
    end
  end

  def heal(self, amount: i16)
    self.hp += amount
    if self.hp > self.max_hp
      self.hp = self.max_hp
    end
  end
end
```

`src/main.gr`:

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

`use Fighter from "./fighter"` brings that one name into this file.
`"./fighter"` is relative to the file doing the importing, and it is
case-sensitive on every machine — a `Fighter.gr` that works on your
laptop and fails in CI is `E_USE_CASE_MISMATCH`.

`use fighter` without a path looks in the standard library first,
then the current directory. Quote the path when you mean a file
next to you.

Everything at the top level is exported by default. `local def helper`
stays in its file.

## A project

A cart is not one `gero compile`. It is a directory with a
`gero.toml` at the root:

```
[package]
name = "fight"
version = "0.1.0"

[build]
entry = "src/main.gr"
```

```bash
gero build
gero run out/debug/fight.gx
```

```
23
30
potion
```

`gero build` walks up from the current directory until it finds
`gero.toml`, compiles `[build].entry`, and writes
`out/<optimize>/<name>.gx`. `debug` is the default profile; `--optimize=release`
and `size` have their own subdirectories so they do not clobber each
other.

`gero compile file.gr` is still there for a single file. Once there
are three, the manifest is the way in.

This fight lives in `examples/lang/fight/` in the Gero repository if
you want to read it as a directory rather than as fences.

---

Ryu is a class, his items are an enum, the program is three files
and a manifest. That is a program, not a script.

---

**Next:** [Numbers that are not integers](09-fixed.md) — a quarter
of seven damage.
