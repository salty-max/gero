#!/usr/bin/env bash
# changeset-new.sh — interactively scaffold a new changeset under .changeset/.
#
# Usage:
#   bash scripts/changeset-new.sh
#
# Output:
#   .changeset/<random-hex>.md
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p .changeset

echo "Bump level for this changeset:"
echo "  patch — bug fixes, small tweaks (no API change)"
echo "  minor — new feature (backward-compatible)"
echo "  major — breaking change"
printf "> "
read -r bump

case "$bump" in
  patch | minor | major) ;;
  *)
    echo "Invalid bump '$bump' — expected patch, minor, or major." >&2
    exit 1
    ;;
esac

echo
echo "Summary (one line, becomes the CHANGELOG bullet):"
printf "> "
IFS= read -r summary

if [[ -z "$summary" ]]; then
  echo "Summary cannot be empty." >&2
  exit 1
fi

# Random 8-char hex name. Prefer openssl, fall back to /dev/urandom + xxd, then od.
gen_name() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 4
  elif command -v xxd >/dev/null 2>&1; then
    head -c 4 /dev/urandom | xxd -p
  else
    od -An -N4 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

# Loop in case of (vanishingly rare) collision.
for _ in 1 2 3; do
  name=$(gen_name)
  if [[ -z "$name" ]]; then
    echo "Failed to generate a random changeset name." >&2
    exit 1
  fi
  file=".changeset/${name}.md"
  [[ -e "$file" ]] || break
done
if [[ -e "$file" ]]; then
  echo "Could not find an unused changeset name after 3 attempts." >&2
  exit 1
fi

cat >"$file" <<EOF
---
bump: $bump
---

$summary
EOF

echo
echo "Wrote $file"
echo "Don't forget: git add $file"
