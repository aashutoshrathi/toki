"use strict";

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const root = path.join(__dirname, "..", "Sources", "Toki", "Resources", "webui");
const read = name => fs.readFileSync(path.join(root, name), "utf8");
const html = read("index.html");
const app = read("app.js");
const css = read("styles.css");
const sw = read("sw.js");

// --- Installable PWA: manifest + icons + iOS home-screen metadata ---
const manifest = JSON.parse(read("manifest.webmanifest"));
assert.equal(manifest.display, "standalone");
assert.ok(manifest.icons.some(i => i.sizes === "512x512" && i.purpose.includes("maskable")));
assert.ok(manifest.icons.some(i => i.sizes === "192x192"));
for (const icon of ["icon-192.png", "icon-512.png", "apple-touch-icon.png"]) {
  assert.ok(fs.existsSync(path.join(root, icon)), icon + " missing");
}
assert.match(html, /rel="manifest" href="manifest\.webmanifest"/);
assert.match(html, /rel="apple-touch-icon" href="apple-touch-icon\.png"/);
assert.match(html, /name="theme-color"/);
assert.match(html, /name="apple-mobile-web-app-capable" content="yes"/);
assert.match(html, /name="apple-mobile-web-app-status-bar-style"/);

// --- Standalone display must not tuck the header under the notch ---
assert.match(css, /header\{[^}]*env\(safe-area-inset-top\)/);

// --- Service worker: versioned, skips the auth'd API, has a fetch handler ---
assert.match(sw, /addEventListener\("fetch"/);
assert.match(sw, /toki-rc-v\d+/);
assert.match(sw, /pathname\.startsWith\("\/api\/"\)\)\s*return/);
assert.match(app, /serviceWorker.*register\("sw\.js"\)/s);

// --- QR scanner: BarcodeDetector fast path, jsQR fallback, same-origin+token guard ---
assert.match(html, /id="scanbtn"/);
assert.match(html, /id="scanner"/);
assert.match(html, /id="scanvideo"[^>]*playsinline/);
assert.match(app, /getUserMedia/);
assert.match(app, /"BarcodeDetector" in window/);
assert.match(app, /window\.jsQR/);
assert.match(app, /target\.origin!=location\.origin/);

// --- Manual entry for machines without a camera: host + token, same connect flow ---
assert.match(html, /id="manualhost"/);
assert.match(html, /id="manualtoken"/);
assert.match(html, /id="manualconnect"/);
assert.match(html, /id="connectmethods"/);
assert.match(app, /function manualConnect/);
assert.match(app, /remoteAPIBase\(host\)/);
assert.match(app, /connectmethods"\)\.hidden=false/);
assert.match(css, /#manualfields input\{[^}]*16px/);
const jsqr = fs.readFileSync(path.join(root, "jsqr.js"), "utf8");
const sandbox = {}; sandbox.self = sandbox; sandbox.window = sandbox;
vm.createContext(sandbox);
vm.runInContext(jsqr, sandbox);
assert.equal(typeof sandbox.jsQR, "function", "vendored jsqr.js must expose window.jsQR");

// --- Scroll no longer yanks; connection loss is surfaced ---
assert.match(app, /function nearBottom/);
assert.match(app, /if\(added\)\{if\(stick\)scrollToLatest\(\)/);
assert.match(html, /id="tolatest"/);
assert.match(html, /id="conn"/);
assert.match(app, /function setConnected/);
assert.match(css, /\.conn-dot/);

// --- Attention notifications: permission affordance, transition-only firing, SW click handler ---
assert.match(html, /id="enablealerts"/);
assert.match(app, /function notifyAttention/);
assert.match(app, /Notification\.permission!="granted"/);
assert.match(app, /notifySeeded&&notifiedAttention\[a\.pid\]!=key/);
assert.match(app, /showNotification\(title,opts\)/);
assert.match(app, /requestPermission\(\)/);
assert.match(sw, /addEventListener\("notificationclick"/);

console.log("remote pwa + qr + ux tests passed");
