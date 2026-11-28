#!/usr/bin/env bash
# Regenerates a Toki cask file with a version and the sha256 values of the published arm64
# and x86_64 release DMGs. Run after the release DMGs are available on GitHub (post-staple).
# Pass the cask path as the first argument to update a tap checkout directly (default: the
# in-repo template).
#
# The second argument is the cask version. It defaults to appVersion from Constants.swift,
# which is all a stable release needs. A prerelease tag (v2.5.0-beta.1) must pass it
# explicitly, because the tag exists only in git - and the DMG filenames carry the base
# version (Toki_2.5.0_arm64.dmg / Toki_2.5.0_x86_64.dmg), so the URL combines the full tag
# with the base name.
#
# Set TOKI_DMG_DIR to hash local DMGs instead of downloading from GitHub (useful for local
# verification against freshly packaged builds).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CASK="${1:-$ROOT_DIR/homebrew/toki.rb}"
VERSION="${2:-$(grep '^let appVersion' "$ROOT_DIR/Sources/Toki/Config/Constants.swift" | sed 's/.*"\(.*\)"/\1/')}"
APP_VERSION="${VERSION%%-*}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

hash_dmg() {
  local arch="$1"
  local filename="Toki_${APP_VERSION}_${arch}.dmg"
  local target_file

  if [[ -n "${TOKI_DMG_DIR:-}" ]]; then
    target_file="${TOKI_DMG_DIR}/${filename}"
    echo "==> Hashing local $target_file" >&2
    if [[ ! -f "$target_file" ]]; then
      echo "Missing local DMG: $target_file" >&2
      exit 1
    fi
  else
    local url="https://github.com/aashutoshrathi/toki/releases/download/v${VERSION}/${filename}"
    target_file="$TMP_DIR/$filename"
    echo "==> Fetching $url" >&2
    curl -fsSL "$url" -o "$target_file"
  fi

  local sha
  sha="$(shasum -a 256 "$target_file" | awk '{print $1}')"
  if [[ ! "$sha" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Invalid sha256 computed for $filename: $sha" >&2
    exit 1
  fi
  printf '%s\n' "$sha"
}

SHA_ARM64="$(hash_dmg arm64)"
SHA_X86_64="$(hash_dmg x86_64)"
echo "==> version=$VERSION arm64=$SHA_ARM64 x86_64=$SHA_X86_64"

/usr/bin/sed -i '' \
  -e "s/^  version \".*\"$/  version \"${VERSION}\"/" \
  -e "s/^  sha256 arm: \".*\", intel: \".*\"$/  sha256 arm: \"${SHA_ARM64}\", intel: \"${SHA_X86_64}\"/" \
  "$CASK"

EXPECTED_VERSION_LINE="  version \"${VERSION}\""
EXPECTED_SHA_LINE="  sha256 arm: \"${SHA_ARM64}\", intel: \"${SHA_X86_64}\""
if ! grep -Fxq "$EXPECTED_VERSION_LINE" "$CASK"; then
  echo "Failed to stamp expected version line in $CASK" >&2
  exit 1
fi
if ! grep -Fxq "$EXPECTED_SHA_LINE" "$CASK"; then
  echo "Failed to stamp expected sha256 line in $CASK" >&2
  exit 1
fi
if grep -q "PLACEHOLDER_" "$CASK"; then
  echo "Unreplaced placeholder remains in $CASK" >&2
  exit 1
fi

echo "==> Updated $CASK"
