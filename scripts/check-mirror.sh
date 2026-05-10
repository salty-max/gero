#!/usr/bin/env bash
# check-mirror.sh — enforce src ↔ tests mirror layout.
#
# Rule: every src/<module>/<path>.zig must have a matching
# tests/<module>/<path>.test.zig, and vice versa.
#
# Exempt from the src→test direction:
#   - src/gero.zig                (public barrel)
#   - src/<module>.zig            (top-level module barrel files)
#   - src/<module>/internal.zig   (private helpers, covered by sibling files)
#
# Whole-tree only — a missing mirror is by nature a whole-tree property.
set -e

ROOT="${ROOT:-.}"
violations=0

is_exempt() {
  local file="$1"
  case "$file" in
    src/gero.zig|./src/gero.zig) return 0 ;;
    src/*/internal.zig|./src/*/internal.zig) return 0 ;;
  esac
  # Top-level module barrels: src/<name>.zig (no slash after src/<name>)
  if [[ "$file" =~ ^(\./)?src/[^/]+\.zig$ ]]; then
    return 0
  fi
  return 1
}

# Direction 1: every src/**/*.zig (except exempt) has tests/**/*.test.zig
while IFS= read -r -d '' src_file; do
  rel="${src_file#$ROOT/}"
  rel="${rel#./}"
  if is_exempt "$rel"; then continue; fi
  test_file="${rel/#src\//tests/}"
  test_file="${test_file%.zig}.test.zig"
  if [[ ! -f "$ROOT/$test_file" ]]; then
    echo "  src has no test mirror: $rel → expected $test_file"
    violations=$((violations + 1))
  fi
done < <(find "$ROOT/src" -type f -name "*.zig" -print0 2>/dev/null)

# Direction 2: every tests/**/*.test.zig has a src/**/*.zig
while IFS= read -r -d '' test_file; do
  rel="${test_file#$ROOT/}"
  rel="${rel#./}"
  case "$rel" in
    tests/util.zig|tests/util.test.zig) continue ;;
  esac
  src_file="${rel/#tests\//src/}"
  src_file="${src_file%.test.zig}.zig"
  if [[ ! -f "$ROOT/$src_file" ]]; then
    echo "  test has no src mirror (orphan): $rel → expected $src_file"
    violations=$((violations + 1))
  fi
done < <(find "$ROOT/tests" -type f -name "*.test.zig" -print0 2>/dev/null)

if [[ "$violations" -gt 0 ]]; then
  echo
  echo "❌ $violations mirror violation(s) found." >&2
  echo "   Convention: src/<module>/<path>.zig ↔ tests/<module>/<path>.test.zig" >&2
  echo "   See CLAUDE.md \"Source Layout\"." >&2
  exit 1
fi
