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

echo "==> Building arm64 binary"
rm -rf "$BUILD_DIR/arm64"
# -Osize rather than the default -O. It takes about 12% off the binary, which is 700KB off the
# installed app - but only 70KB off the DMG, because UDZO already compresses away most of what
# it removes. So this is for the space Toki occupies on disk, not for the download. Toki spends
# its time waiting on timers, subprocesses and the network, so the speed traded away for it is
# not what is scarce here.
ARM64_BUILD_ARGS=(
  -c release
  -Xswiftc -Osize
  --triple arm64-apple-macosx14.0
  --build-path "$BUILD_DIR/arm64"
)
swift build "${ARM64_BUILD_ARGS[@]}"
ARM64_BIN_DIR="$(swift build "${ARM64_BUILD_ARGS[@]}" --show-bin-path)"

echo "==> Building x86_64 binary"
rm -rf "$BUILD_DIR/x86_64"
# SwiftPM must plan the whole build for Intel. Passing -target through -Xswiftc leaves the
# Xcode build plan on the host architecture, producing arm64 objects for an x86_64 link.
X86_64_BUILD_ARGS=(
  -c release
  -Xswiftc -Osize
  --triple x86_64-apple-macosx14.0
  --build-path "$BUILD_DIR/x86_64"
)
swift build "${X86_64_BUILD_ARGS[@]}"
X86_64_BIN_DIR="$(swift build "${X86_64_BUILD_ARGS[@]}" --show-bin-path)"

assert_archs() {
  local binary="$1"
  local expected="$2"
  local actual
  actual="$(lipo -archs "$binary" | tr ' ' '\n' | awk 'NF' | sort | tr '\n' ' ' | sed 's/ $//')"
  if [[ "$actual" != "$expected" ]]; then
    echo "    expected archs '$expected' in $binary, got '$actual'" >&2
    exit 1
  fi
}

CURRENT_MOUNT_POINT=""
cleanup_mount() {
  if [[ -n "$CURRENT_MOUNT_POINT" ]]; then
    hdiutil detach "$CURRENT_MOUNT_POINT" -quiet 2>/dev/null || true
    CURRENT_MOUNT_POINT=""
  fi
}
trap cleanup_mount EXIT

