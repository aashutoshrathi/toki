#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/.build/Toki.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PLUGINS_DIR="$CONTENTS_DIR/PlugIns"
WIDGET_DIR="$PLUGINS_DIR/TokiWidgets.appex"
WIDGET_CONTENTS_DIR="$WIDGET_DIR/Contents"
WIDGET_MACOS_DIR="$WIDGET_CONTENTS_DIR/MacOS"
WIDGET_RESOURCES_DIR="$WIDGET_CONTENTS_DIR/Resources"

cd "$ROOT_DIR"
VERSION=$(grep '^let appVersion' Sources/Toki/Config/Constants.swift | sed 's/.*"\(.*\)"/\1/')
BUILD_NUMBER="${TOKI_BUILD_NUMBER:-$(date +%s)}"
# Matches package-release.sh so a local build can carry a prerelease identity too. Without it
# the two scripts produce differently shaped bundles, and anything reading this key - the
# updater, the header's prerelease badge - is untestable outside a tagged CI run.
RELEASE_VERSION="${TOKI_RELEASE_VERSION:-$VERSION}"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
mkdir -p "$WIDGET_MACOS_DIR"
mkdir -p "$WIDGET_RESOURCES_DIR"
cp "$ROOT_DIR/.build/release/Toki" "$MACOS_DIR/Toki"
cp "$ROOT_DIR/.build/release/TokiWidgets" "$WIDGET_MACOS_DIR/TokiWidgets"
# Strip symbols before signing (stripping invalidates the signature). The Swift
# release binary carries ~3MB of symbol tables it never needs at runtime.
strip "$MACOS_DIR/Toki"
strip "$WIDGET_MACOS_DIR/TokiWidgets"
cp -R "$ROOT_DIR/Sources/Toki/Resources/"* "$RESOURCES_DIR/"
cp "$ROOT_DIR/Sources/Toki/Resources/"*-logo.svg "$WIDGET_RESOURCES_DIR/"
cp "$ROOT_DIR/Sources/Toki/Resources/"toki-router-glyph-*.svg "$WIDGET_RESOURCES_DIR/"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Toki</string>
  <key>CFBundleIdentifier</key>
  <string>local.toki</string>
  <key>CFBundleIconFile</key>
  <string>toki-logo.icns</string>
  <key>CFBundleName</key>
  <string>Toki</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>TokiReleaseVersion</key>
  <string>$RELEASE_VERSION</string>
  <key>TokiWidgetDataMode</key>
  <string>local</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key>
  <string>Personal use.</string>
</dict>
</plist>
PLIST

cat > "$WIDGET_CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>Toki Widgets</string>
  <key>CFBundleExecutable</key>
  <string>TokiWidgets</string>
  <key>CFBundleIdentifier</key>
  <string>local.toki.widgets</string>
  <key>CFBundleName</key>
  <string>TokiWidgets</string>
  <key>CFBundlePackageType</key>
  <string>XPC!</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>TokiReleaseVersion</key>
  <string>$RELEASE_VERSION</string>
  <key>TokiWidgetDataMode</key>
  <string>local</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.widgetkit-extension</string>
  </dict>
</dict>
</plist>
PLIST

codesign --force --sign - \
  --entitlements "$ROOT_DIR/Config/TokiWidgets.local.entitlements" \
  "$WIDGET_DIR"
codesign --force --sign - "$APP_DIR"

echo "$APP_DIR"
