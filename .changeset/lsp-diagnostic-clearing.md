---
bump: patch
---

Opening one document no longer clears another's diagnostics.

The server tracked which URIs were carrying diagnostics as one global
set, and each analysis cleared everything in it that the analysis
itself had not just published. So opening any second file retracted
the first one's errors: the analysis of `lib.gr` says nothing about
`main.gr`, but wiped it all the same.

In an editor that reads as diagnostics vanishing when you switch tabs
and never coming back, because a client does not re-send `didOpen` for
a tab it already holds — nothing prompts a re-check until the file is
edited.

The record is now kept per analysed document, and a retraction only
covers what that document's own previous analysis published. An error
in an imported file is still published against that file and still
cleared when fixed, which is what the tracking was for.
