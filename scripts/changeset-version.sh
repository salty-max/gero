#!/usr/bin/env bash
# changeset-version.sh — consume every pending changeset, bump
# build.zig.zon's version, prepend a section to CHANGELOG.md, and delete
# the consumed changeset files.
#
# Usage:
#   bash scripts/changeset-version.sh
#
# Idempotent: running twice with no pending changesets is a no-op.
set -euo pipefail

cd "$(dirname "$0")/.."

# Clean up any temp files we might leave on interrupt.
cleanup() { rm -f build.zig.zon.tmp CHANGELOG.md.tmp; }
trap cleanup EXIT INT TERM

# Collect pending changesets (everything in .changeset/*.md except README.md).
changesets=()
if [[ -d .changeset ]]; then
  while IFS= read -r f; do
    [[ "$f" == ".changeset/README.md" ]] && continue
    changesets+=("$f")
  done < <(find .changeset -maxdepth 1 -type f -name '*.md' | sort)
fi

if [[ ${#changesets[@]} -eq 0 ]]; then
  echo "No pending changesets — nothing to do."
  exit 0
fi

# Aggregate: highest bump level + bullet list of summaries.
highest_bump="patch"
bullets=""

bump_rank() {
  case "$1" in
    major) echo 3 ;;
    minor) echo 2 ;;
    patch) echo 1 ;;
    *) echo 0 ;;
  esac
}

for cs in "${changesets[@]}"; do
  bump=$(awk '
    BEGIN { n = 0 }
    /^---$/ { n++; next }
    n == 1 && /^bump:/ { sub(/^bump:[[:space:]]*/, ""); print; exit }
  ' "$cs")
  if [[ -z "$bump" ]]; then
    echo "Missing or malformed 'bump' in $cs" >&2
    exit 1
  fi
  case "$bump" in
    major | minor | patch) ;;
    *) echo "Invalid 'bump: $bump' in $cs (expected patch/minor/major)" >&2; exit 1 ;;
  esac

  cur_rank=$(bump_rank "$highest_bump")
  cs_rank=$(bump_rank "$bump")
  if [[ "$cs_rank" -gt "$cur_rank" ]]; then
    highest_bump="$bump"
  fi

  # First non-empty line of the body.
  summary=$(awk '
    BEGIN { n = 0; in_body = 0 }
    /^---$/ { n++; if (n == 2) { in_body = 1 }; next }
    in_body && NF > 0 { print; exit }
  ' "$cs")
  if [[ -z "$summary" ]]; then
    echo "Missing summary in $cs" >&2
    exit 1
  fi

  bullets+="- $summary"$'\n'
done

# Read current version from build.zig.zon. Constrain to N.N.N so we fail
# loudly on prerelease/build-metadata suffixes the bump logic doesn't handle.
# `|| true` so an empty grep (no match) doesn't trip pipefail before our error.
current=$({ grep -E '\.version[[:space:]]*=[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' build.zig.zon || true; } \
  | head -1 \
  | sed -E 's/.*"([^"]+)".*/\1/')
if [[ -z "$current" ]]; then
  echo "Could not parse a 3-part semver from build.zig.zon's .version field." >&2
  echo "Pre-release / build-metadata suffixes are not supported." >&2
  exit 1
fi

IFS='.' read -r major minor patch <<<"$current"
case "$highest_bump" in
  major) new_version="$((major + 1)).0.0" ;;
  minor) new_version="$major.$((minor + 1)).0" ;;
  patch) new_version="$major.$minor.$((patch + 1))" ;;
esac

# Update build.zig.zon (portable in-place edit via temp file).
sed -E "s/(\.version[[:space:]]*=[[:space:]]*\")$current(\")/\1$new_version\2/" build.zig.zon >build.zig.zon.tmp
mv build.zig.zon.tmp build.zig.zon

# Prepend a new section to CHANGELOG.md, preserving the existing header + body.
# UTC date so two maintainers in different timezones cutting the same tag
# get the same CHANGELOG entry.
date_iso=$(date -u +%Y-%m-%d)
new_section="## v$new_version - $date_iso

$bullets"

if [[ -f CHANGELOG.md ]]; then
  # Split: keep H1 + tagline at the top, insert section, then the rest.
  header=$(awk '
    /^## / { exit }
    { print }
  ' CHANGELOG.md)
  rest=$(awk '
    in_rest { print }
    /^## / { in_rest = 1; print }
  ' CHANGELOG.md)
else
  header="# Changelog
"
  rest=""
fi

{
  printf '%s\n\n' "$header"
  printf '%s' "$new_section"
  if [[ -n "$rest" ]]; then
    printf '\n%s\n' "$rest"
  fi
} >CHANGELOG.md.tmp
mv CHANGELOG.md.tmp CHANGELOG.md

# Delete consumed changesets.
for cs in "${changesets[@]}"; do
  rm "$cs"
done

echo "Bumped $current → $new_version (level: $highest_bump)"
echo "Consumed ${#changesets[@]} changeset(s)"
echo "Edit build.zig.zon and CHANGELOG.md before committing if needed."
