#!/usr/bin/env bash
# Renders docs/og.png, the 1200x630 link preview image for toki.aashutosh.dev.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
RES="file://$ROOT_DIR/Sources/Toki/Resources"
FONT="-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"
WORK_DIR="$(mktemp -d)"
PAGE="$WORK_DIR/og.html"
trap 'rm -rf "$WORK_DIR"' EXIT

logo() {
  printf '<div style="width:60px;height:60px;border-radius:14px;background:#24262b;display:flex;align-items:center;justify-content:center"><img src="%s/%s-logo.svg" width="36" height="36"></div>' "$RES" "$1"
}

LOGOS=""
for provider in claude codex cursor opencode gemini zed; do
  LOGOS+="$(logo "$provider")"
done

cat > "$PAGE" <<HTML
<html><body style="margin:0;width:1200px;height:630px;overflow:hidden;background:#f4f1ea;font-family:$FONT">
<div style="box-sizing:border-box;width:100%;height:100%;padding:44px 0 0 80px;display:flex;gap:56px">
  <div style="flex:1;display:flex;flex-direction:column">
    <div style="display:flex;align-items:center;gap:28px">
      <img src="$RES/toki-logo.svg" width="104" height="104" style="border-radius:24px;box-shadow:0 0 0 2px #24262b">
      <div style="color:#24262b;font-size:84px;font-weight:800;letter-spacing:-0.03em">Toki</div>
    </div>
    <div style="color:#24262b;font-size:42px;font-weight:700;line-height:1.15;margin-top:28px">One menu bar app for every AI coding agent you run.</div>
    <div style="color:#5b5e66;font-size:26px;line-height:1.35;margin-top:18px">Usage, spend, and live sessions. Answer a waiting agent from your phone.</div>
    <div style="display:flex;gap:12px;margin-top:26px">$LOGOS</div>
    <div style="display:flex;align-items:center;gap:20px;margin-top:auto;margin-bottom:100px">
      <div style="padding:14px 28px;border-radius:999px;background:#24262b;color:#f4f1ea;font-size:26px;font-weight:600">Free for macOS</div>
      <code style="color:#24262b;font-size:24px;font-family:ui-monospace, Menlo, monospace">brew install --cask toki</code>
    </div>
  </div>
  <div style="width:400px;padding-top:6px">
    <img src="https://files.aashutosh.dev/toki-preview.png" width="400" style="display:block;border-radius:24px 0 0 0;box-shadow:0 20px 60px rgba(36,38,43,0.35)">
  </div>
</div>
</body></html>
HTML

"$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --window-size=1200,630 --virtual-time-budget=5000 \
  --screenshot="$ROOT_DIR/docs/og.png" "file://$PAGE" 2>/dev/null
