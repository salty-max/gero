# 7. Classes

Ryu has a name, hit points, a maximum, a way to take damage, a way
to drink. Those belong together.

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

def main()
  let ryu = Fighter("Ryu", 30)
  ryu.take_damage(7)
  print ryu.hp
  ryu.heal(15)
  print ryu.hp
  print ryu.name
end
```

`23`, `30`, `Ryu`. `Fighter("Ryu", 30)` calls `init`. Every method
takes `self` as its first parameter — that is the receiver, the
instance the call was made on. `ryu.take_damage(7)` is
`take_damage` with `self` bound to `ryu`.

Fields are `let` bindings on the class. They live in the instance.
`ryu.hp` reads one; `self.hp -= amount` writes one.

A second fighter is another instance, not a copied pile of
variables:

```gero
class Fighter
  let name: str
  let hp: i16

  def init(self, name: str, hp: i16)
    self.name = name
    self.hp = hp
  end
end

def main()
  let ryu = Fighter("Ryu", 30)
  let ken = Fighter("Ken", 30)
  print ryu.name
  print ken.name
end
```

`Ryu` then `Ken`.

## Methods that take no instance

A helper that belongs to the type rather than to one fighter is
`@static`, and you call it on the class name:

```gero
class Fighter
  let hp: i16

  def init(self, hp: i16)
    self.hp = hp
  end

  @static
  def starting_hp() -> i16
    return 30
  end
end

def main()
  let ryu = Fighter(Fighter.starting_hp())
  print ryu.hp
end
```

`30`.

## Inheritance, briefly

`class Hero extends Fighter` is allowed. Single inheritance, methods
resolved bottom-up, `super.init(...)` to run the parent. You do not
need it for two fighters of the same kind. Reach for it when the
shared behaviour is real, not when you want to skip typing `hp`
twice — a function that takes a `Fighter` already does that.

## What a class costs

An instance is a pointer to its fields plus a vtable pointer, two
bytes more than the same fields laid out as a `struct`. `struct` is
the right tool for pure data with no methods. The moment you have
`take_damage`, you want the class.

---

**Next:** [Modules](08-modules.md) — this is now more than one file.
