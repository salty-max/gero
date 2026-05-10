#!/usr/bin/env bash
# check-docs.sh — every public declaration in src/ must carry a `///`
# doc comment in the contiguous comment block immediately above it.
#
# Block-scanning rule:
#   - Walk the lines preceding a `pub` declaration.
#   - If the preceding lines form a contiguous comment block (any mix
#     of `//` and `///` lines, no blanks), and at least one line in
#     that block starts with `///`, the declaration is documented.
#   - A blank line or a non-comment line breaks the block — anything
#     before that doesn't count toward the doc requirement.
#
# Allowlist: `// allow-strict: <reason>` anywhere in the same
# preceding comment block silences the rule, for cases where docs are
# pending or the symbol is private-to-the-module by convention.
#
# Whole-tree only.
set -euo pipefail

ROOT="${ROOT:-.}"
violations=0

trim() { echo "$1" | awk '{$1=$1};1'; }

scan_file() {
  local file="$1"
  [[ -f "$file" && "$file" == *.zig ]] || return 0
  # `find` below already restricts to src/, so no further path filter
  # is needed. The check is whole-tree only.

  # Read whole file into an array (bash 3.2 compatible — no mapfile).
  local lines=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    lines+=("$line")
  done <"$file"

  local n=${#lines[@]}
  local i=0
  while [[ $i -lt $n ]]; do
    local line="${lines[i]}"
    local stripped
    stripped=$(trim "$line")

    if [[ "$stripped" =~ ^pub[[:space:]]+(fn|const|var)[[:space:]] ]]; then
      # Walk backwards through the preceding comment block.
      local j=$((i - 1))
      local has_doc=0
      local has_allow=0
      while [[ $j -ge 0 ]]; do
        local prev="${lines[j]}"
        local prev_stripped
        prev_stripped=$(trim "$prev")
        if [[ -z "$prev_stripped" ]]; then break; fi
        if [[ "$prev_stripped" == "///"* ]]; then
          has_doc=1
        elif [[ "$prev_stripped" == "//"* ]]; then
          if [[ "$prev_stripped" == *"allow-strict:"* ]]; then
            has_allow=1
          fi
        else
          break
        fi
        j=$((j - 1))
      done

      if [[ "$has_doc" -eq 0 && "$has_allow" -eq 0 ]]; then
        echo "  $file:$((i + 1)): pub declaration missing /// doc comment: $line"
        violations=$((violations + 1))
      fi
    fi

    i=$((i + 1))
  done
}

while IFS= read -r -d '' file; do
  scan_file "$file"
done < <(find "$ROOT/src" -type f -name "*.zig" -print0 2>/dev/null)

if [[ "$violations" -gt 0 ]]; then
  echo
  echo "❌ $violations public declaration(s) lack a /// doc comment." >&2
  echo "   Add a one-line /// description directly above the declaration," >&2
  echo "   or allowlist with '// allow-strict: <reason>' if the symbol is" >&2
  echo "   not part of the consumer-facing API." >&2
  echo "   See CLAUDE.md \"Doc Comments\"." >&2
  exit 1
fi
