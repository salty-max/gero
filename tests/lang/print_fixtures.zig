/// Canonical-syntax source fixtures used by the pretty-printer
/// round-trip property test. Each entry covers a different AST
/// shape so a printer drift on a node variant gets caught.
///
/// The round-trip property is:
///     print(parse(src)) == print(parse(print(parse(src))))
///
/// (printer idempotency — the strict-AST round-trip stays out of
/// scope for now; the weaker form catches every regression we've
/// hit in practice).
///
/// New AST variants extending the printer should add at least one
/// fixture here.
pub const fixtures = [_][]const u8{
    // ---------- bindings ----------
    "let x = 0",
    "let x: i16 = 0",
    "let s: str = \"hi\"",
    "let v: fixed = 1.5",
    "let b: bool = true",
    "let c: char = 'A'",
    "let p: i16? = nil",
    "let r = &x",
    "const MAX: i16 = 100",
    "let buf: [i16; 64] = [0; 64]",
    "let v = [1, 2, 3]",
    "let t = (1, 2, 3)",

    // ---------- assignment / inc-dec / discard ----------
    "x = 5",
    "x += 1",
    "x <<= 2",
    "x++",
    "_ = expensive_call()",

    // ---------- operator precedence ----------
    "let r = a + b * c - d / (e + f)",
    "let r = (a & MASK) == TARGET",
    "let r = x as u8 + 1",
    "let r = a + b as u8",
    "let r = -x * 2",
    "let r = not (a and b)",

    // ---------- control flow ----------
    \\if cond
    \\  x = 1
    \\end
    ,
    \\if cond
    \\  x = 1
    \\else
    \\  x = 2
    \\end
    ,
    \\while x > 0
    \\  x -= 1
    \\end
    ,
    \\for i in 0..10
    \\  print i
    \\end
    ,
    \\for i in 0..10 :rows
    \\  break :rows
    \\end
    ,
    \\repeat
    \\  x += 1
    \\until x > 10
    ,

    // ---------- match ----------
    \\match it
    \\  case Item.Sword => print "blade"
    \\  case Item.Potion(n) => print n
    \\  case _ => print "other"
    \\end
    ,
    \\match e
    \\  case Event.Hit((x, 0 | 1)) when x > 0 =>
    \\    print x
    \\end
    ,

    // ---------- functions + lambdas ----------
    \\def add(a: i16, b: i16) -> i16
    \\  return a + b
    \\end
    ,
    \\def greet(name: str)
    \\  print "hi, ", name
    \\end
    ,
    "let f = |x| x * 2",
    "let g = |x, y| x + y",

    // ---------- struct / class / enum ----------
    \\struct Stats
    \\  hp: i16
    \\  mp: i16
    \\end
    ,
    \\class Player
    \\  let hp: i16
    \\
    \\  def greet(self)
    \\    print "hi"
    \\  end
    \\end
    ,
    \\enum Item
    \\  case Sword
    \\  case Potion(amount: i16)
    \\end
    ,

    // ---------- imports ----------
    "use math",
    "use math as m",
    "use abs from math",
    "use sin, cos from math",

    // ---------- annotations ----------
    \\@bank 5
    \\def town_intro_dialog() -> str
    \\  return "Welcome to Mistwood..."
    \\end
    ,
    \\@addr $FE40
    \\@volatile
    \\let DISPCTL: u8 = 0
    ,

    // ---------- defer + asm ----------
    \\def cleanup() end
    \\
    \\def f()
    \\  defer cleanup()
    \\  asm "noop"
    \\end
    ,

    // ---------- bake ----------
    \\bake def make() -> i16
    \\  return 42
    \\end
    ,

    // ---------- references ----------
    \\def apply_damage(stats: &Stats, dmg: i16)
    \\  stats.hp = stats.hp - dmg
    \\end
    ,

    // ---------- nullable + flow ----------
    \\def lookup(s: str?) -> i16
    \\  if s == nil
    \\    return 0
    \\  end
    \\  return s.len
    \\end
    ,
};
