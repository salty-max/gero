#!/usr/bin/env bash
# changeset-version.sh — consume every pending changeset, bump
# build.zig.zon's version, prepend a CHANGELOG.md section grouped by
# bump level, and delete the consumed changeset files.
#
# Usage:
#   bash scripts/changeset-version.sh
#
# CHANGELOG section shape:
#
#   ## vMAJOR.MINOR.PATCH - YYYY-MM-DD
#
#   ### Breaking      <- only if at least one `bump: major`
#   - <first paragraph of changeset body, joined into one line>
#
#   ### Added         <- only if at least one `bump: minor`
#   - <...>
#
#   ### Fixed         <- only if at least one `bump: patch`
#   - <...>
#
# Each bullet is the changeset body's first paragraph (everything
# between the closing `---` and the first blank line), with hard line
# breaks collapsed into single spaces. Anything past the first
# paragraph is dropped — keep extra detail in PR descriptions, not in
# the CHANGELOG.
#
# Idempotent: running twice with no pending changesets is a no-op.

set -euo pipefail

cd "$(dirname "$0")/.."

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

# Bullets grouped by bump level; highest bump drives the version step.
highest_bump="patch"
major_bullets=""
minor_bullets=""
patch_bullets=""

bump_rank() {
  case "$1" in
    major) echo 3 ;;
    minor) echo 2 ;;
    patch) echo 1 ;;
    *) echo 0 ;;
  esac
}

# Pull the changeset body's first paragraph and join newlines into spaces.
extract_summary() {
  awk '
    BEGIN { n = 0; in_body = 0; paragraph = ""; done = 0 }
    /^---$/ { n++; if (n == 2) in_body = 1; next }
    done { next }
    in_body && NF == 0 {
      if (paragraph != "") { print paragraph; done = 1 }
      next
    }
    in_body {
      if (paragraph == "") paragraph = $0
      else paragraph = paragraph " " $0
    }
    END { if (!done && paragraph != "") print paragraph }
  ' "$1"
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

  summary=$(extract_summary "$cs")
  if [[ -z "$summary" ]]; then
    echo "Missing summary in $cs" >&2
    exit 1
  fi

  case "$bump" in
    major) major_bullets+="- $summary"$'\n' ;;
    minor) minor_bullets+="- $summary"$'\n' ;;
    patch) patch_bullets+="- $summary"$'\n' ;;
  esac
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

# Compose the per-bump subsections in priority order (Breaking → Added → Fixed).
section_body=""
add_subsection() {
  local label="$1"
  local bullets="$2"
  [[ -z "$bullets" ]] && return
  section_body+="### $label"$'\n\n'
  section_body+="$bullets"
  section_body+=$'\n'
}
add_subsection "Breaking" "$major_bullets"
add_subsection "Added" "$minor_bullets"
add_subsection "Fixed" "$patch_bullets"
# Trim the trailing blank line so the next H2 sits flush.
section_body="${section_body%$'\n'}"

# Prepend a new section to CHANGELOG.md, preserving the existing header + body.
# UTC date so two maintainers in different timezones cutting the same tag
# get the same CHANGELOG entry.
date_iso=$(date -u +%Y-%m-%d)
new_section="## v$new_version - $date_iso

$section_body"

if [[ -f CHANGELOG.md ]]; then
  # Split: keep H1 + tagline at the top, insert section, then the rest.
  header=$(awk '
    /^## / { exit }
    { print }
  ' CHANGELOG.md)
  rest=$(awk '
    /^## / { in_rest = 1 }
    in_rest { print }
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
  else
    printf '\n'
  fi
} >CHANGELOG.md.tmp
mv CHANGELOG.md.tmp CHANGELOG.md

# Delete consumed changesets.
for cs in "${changesets[@]}"; do
  rm "$cs"
done

echo "Bumped $current → $new_version (level: $highest_bump)"
echo "Consumed ${#changesets[@]} changeset(s)"
echo "CHANGELOG.md grouped by bump level — edit the narrative before committing if needed."
