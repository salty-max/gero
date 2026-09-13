---
bump: minor
---

The wasm artifact carries both books.

`docs/machine/` — The Gero Machine — now ships beside The Gero Book in
a single `books.json`, replacing the one-book `book.json`. A browser
host cannot list a directory over HTTP, so the manifest is how a reader
finds the chapters at all, and a second book that is not in it is a
second book the lab cannot show.

Each entry carries an `id`, which is what a reader's URL carries and
what a link from one book into the other resolves against — the two
books cross-reference each other in their front matter, and those links
should stay in the reader rather than leaving for the repository.
