---
bump: patch
---

The published package can be used as a dependency.

Every release so far could not. `build.zig` reads three example
programs into build options, and did so from the **process's working
directory** — which is the dependent's root, not gero's, whenever gero
is a dependency. `examples/` is also outside the package's `.paths`,
so the files are not in the tarball at all. A consumer got a panic
during dependency resolution, before any of their own code compiled:

```
thread panic: makeExamplesOptions: read examples/asm/hello.gas failed (FileNotFound)
```

Paths now resolve against this package's own root, and a missing
example yields an empty option rather than aborting the build. gero's
own gates are unaffected — its build root has the files, so its
example tests read them exactly as before. A dependent never runs
those tests, and now never reads the files either.

This surfaced the first time anything tried to depend on gero.
