---
bump: minor
---

`gero lsp` offers imports from files the document has not mentioned.

A name declared in a sibling file that nothing imports yet is not part
of any program the checker was asked about, so there is no binding for
it to have recorded and no fix for it to suggest. The server therefore
keeps its own index of what the workspace exports: `initialize`'s
`rootUri` names a directory, and a code-action request walks it for
`.gr` files and reads what each declares — skipping `local`
declarations and the document being edited.

The import is spelled relative to the importing document rather than
to the workspace root, since that is what a `use` resolves against: a
file one directory down is `"./lib/vec"`, one directory up is
`"../vec"`. Several files exporting one name produce one action each
rather than a guess between them.

Buffers the editor holds unsaved shadow the disk, so a name typed a
minute ago in another tab is offered like any other — including from a
file that has never been saved at all. The index is refreshed per
request rather than watched, so a file saved elsewhere is seen; a file
whose size and modification time are both unchanged is reused from the
previous pass rather than parsed again, which keeps a per-keystroke
completion request to a walk and a stat per file.

A correction the checker worked out always wins. A name one edit from
something local is likelier a typo than a reach for another file, and
an import is the more disruptive of the two.