package_variant() {
  local variant="$1"
  local app_dir="$BUILD_DIR/bundle-${variant}/${APP_NAME}.app"
  local widget_dir="$app_dir/Contents/PlugIns/TokiWidgets.appex"
  local staging_dir="$BUILD_DIR/dmg-staging-${variant}"
  local dmg_name
  local expected_archs

  case "$variant" in
    arm64)
      dmg_name="${APP_NAME}_${VERSION}_arm64.dmg"
      expected_archs="arm64"
      ;;
    x86_64)
      dmg_name="${APP_NAME}_${VERSION}_x86_64.dmg"
      expected_archs="x86_64"
      ;;
    universal)
      # Permanent naming rule: the universal DMG uses "_all" so the shared prefix "Toki_<v>_"
      # is identical and the first differing characters are pure lowercase letters ("al" < "ar" < "x").
      # That guarantees Toki_<v>_all.dmg sorts before _arm64.dmg and _x86_64.dmg under every
      # collation (ASCII and Unicode/UCA alike). Shipped builds <= 3.4.5 pick the first ".dmg"
      # asset blindly, so keeping the universal DMG first guarantees legacy Intel and Apple Silicon
      # updaters receive a runnable universal bundle instead of an arm64-only one.
      dmg_name="${APP_NAME}_${VERSION}_all.dmg"
      expected_archs="arm64 x86_64"
      ;;
    *)
      echo "Unknown package variant: $variant" >&2
      exit 1
      ;;
  esac

  echo ""
  echo "==> Packaging $variant ($dmg_name)"
  rm -rf "$app_dir"
  mkdir -p "$app_dir/Contents/MacOS"
  mkdir -p "$app_dir/Contents/Resources"
  mkdir -p "$widget_dir/Contents/MacOS"
  mkdir -p "$widget_dir/Contents/Resources"

  if [[ "$variant" == "universal" ]]; then
    lipo -create \
      "$ARM64_BIN_DIR/Toki" \
      "$X86_64_BIN_DIR/Toki" \
      -output "$app_dir/Contents/MacOS/Toki"
    lipo -create \
      "$ARM64_BIN_DIR/TokiWidgets" \
      "$X86_64_BIN_DIR/TokiWidgets" \
      -output "$widget_dir/Contents/MacOS/TokiWidgets"
  elif [[ "$variant" == "arm64" ]]; then
    cp "$ARM64_BIN_DIR/Toki" "$app_dir/Contents/MacOS/Toki"
    cp "$ARM64_BIN_DIR/TokiWidgets" "$widget_dir/Contents/MacOS/TokiWidgets"
  else
    cp "$X86_64_BIN_DIR/Toki" "$app_dir/Contents/MacOS/Toki"
    cp "$X86_64_BIN_DIR/TokiWidgets" "$widget_dir/Contents/MacOS/TokiWidgets"
  fi

  assert_archs "$app_dir/Contents/MacOS/Toki" "$expected_archs"
  assert_archs "$widget_dir/Contents/MacOS/TokiWidgets" "$expected_archs"

  # Strip symbols before signing (stripping invalidates the signature). Each slice carries
  # ~3MB of symbol tables unused at runtime.
  strip "$app_dir/Contents/MacOS/Toki"
  strip "$widget_dir/Contents/MacOS/TokiWidgets"

  # -R recurses into subdirectories such as webui/; -L follows the CHANGELOG.md
  # symlink so the bundle gets a real file the in-app What's New can read.
  cp -RL "$ROOT_DIR/Sources/Toki/Resources/"* "$app_dir/Contents/Resources/"
  cp "$ROOT_DIR/Sources/Toki/Resources/"*-logo.svg "$widget_dir/Contents/Resources/"
  cp "$ROOT_DIR/Sources/Toki/Resources/"toki-router-glyph-*.svg "$widget_dir/Contents/Resources/"

  cat > "$app_dir/Contents/Info.plist" <<PLIST
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

  cat > "$widget_dir/Contents/Info.plist" <<PLIST
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

  echo "    Signing app bundle"
  if [[ -n "${APPLE_SIGNING_IDENTITY:-}" ]]; then
    echo "    Using Developer ID identity: $APPLE_SIGNING_IDENTITY"
    # Hardened runtime + a secure timestamp are required for notarization to accept the
    # binary; ad-hoc signing (the fallback below) can't be notarized at all.
    codesign --force --options runtime --timestamp \
      --entitlements "$ROOT_DIR/Config/TokiWidgets.entitlements" \
      --sign "$APPLE_SIGNING_IDENTITY" \
      "$widget_dir"
    codesign --force --options runtime --timestamp \
      --entitlements "$ROOT_DIR/Config/Toki.entitlements" \
      --sign "$APPLE_SIGNING_IDENTITY" \
      "$app_dir"
  else
    echo "    No APPLE_SIGNING_IDENTITY set - falling back to ad-hoc signing (not notarizable)."
    codesign --force --sign - \
      --entitlements "$ROOT_DIR/Config/TokiWidgets.local.entitlements" \
      "$widget_dir"
    codesign --force --sign - "$app_dir"
  fi

  local dmg_path="$BUILD_DIR/$dmg_name"
  rm -rf "$staging_dir"
  mkdir -p "$staging_dir"
  cp -R "$app_dir" "$staging_dir/"
  ln -s /Applications "$staging_dir/Applications"

  rm -f "$dmg_path"
  # No -fs: it used to pin HFS+, and on GitHub's macos-26 image that produces a file hdiutil
  # cannot read back at all - imageinfo rejects the header, not just the checksum. Apple has been
  # withdrawing HFS+ write support, so the filesystem is left to hdiutil, which picks one the
  # running OS can actually create. Toki requires macOS 14, well past the 10.13 that APFS images
  # need, so whichever it chooses is mountable by every supported install.
  hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$staging_dir" \
    -ov -format UDZO \
    "$dmg_path"

  rm -rf "$staging_dir"

  if [[ -n "${APPLE_SIGNING_IDENTITY:-}" ]]; then
    codesign --force --timestamp --sign "$APPLE_SIGNING_IDENTITY" "$dmg_path"
  fi

  # A DMG that hdiutil cannot mount is worthless to the updater, which mounts it to swap the
  # app in. Failing here keeps a bad image from being uploaded to a release, where the only
  # symptom is "hdiutil: attach failed - corrupt image" on every machine that tries to update.
  #
  # This mounts read-only and verifies the mounted bundle rather than calling `hdiutil verify`.
  # `hdiutil verify` reads the internal CRC, and on GitHub's macos-26 runner it rejects images
  # hdiutil itself has just written ("unable to recognize as a disk image"), while passing locally
  # for a byte-identical invocation. Mounting and verifying the app matches what the updater does.
  echo "    Verifying DMG"
  hdiutil imageinfo "$dmg_path" > /dev/null
  local mount_point
  mount_point="$(
    hdiutil attach -nobrowse -readonly -plist "$dmg_path" \
      | python3 -c '
import plistlib, sys
plist = plistlib.loads(sys.stdin.buffer.read())
for entity in plist.get("system-entities", []):
    mp = entity.get("mount-point")
    if mp:
        print(mp)
        break
'
  )"
  if [[ -z "$mount_point" ]]; then
    echo "    hdiutil attach produced no mount point for $dmg_path" >&2
    exit 1
  fi
  CURRENT_MOUNT_POINT="$mount_point"
  codesign --verify --deep --strict "$mount_point/${APP_NAME}.app"
  assert_archs "$mount_point/${APP_NAME}.app/Contents/MacOS/Toki" "$expected_archs"
  assert_archs "$mount_point/${APP_NAME}.app/Contents/PlugIns/TokiWidgets.appex/Contents/MacOS/TokiWidgets" "$expected_archs"
  cleanup_mount
  echo "    mounted, verified ($expected_archs), and detached cleanly: $dmg_path"
}

package_variant arm64
package_variant x86_64
package_variant universal

echo ""
echo "==> Done:"
echo "    $BUILD_DIR/${APP_NAME}_${VERSION}_all.dmg (universal)"
echo "    $BUILD_DIR/${APP_NAME}_${VERSION}_arm64.dmg (arm64)"
echo "    $BUILD_DIR/${APP_NAME}_${VERSION}_x86_64.dmg (x86_64)"
