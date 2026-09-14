---
bump: patch
---

A member list opens when you type the dot.

`gero lsp` advertised no completion trigger characters, on the
reasoning that every completion was an identifier and a client asks
for those on its own while you type. Member completion after a
receiver made that false: `.` is not an identifier character, so
nothing prompted the client to ask, and `math.` or `v.` opened a list
only if you pressed the manual-completion key.

`.` is now advertised, so the list arrives when the dot is typed.
