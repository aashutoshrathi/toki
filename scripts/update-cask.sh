#!/usr/bin/env bash
# Regenerates homebrew/toki.rb with the current version and the sha256 of the
# published release DMG. Run after a release DMG is available on GitHub, then copy
# homebrew/toki.rb into the tap repo (aashutoshrathi/homebrew-tap) as Casks/toki.rb.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION=$(grep '^let appVersion' Sources/Toki/Config/Constants.swift | sed 's/.*"\(.*\)"/\1/')
DMG_URL="https://github.com/aashutoshrathi/toki/releases/download/v${VERSION}/Toki_${VERSION}_universal.dmg"
CASK="homebrew/toki.rb"

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
