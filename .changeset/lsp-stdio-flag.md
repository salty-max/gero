---
bump: patch
---

`gero lsp` accepts `--stdio`.

Most LSP clients append the flag when they name a transport — VS Code's
`vscode-languageclient` does it whenever `TransportKind.stdio` is set —
and the server rejected it as an unknown flag and exited 2. The client
then reported a broken pipe and retried in a loop, so the extension
started nothing at all.

Stdio is the only transport the server speaks, so the flag is accepted
and ignored, and only on `lsp`: it would mean nothing to the other
commands, and quietly accepting a flag that does nothing is worse than
refusing it.
