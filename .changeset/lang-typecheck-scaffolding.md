---
bump: minor
---

`gero.lang.typecheck` lands as a no-op walker — the first slice of
the gero-lang typechecker (option B sequential PRs, parent #233).
Ships the bones: type representation, scope + symbol-table
primitives, and an AST walker that visits every variant. Subsequent
slices populate resolution, inference, and the spec's semantic
rules.

**`src/lang/types.zig`**

`Type` union for the typechecker's internal shape — primitives
(`i8`/`u8`/`i16`/`u16`/`bool`/`nil`/`str`/`fixed`/`char`), `array`,
`vec`, `tuple`, `function`, `optional` (`T?`), `reference` (`&T`),
`named` (user-defined types). Structural equality on every variant.
Builders: `mkPrimitive` / `mkOptional` / `mkReference` / `mkArray` /
`mkVec` / `mkNamed`.

**`src/lang/scope.zig`**

`Scope` struct with parent pointer + `ident → SymbolInfo` map.
Operations: `init` / `deinit` / `define` (errors on local-scope
redefinition) / `lookup` (walks parent chain) / `lookupLocal` /
`setType` (patch an entry once inference has resolved a type).
`SymbolKind` covers the 9 shapes the typechecker tracks (let /
const / def / class / struct / enum / param / module alias /
imported).

**`src/lang/typecheck.zig`**

`pub fn typecheck(allocator, source, *ast.Program) !CheckedProgram`.
Walks every statement and expression variant in the AST without yet
emitting any rule violation. `CheckedProgram` owns a `*Type` arena
and the diagnostics slice.

Public re-exports: `gero.lang.types`, `gero.lang.scope`,
`gero.lang.typecheck`, `gero.lang.CheckedProgram`.

Mirror tests: `tests/lang/types.test.zig` (9 tests),
`tests/lang/scope.test.zig` (8 tests),
`tests/lang/typecheck.test.zig` (11 tests covering the walker
across every AST surface).
