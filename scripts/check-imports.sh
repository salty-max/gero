#!/usr/bin/env bash
# check-imports.sh — forbid @import("../../...") deeper than one parent.
#
# Single-level relative imports (`./foo.zig`, `../foo.zig`) are allowed for
# sibling barrel access. Anything reaching past one parent is rejected so
# the source tree stays shallow and refactor-safe.
#
# Usage:
#   bash scripts/check-imports.sh                    # walk every .zig in src/
#   bash scripts/check-imports.sh file1.zig file2.zig  # check only listed files
#                                                       # (used by lefthook with {staged_files})
#
# Allowlist a violation by adding `// allow-import: <reason>` on the line
# directly above the offending @import. Reviewer-gated; rare.
set -e

violations=0
report() {
  local file="$1" line="$2" content="$3"
  echo "  $file:$line: $content"
  violations=$((violations + 1))
}

scan_file() {
  local file="$1"
  [[ -f "$file" && "$file" == *.zig ]] || return 0

  # Read line by line so we can check the previous line for the allowlist.
  local prev=""
  local lineno=0
  while IFS= read -r line; do
    lineno=$((lineno + 1))
    if echo "$line" | grep -qF '../../'; then
      if [[ "$prev" == *"allow-import:"* ]]; then
        prev="$line"
        continue
      fi
      report "$file" "$lineno" "$line"
    fi
    prev="$line"
  done < "$file"
}

if [[ $# -eq 0 ]]; then
  # Whole-tree mode.
  while IFS= read -r -d '' file; do
    scan_file "$file"
  done < <(find src -type f -name "*.zig" -print0 2>/dev/null)
else
  # Per-file mode (lefthook).
  for file in "$@"; do
    scan_file "$file"
  done
fi

if [[ "$violations" -gt 0 ]]; then
  echo
  echo "❌ $violations deep relative import(s) found." >&2
  echo "   Single-level '../' is allowed; '../../' and deeper is forbidden." >&2
  echo "   See CLAUDE.md \"Imports\"." >&2
  exit 1
fi
