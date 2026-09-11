---
bump: patch
---

Interned string literals now have debug data symbols (`str_0`,
`str_1`, …), so the disassembler renders them as `data8` — with
the text in a comment when it's printable ASCII — instead of
decoding `"Hello"` as `inc r?65`.
