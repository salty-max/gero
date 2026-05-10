#!/usr/bin/env bash
# check-testing-allocator.sh — every alloc-touching test must use
# std.testing.allocator (which leak-checks).
#
# Heuristic: a test file is "alloc-touching" if its body contains any of
# `.alloc(`, `.dupe(`, `.create(`, `.realloc(`, `.free(`, or the type name
# `Allocator`. In any such file, `std.testing.allocator` must also appear.
#
# Allowlist: add `// allow-test-allocator: <reason>` somewhere in the
# file (typically near the top) for tests that legitimately use a
# different allocator (e.g. exercising arena-deinit semantics with a
# bespoke allocator).
#
# Whole-tree only — the lint is about hygiene across the test suite.
#
# Usage:
#   bash scripts/check-testing-allocator.sh
set -euo pipefail

ROOT="${ROOT:-.}"
violations=0

# Tokens that signal an alloc-touching test. `Allocator` (capitalized type
# name) is broad on purpose; tests that just declare `pub fn run(... a:
# std.mem.Allocator)` already lean on the testing allocator's leak-check.
TOKENS=(
  ".alloc("
  ".dupe("
  ".create("
  ".realloc("
  ".free("
  "Allocator"
)

scan_file() {
  local file="$1"
  [[ -f "$file" && "$file" == *.test.zig ]] || return 0

  # Allowlisted? Free pass.
  if grep -qF "// allow-test-allocator:" "$file"; then
    return 0
  fi

  # Does the file touch allocations?
  local touches_alloc=0
  for tok in "${TOKENS[@]}"; do
    if grep -qF "$tok" "$file"; then
      touches_alloc=1
      break
    fi
  done

  [[ "$touches_alloc" -eq 0 ]] && return 0

  # Then std.testing.allocator must appear.
  if ! grep -qF "std.testing.allocator" "$file"; then
    echo "  $file: alloc-touching test but no std.testing.allocator usage"
    violations=$((violations + 1))
  fi
}

while IFS= read -r -d '' file; do
  scan_file "$file"
done < <(find "$ROOT/tests" -type f -name "*.test.zig" -print0 2>/dev/null)

if [[ "$violations" -gt 0 ]]; then
  echo
  echo "❌ $violations alloc-touching test(s) without std.testing.allocator." >&2
  echo "   Use std.testing.allocator (leak-checked) or allowlist with" >&2
  echo "   '// allow-test-allocator: <reason>' if a different allocator is" >&2
  echo "   intentional." >&2
  echo "   See CLAUDE.md \"Testing\"." >&2
  exit 1
fi
