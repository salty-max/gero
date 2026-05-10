#!/usr/bin/env bash
# check-naming.sh — Zig naming-convention lint for public functions.
#
# Convention:
#   pub fn Foo(...) type   → PascalCase (function returns a type)
#   pub fn foo(...) <other>  → camelCase (function returns a value)
#
# Heuristic: only single-line `pub fn ... {` signatures are checked.
# Multi-line signatures (where the closing brace is on a later line)
# are skipped to avoid false positives. An AST-based upgrade would
# close that gap.
#
# Allowlist: `// allow-strict: <reason>` directly above the
# declaration silences the rule.
#
# Whole-tree only.
set -euo pipefail

ROOT="${ROOT:-.}"
violations=0

trim() { echo "$1" | awk '{$1=$1};1'; }

is_allowed() {
  local prev="$1"
  case "$prev" in
    *"allow-strict:"*) return 0 ;;
  esac
  return 1
}

scan_file() {
  local file="$1"
  [[ -f "$file" && "$file" == *.zig ]] || return 0

  local prev=""
  local lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    local stripped
    stripped=$(trim "$line")

    # Match `pub fn <name>(...` and only proceed when the line is a
    # complete signature (ends with `{`). Multi-line signatures are
    # skipped — heuristic limitation, documented above.
    if [[ "$stripped" =~ ^pub[[:space:]]+fn[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)\( ]] \
        && [[ "$stripped" == *"{" ]]; then
      local name="${BASH_REMATCH[1]}"
      local first="${name:0:1}"

      # Detect `) type {` (with optional whitespace) on the same line.
      local is_type_returning=0
      if [[ "$line" =~ \)[[:space:]]+type[[:space:]]*\{ ]]; then
        is_type_returning=1
      fi

      if [[ "$is_type_returning" -eq 1 ]]; then
        if [[ "$first" =~ [a-z] ]]; then
          if ! is_allowed "$prev"; then
            echo "  $file:$lineno: type-returning fn '$name' should be PascalCase: $line"
            violations=$((violations + 1))
          fi
        fi
      else
        if [[ "$first" =~ [A-Z] ]]; then
          if ! is_allowed "$prev"; then
            echo "  $file:$lineno: fn '$name' should be camelCase (PascalCase reserved for type-returning fns): $line"
            violations=$((violations + 1))
          fi
        fi
      fi
    fi

    prev="$line"
  done <"$file"
}

while IFS= read -r -d '' file; do
  scan_file "$file"
done < <(find "$ROOT/src" -type f -name "*.zig" -print0 2>/dev/null)

if [[ "$violations" -gt 0 ]]; then
  echo
  echo "❌ $violations naming-convention violation(s)." >&2
  echo "   Convention: pub fn returning 'type' is PascalCase; everything" >&2
  echo "   else is camelCase. Allowlist with '// allow-strict: <reason>'." >&2
  echo "   See Zig style guide / CLAUDE.md \"Naming\"." >&2
  exit 1
fi
