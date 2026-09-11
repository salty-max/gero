#!/usr/bin/env bash
#
# Keep docs/lang-diagnostics.md honest against the compiler.
#
# Every `E_*` / `W_*` code must appear in all three places:
#   1. a meaning-table row in §5
#   2. the registry table in §6
#   3. an emit site in src/ (quoted string)
#
# A documented code with no emission site is a promise nothing keeps;
# an emitted code with no row is a diagnostic a reader cannot look up.
# Either direction fails this gate.
#
# Also: every `v.method(` / `s.method(` in the Vec / str operations
# tables of gero-lang.md must be a method the typechecker implements,
# so a table row cannot quietly describe a method that does not exist.
#
# Exit codes:
#   0 — the three sets match, and the builtin tables name real methods
#   1 — at least one mismatch

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$ROOT/docs/lang-diagnostics.md"
SPEC="$ROOT/docs/gero-lang.md"
SRC="$ROOT/src"

if [[ ! -f "$DOC" || ! -f "$SPEC" ]]; then
    printf 'check-diag-registry: spec files missing\n' >&2
    exit 1
fi

python3 - "$DOC" "$SPEC" "$SRC" <<'PY'
import re, sys, pathlib

doc_path, spec_path, src_path = (pathlib.Path(p) for p in sys.argv[1:])
doc = doc_path.read_text()
spec = spec_path.read_text()

code_re = re.compile(r"`(E_[A-Z0-9_]+|W_[A-Z0-9_]+)`")

# §6 registry: from the heading until the next ## heading.
reg_m = re.search(r"## 6\. Error code registry\n(.*?)(?:\n## |\Z)", doc, re.S)
if not reg_m:
    print("check-diag-registry: no §6 registry heading", file=sys.stderr)
    sys.exit(1)
registry = set(code_re.findall(reg_m.group(1)))

# Meaning tables live in §5 (before the registry).
mean_m = re.search(r"## 5\. Categories\n(.*?)(?:\n## 6\. |\Z)", doc, re.S)
if not mean_m:
    print("check-diag-registry: no §5 categories heading", file=sys.stderr)
    sys.exit(1)
meaning = set(code_re.findall(mean_m.group(1)))

emit = set()
quoted = re.compile(r'"(E_[A-Z0-9_]+|W_[A-Z0-9_]+)"')
for p in pathlib.Path(src_path).rglob("*.zig"):
    emit.update(quoted.findall(p.read_text()))

failed = 0

def report(title, codes):
    global failed
    if not codes:
        return
    failed = 1
    print(f"check-diag-registry: {title}")
    for c in sorted(codes):
        print(f"  {c}")

report("in registry, no emit site in src/", registry - emit)
report("emitted in src/, missing from registry §6", emit - registry)
report("in §5 meaning tables, missing from registry §6", meaning - registry)
report("in registry §6, missing from §5 meaning tables", registry - meaning)

# Builtin method tables vs the typechecker.
def methods_in(zig: pathlib.Path) -> set[str]:
    text = zig.read_text()
    return set(re.findall(r'std\.mem\.eql\(u8, method, "([a-z_]+)"\)', text))

def table_methods(section: str, prefix: str) -> set[str]:
    # `| `v.push(x)` |` / `| `s.at(i)` |` — skip index sugar `v[i]`.
    return set(re.findall(rf"`{prefix}\.([a-z_]+)\(", section))

vec_sec = re.search(r"#### 3\.4\.3 `Vec\(T\)`.+?(?=\n#### |\n### |\n## |\Z)", spec, re.S)
str_sec = re.search(r"#### 3\.2\.1 String operations.+?(?=\n#### |\n### |\n## |\Z)", spec, re.S)
if not vec_sec or not str_sec:
    print("check-diag-registry: Vec / str operations section missing", file=sys.stderr)
    sys.exit(1)

vec_impl = methods_in(src_path / "lang/typecheck/vec_builtin.zig")
str_impl = methods_in(src_path / "lang/typecheck/str_builtin.zig")
vec_doc = table_methods(vec_sec.group(0), "v")
str_doc = table_methods(str_sec.group(0), "s")

report("Vec operations table names a method vec_builtin does not implement", vec_doc - vec_impl)
report("str operations table names a method str_builtin does not implement", str_doc - str_impl)

if failed:
    sys.exit(1)
print(
    f"check-diag-registry: {len(registry)} codes match emit sites; "
    f"Vec {sorted(vec_doc)} / str {sorted(str_doc)} match the typechecker"
)
PY
