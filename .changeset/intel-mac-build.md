---
bump: patch
---

Release tarballs now include `x86_64-macos` — Intel Mac users can
install via the Homebrew tap (a follow-up tap update lands separately)
or download the `gero-vX.Y.Z-x86_64-macos.tar.gz` artifact directly.
The release matrix in `.github/workflows/release.yml` cross-builds
the target alongside the existing `aarch64-macos`, `x86_64-linux`,
both Windows architectures, and `wasm32-wasi`.
