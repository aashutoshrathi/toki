#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="$HOME/Applications"
SOURCE_APP="$ROOT_DIR/.build/TokenBar.app"
TARGET_APP="$INSTALL_DIR/TokenBar.app"

"$ROOT_DIR/scripts/build-app.sh" >/dev/null

mkdir -p "$INSTALL_DIR"
ditto "$SOURCE_APP" "$TARGET_APP"

echo "$TARGET_APP"
