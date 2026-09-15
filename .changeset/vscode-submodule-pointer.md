---
bump: patch
---

The `editors/vscode-gero` submodule points at a commit on that repo's
`main`.

It recorded `e9a234d`, the tip of a branch that a rebase-merge
replaced and deleted, so the SHA a checkout resolves is reachable only
through a pull-request ref. `git submodule update` still works —
GitHub keeps such commits for a while — and stops the moment one is
collected.

Anyone cloning v0.4.0 and initialising submodules is relying on that.
This release points at `e7d471b` instead, which is a branch tip.
