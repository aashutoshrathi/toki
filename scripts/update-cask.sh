#!/usr/bin/env bash
# Regenerates a Toki cask file with a version and the sha256 of the published release DMG.
# Run after a release DMG is available on GitHub. Pass the cask path as the first argument
# to update a tap checkout directly (default: the in-repo template).
#
# The second argument is the cask version. It defaults to appVersion from Constants.swift,
# which is all a stable release needs. A prerelease tag (v2.5.0-beta.1) must pass it
# explicitly, because the tag exists only in git - and the DMG filename carries the base
# version (Toki_2.5.0_universal.dmg), so the URL combines the full tag with the base name.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CASK="${1:-$ROOT_DIR/homebrew/toki.rb}"
VERSION="${2:-$(grep '^let appVersion' "$ROOT_DIR/Sources/Toki/Config/Constants.swift" | sed 's/.*"\(.*\)"/\1/')}"
APP_VERSION="${VERSION%%-*}"
DMG_URL="https://github.com/aashutoshrathi/toki/releases/download/v${VERSION}/Toki_${APP_VERSION}_universal.dmg"

echo "==> Fetching $DMG_URL"
TMP_DMG="$(mktemp -t toki-dmg).dmg"
trap 'rm -f "$TMP_DMG"' EXIT
curl -fsSL "$DMG_URL" -o "$TMP_DMG"

SHA=$(shasum -a 256 "$TMP_DMG" | awk '{print $1}')
echo "==> version=$VERSION sha256=$SHA"

/usr/bin/sed -i '' \
  -e "s/^  version \".*\"/  version \"${VERSION}\"/" \
  -e "s/^  sha256 \".*\"/  sha256 \"${SHA}\"/" \
  "$CASK"

echo "==> Updated $CASK"
