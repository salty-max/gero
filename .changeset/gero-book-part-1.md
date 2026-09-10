---
bump: patch
---

The Gero Book — front matter and the first four chapters. A guided path
into gero-lang for someone who has never targeted a machine like this,
building one program across the chapters rather than a fresh snippet
each time.

Chapter 1 gets a program running before it explains anything, then says
what the machine is and why 64 KB is the point. Chapters 2–4 cover
values and types, control flow, and functions, ending with a fight loop
whose pieces are named and testable.

Every code block is compiled by `zig build verify`, and the gates glob
the book directories so a new chapter is covered without a build
change.
