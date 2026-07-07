#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Toki"
VERSION=$(grep '^private let appVersion' Sources/Toki/main.swift | sed 's/.*"\(.*\)"/\1/')

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
lipo -create \
  "$BUILD_DIR/release/Toki" \
  "$BUILD_DIR/x86_64/release/Toki" \
  -output "$APP_DIR/Contents/MacOS/Toki"

echo "==> Copying resources"
cp "$ROOT_DIR/Sources/Toki/Resources/"* "$APP_DIR/Contents/Resources/"

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
  <string>5</string>
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
