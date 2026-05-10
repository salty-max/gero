#!/usr/bin/env bash
# check-unused.sh — flag public exports in src/ that no one references.
#
# For every `pub fn|const|var <name>` declared in src/, check whether
# `<name>` appears (word-bounded) anywhere else in src/, tests/, or
# test.zig. Zero references → unused.
#
# Allowlist with `// allow-unused: <reason>` on the line directly above
# the offending declaration. Reviewer-gated, rare.
#
# Whole-tree only — no per-file mode (a "missing reference" is by nature
# a whole-tree property).
set -e

ROOT="${ROOT:-.}"
SRC_DIR="$ROOT/src"
SEARCH_PATHS=("$ROOT/src" "$ROOT/tests" "$ROOT/test.zig")

if [[ ! -d "$SRC_DIR" ]]; then
  echo "check-unused.sh: $SRC_DIR not found" >&2
  exit 2
fi

violations=0

# Read every pub declaration. Output: <file>:<line>:<name>
extract_pub() {
  # Match "pub fn NAME", "pub const NAME", "pub var NAME".
  # Capture file:line, then sed to keep just the identifier.
  grep -RnE '^[[:space:]]*pub (fn|const|var) [a-zA-Z_][a-zA-Z0-9_]*' "$SRC_DIR" \
    | sed -E 's/^([^:]+):([0-9]+):.*pub (fn|const|var) ([a-zA-Z_][a-zA-Z0-9_]*).*/\1:\2:\4/'
}

# Returns 0 (true) if the line directly above $file:$lineno is an allowlist.
is_allowlisted() {
  local file="$1" lineno="$2"
  local prev_line=$((lineno - 1))
  [[ "$prev_line" -lt 1 ]] && return 1
  local prev
  prev=$(sed -n "${prev_line}p" "$file")
  case "$prev" in
    *"allow-unused:"*) return 0 ;;
  esac
  return 1
}

# Count references to $name across SEARCH_PATHS. Returns total count.
count_refs() {
  local name="$1" def_file="$2" def_line="$3"
  local total=0
  for p in "${SEARCH_PATHS[@]}"; do
    [[ -e "$p" ]] || continue
    if [[ -d "$p" ]]; then
      while IFS= read -r match; do
        # match is "file:line:content"
        local mf ml
        mf=$(echo "$match" | cut -d: -f1)
        ml=$(echo "$match" | cut -d: -f2)
        # Skip the defining line itself.
        if [[ "$mf" == "$def_file" && "$ml" == "$def_line" ]]; then
          continue
        fi
        total=$((total + 1))
      done < <(grep -RnwE "$name" "$p" 2>/dev/null || true)
    else
      while IFS= read -r match; do
        local mf ml
        mf=$(echo "$match" | cut -d: -f1)
        ml=$(echo "$match" | cut -d: -f2)
        if [[ "$mf" == "$def_file" && "$ml" == "$def_line" ]]; then
          continue
        fi
        total=$((total + 1))
      done < <(grep -nwE "$name" "$p" 2>/dev/null || true)
    fi
  done
  echo "$total"
}

while IFS=: read -r file lineno name; do
  [[ -z "$name" ]] && continue
  if is_allowlisted "$file" "$lineno"; then
    continue
  fi
  refs=$(count_refs "$name" "$file" "$lineno")
  if [[ "$refs" -eq 0 ]]; then
    echo "  $file:$lineno: $name"
    violations=$((violations + 1))
  fi
done < <(extract_pub)

if [[ "$violations" -gt 0 ]]; then
  echo
  echo "❌ $violations unused public export(s) found." >&2
  echo "   Either reference them, delete them, or add '// allow-unused: <reason>' above." >&2
  echo "   See CLAUDE.md \"Self-Review / Step 3 — explicit acceptance checks\"." >&2
  exit 1
fi
