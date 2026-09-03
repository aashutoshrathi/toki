#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Toki"
VERSION=$(grep '^let appVersion' Sources/Toki/Config/Constants.swift | sed 's/.*"\(.*\)"/\1/')
# The full release identity, including any prerelease suffix (e.g. 2.5.1-beta.3). CFBundleShort-
# VersionString must stay dotted-numeric, so the updater compares against this instead, letting a
# beta see the next beta and the eventual stable. Falls back to the marketing version locally.
RELEASE_VERSION="${TOKI_RELEASE_VERSION:-$VERSION}"
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
# -Osize rather than the default -O. It takes about 12% off the binary, which is 700KB off the
# installed app - but only 70KB off the DMG, because UDZO already compresses away most of what
# it removes. So this is for the space Toki occupies on disk, not for the download. Toki spends
# its time waiting on timers, subprocesses and the network, so the speed traded away for it is
# not what is scarce here.
swift build -c release -Xswiftc -Osize

echo "==> Building x86_64 binary"
rm -rf "$BUILD_DIR/x86_64"
# SwiftPM must plan the whole build for Intel. Passing -target through -Xswiftc leaves the
# Xcode build plan on the host architecture, producing arm64 objects for an x86_64 link.
swift build -c release -Xswiftc -Osize \
  --triple x86_64-apple-macosx14.0 \
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
# -R recurses into subdirectories such as webui/; -L follows the CHANGELOG.md
# symlink so the bundle gets a real file the in-app What's New can read.
cp -RL "$ROOT_DIR/Sources/Toki/Resources/"* "$APP_DIR/Contents/Resources/"
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
  <key>TokiReleaseVersion</key>
  <string>$RELEASE_VERSION</string>
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
  <key>TokiReleaseVersion</key>
  <string>$RELEASE_VERSION</string>
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
# No -fs: it used to pin HFS+, and on GitHub's macos-26 image that produces a file hdiutil
# cannot read back at all - imageinfo rejects the header, not just the checksum. Apple has been
# withdrawing HFS+ write support, so the filesystem is left to hdiutil, which picks one the
# running OS can actually create. Toki requires macOS 14, well past the 10.13 that APFS images
# need, so whichever it chooses is mountable by every supported install.
hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGING_DIR" \
  -ov -format UDZO \
  "$DMG_PATH"

rm -rf "$STAGING_DIR"

# A DMG that hdiutil cannot attach is worthless to the updater, which mounts it to swap the
# app in. Failing here keeps a bad image from being uploaded to a release, where the only
# symptom is "hdiutil: attach failed - corrupt image" on every machine that tries to update.
#
# This checks attachability rather than the checksum. `hdiutil verify` reads the internal
# CRC, and on GitHub's macos-26 runner it rejects images hdiutil itself has just written
# ("unable to recognize as a disk image"), while passing locally on 26.6.2 for a byte-identical
# invocation. Attaching is both the stricter test and the one that matches what the updater
# does, so a pass here means more than a checksum ever did.
echo "==> Verifying DMG"
hdiutil imageinfo "$DMG_PATH" > /dev/null
ATTACH_DEV=$(hdiutil attach -nomount -readonly "$DMG_PATH" | grep -o '^/dev/[^[:space:]]*' | head -1)
if [[ -z "$ATTACH_DEV" ]]; then
  echo "    hdiutil attach produced no device for $DMG_PATH" >&2
  exit 1
fi
hdiutil detach "$ATTACH_DEV" -quiet
echo "    attached and detached cleanly as $ATTACH_DEV"

echo ""
echo "==> Done: $DMG_PATH"
