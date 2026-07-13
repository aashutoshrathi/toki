#!/usr/bin/env bash
# Notarizes and staples a DMG - but only if Apple credentials are present in the
# environment. Safe to call unconditionally from CI: with no credentials configured
# it just logs why it's skipping and exits 0, so the release still ships (ad-hoc
# signed, same as before) until the secrets below are added.
#
# Accepts either notarization credential style:
#   API key (recommended - doesn't expire): APPLE_API_KEY_PATH, APPLE_API_KEY_ID, APPLE_API_ISSUER
#   Apple ID + app-specific password:        APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID
set -euo pipefail

DMG_PATH="${1:?Usage: notarize.sh <path-to-dmg>}"

if [[ -n "${APPLE_API_KEY_PATH:-}" && -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER:-}" ]]; then
  AUTH_ARGS=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER")
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
  AUTH_ARGS=(--apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID")
else
  echo "==> No notarization credentials in the environment - skipping notarization."
  echo "    Set APPLE_API_KEY_PATH/APPLE_API_KEY_ID/APPLE_API_ISSUER (App Store Connect API key)"
  echo "    or APPLE_ID/APPLE_APP_SPECIFIC_PASSWORD/APPLE_TEAM_ID to enable it."
  exit 0
fi

echo "==> Submitting $DMG_PATH for notarization (this can take a few minutes)"
xcrun notarytool submit "$DMG_PATH" "${AUTH_ARGS[@]}" --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$DMG_PATH"

echo "==> Notarization complete"
