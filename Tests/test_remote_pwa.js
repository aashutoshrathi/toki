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

// --- QR scanner: BarcodeDetector fast path, jsQR fallback, token required ---
assert.match(html, /id="scanbtn"/);
assert.match(html, /id="scanner"/);
assert.match(html, /id="scanvideo"[^>]*playsinline/);
assert.match(app, /getUserMedia/);
assert.match(app, /"BarcodeDetector" in window/);
assert.match(app, /window\.jsQR/);
assert.match(app, /function handleScan/);
assert.match(app, /connectWith\(link\.host,link\.token\)/);

// --- Scanned links resolve to host + token, whichever shape Toki's Connect QR uses ---
// Both shapes name the same Mac, so a QR built for one page must still work on the other:
// scanning a direct Tailscale link on the hosted UI used to be rejected as "not for this page".
const scan = vm.createContext({ URL, URLSearchParams });
for (const name of ["isTailscaleHost", "resolveScanLink"]) {
  const source = app.match(new RegExp("^function " + name + "\\([\\s\\S]*?^}", "m"));
  assert.ok(source, name + " must be a top-level function in app.js");
  vm.runInContext(source[0], scan);
}
const resolve = (qr, page) => vm.runInContext("resolveScanLink", scan)(qr, page);
const HOSTED = "https://rc.toki.aashutosh.dev/";
const MAC = "https://my-mac.example-tailnet.ts.net/";

// A direct Tailscale link scanned on the hosted UI: reachable over the tailnet, so adopt its host.
assert.deepEqual(resolve(MAC + "?token=abc", HOSTED), { host: "my-mac.example-tailnet.ts.net", token: "abc" });
// A hosted link scanned on the Mac's own HTTPS UI: the fragment already names the Mac.
assert.deepEqual(resolve(HOSTED + "#host=my-mac.example-tailnet.ts.net&token=abc", MAC),
  { host: "my-mac.example-tailnet.ts.net", token: "abc" });
// Same-origin direct link: no host, so the page keeps talking to its own origin.
assert.deepEqual(resolve(MAC + "?token=abc", MAC), { host: "", token: "abc" });
// A LAN link on the hosted UI genuinely can't work (mixed content), and says which host it means.
assert.match(resolve("http://192.168.1.10:8765/?token=abc", HOSTED).error, /192\.168\.1\.10/);
// A named host that isn't a tailnet name is refused rather than used as an API origin.
assert.match(resolve(HOSTED + "#host=evil.example.com&token=abc", HOSTED).error, /Tailscale name/);
// Anything without a token isn't a connect link at all.
assert.match(resolve("https://example.com/", HOSTED).error, /Remote Control link/);
assert.match(resolve("just some scanned text", HOSTED).error, /Remote Control link/);
assert.match(resolve("https://", HOSTED).error, /Toki link/);
// An empty host must not leave a dangling "host=" in the fragment.
assert.match(app, /const parts=host\?\["host="\+encodeURIComponent\(host\)\]:\[\]/);

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

// --- Installed PWA relaunch restores the last connection instead of the invalid-link screen ---
assert.match(app, /const CONN_KEY="toki-conn"/);
assert.match(app, /function savedConn/);
assert.match(app, /const REVIVE=PARAMS\.get\("token"\)\?null:savedConn\(\)/);
assert.match(app, /localStorage\.setItem\(CONN_KEY/);
assert.match(app, /localStorage\.removeItem\(CONN_KEY\)/);

console.log("remote pwa + qr + ux tests passed");
