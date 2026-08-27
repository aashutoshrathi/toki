#!/usr/bin/env bash
# Prints CHANGELOG.md's section for a release tag, for `gh release create --notes-file`.
# Exits 1 when the changelog has no section for that version, which is the normal case for a
# prerelease tag - the caller falls back to --generate-notes there.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHANGELOG="$ROOT_DIR/CHANGELOG.md"

TAG="${1:-}"
if [[ -z "$TAG" ]]; then
  echo "usage: release-notes.sh <tag>" >&2
  exit 2
fi

VERSION="${TAG#v}"

NOTES=$(
  awk -v ver="$VERSION" '
    index($0, "## " ver) == 1 && substr($0, length("## " ver) + 1, 1) ~ /^( |$)/ { found = 1; print; next }
    found && /^## / { exit }
    found { print }
  ' "$CHANGELOG"
)

# Trim the blank lines that bracket a section, so the release body starts at the first heading.
NOTES=$(printf '%s\n' "$NOTES" | sed -e '/./,$!d' | awk 'BEGIN{blank=0} /^$/{blank++; next} {while(blank>0){print ""; blank--}; print}')

if [[ -z "$NOTES" ]]; then
  echo "No CHANGELOG.md section for $VERSION" >&2
  exit 1
fi

printf '%s\n' "$NOTES"
