#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Toki"
VERSION=$(grep '^let appVersion' Sources/Toki/Config/Constants.swift | sed 's/.*"\(.*\)"/\1/')
BUILD_NUMBER="${TOKI_BUILD_NUMBER:-10}"
if [[ -n "${APPLE_SIGNING_IDENTITY:-}" ]]; then
  WIDGET_DATA_MODE="app-group"
else
  WIDGET_DATA_MODE="local"
fi

BUILD_DIR="$ROOT_DIR/.build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

echo "==> Building arm64 binary"
rm -rf "$BUILD_DIR/release"
swift build -c release

echo "==> Building x86_64 binary"
rm -rf "$BUILD_DIR/release-x86_64"
swift build -c release \
  -Xswiftc -target -Xswiftc x86_64-apple-macosx14.0 \
  --build-path "$BUILD_DIR/x86_64"

echo "==> Creating universal binary"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/PlugIns/TokiWidgets.appex/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/PlugIns/TokiWidgets.appex/Contents/Resources"
lipo -create \
  "$BUILD_DIR/release/Toki" \
  "$BUILD_DIR/x86_64/release/Toki" \
  -output "$APP_DIR/Contents/MacOS/Toki"
lipo -create \
  "$BUILD_DIR/release/TokiWidgets" \
  "$BUILD_DIR/x86_64/release/TokiWidgets" \
  -output "$APP_DIR/Contents/PlugIns/TokiWidgets.appex/Contents/MacOS/TokiWidgets"

# Strip symbols from the universal binary before signing (stripping invalidates
# the signature). Each slice carries ~3MB of symbol tables unused at runtime.
strip "$APP_DIR/Contents/MacOS/Toki"
strip "$APP_DIR/Contents/PlugIns/TokiWidgets.appex/Contents/MacOS/TokiWidgets"

echo "==> Copying resources"
cp "$ROOT_DIR/Sources/Toki/Resources/"* "$APP_DIR/Contents/Resources/"
cp "$ROOT_DIR/Sources/Toki/Resources/"*-logo.svg \
  "$APP_DIR/Contents/PlugIns/TokiWidgets.appex/Contents/Resources/"
cp "$ROOT_DIR/Sources/Toki/Resources/"toki-router-glyph-*.svg \
  "$APP_DIR/Contents/PlugIns/TokiWidgets.appex/Contents/Resources/"

echo "==> Generating Info.plist"
INFO_PLIST="$APP_DIR/Contents/Info.plist"
cat > "$INFO_PLIST" <<PLIST
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
  <key>TokiWidgetDataMode</key>
  <string>$WIDGET_DATA_MODE</string>
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

WIDGET_DIR="$APP_DIR/Contents/PlugIns/TokiWidgets.appex"
cat > "$WIDGET_DIR/Contents/Info.plist" <<PLIST
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
  <key>TokiWidgetDataMode</key>
  <string>$WIDGET_DATA_MODE</string>
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

echo "==> Signing app bundle"
if [[ -n "${APPLE_SIGNING_IDENTITY:-}" ]]; then
  echo "    Using Developer ID identity: $APPLE_SIGNING_IDENTITY"
  # Hardened runtime + a secure timestamp are required for notarization to accept the
  # binary; ad-hoc signing (the fallback below) can't be notarized at all.
  codesign --force --options runtime --timestamp \
    --entitlements "$ROOT_DIR/Config/TokiWidgets.entitlements" \
    --sign "$APPLE_SIGNING_IDENTITY" \
    "$WIDGET_DIR"
  codesign --force --options runtime --timestamp \
    --entitlements "$ROOT_DIR/Config/Toki.entitlements" \
    --sign "$APPLE_SIGNING_IDENTITY" \
    "$APP_DIR"
else
  echo "    No APPLE_SIGNING_IDENTITY set - falling back to ad-hoc signing (not notarizable)."
  codesign --force --sign - \
    --entitlements "$ROOT_DIR/Config/TokiWidgets.local.entitlements" \
    "$WIDGET_DIR"
  codesign --force --sign - "$APP_DIR"
fi

echo "==> Creating DMG"
DMG_NAME="${APP_NAME}_${VERSION}_universal.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
STAGING_DIR="$BUILD_DIR/dmg-staging"

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_DIR" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGING_DIR" \
  -ov -format UDZO \
  -fs HFS+ \
  "$DMG_PATH"

rm -rf "$STAGING_DIR"
echo ""
echo "==> Done: $DMG_PATH"
