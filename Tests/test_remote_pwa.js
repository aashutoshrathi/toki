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
assert.match(app, /connectWith\(link\.host,\s*link\.token\)/);

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
// --- A scanned or typed link is saved before the reload that applies it ---
// Scan and manual entry are only reachable from the invalid-link screen, and that screen clears the
// saved connection, so the fragment connectWith sets is the only copy of the link. A reload does not
// always come back with the fragment (an installed PWA relaunches at start_url), which used to drop
// a freshly scanned link and bounce straight back to the invalid-link screen.
assert.match(app, /\$\("#connectmethods"\)\.hidden\s*=\s*false/);
const connectSource = app.match(/^function connectWith\([\s\S]*?^}/m);
assert.ok(connectSource, "connectWith must be a top-level function in app.js");
const order = [];
const stored = {};
const conn = vm.createContext({
  CONN_KEY: "toki-conn",
  JSON,
  localStorage: { setItem(k, v) { order.push("save"); stored[k] = v; } },
  location: {
    set hash(v) { order.push("hash:" + v); },
    reload() { order.push("reload"); },
  },
});
vm.runInContext(connectSource[0], conn);

vm.runInContext("connectWith('my-mac.example-tailnet.ts.net','abc')", conn);
assert.deepEqual(order, ["save", "hash:host=my-mac.example-tailnet.ts.net&token=abc", "reload"]);
assert.deepEqual(JSON.parse(stored["toki-conn"]), { host: "my-mac.example-tailnet.ts.net", token: "abc" });

// The same-origin case saves an empty host, which restores to this page's own origin, and must not
// leave a dangling "host=" in the fragment.
order.length = 0;
vm.runInContext("connectWith('','abc')", conn);
assert.deepEqual(order, ["save", "hash:token=abc", "reload"]);
assert.deepEqual(JSON.parse(stored["toki-conn"]), { host: "", token: "abc" });

// A storage failure (Safari private mode) must not stop the reload from applying the link.
order.length = 0;
vm.runInContext("localStorage.setItem=()=>{throw new Error('denied')}", conn);
vm.runInContext("connectWith('my-mac.example-tailnet.ts.net','abc')", conn);
assert.deepEqual(order, ["hash:host=my-mac.example-tailnet.ts.net&token=abc", "reload"]);

// --- A wedged connection can always be restarted, from either screen ---
// A link naming a host the phone can no longer reach strands the app on the verify screen. Both
// localStorage and the address bar still hold that link, so reloading only restores it; goHome has
// to drop both and navigate to the bare path rather than reload.
assert.match(html, /id="home"/);
assert.match(html, /id="pairhome"/);
assert.match(css, /#pairhome\{[^}]*position:absolute/);
const homeSource = app.match(/^function goHome\([\s\S]*?^}/m);
assert.ok(homeSource, "goHome must be a top-level function in app.js");
const clearSource = app.match(/^function clearSession\([\s\S]*?^}/m);
assert.ok(clearSource, "clearSession must be a top-level function in app.js");
const steps = [];
const home = vm.createContext({
  CONN_KEY: "toki-conn",
  SESSION_KEY: "toki-session:https://my-mac.example-tailnet.ts.net:abc",
  localStorage: { removeItem(k) { steps.push("local:" + k); } },
  sessionStorage: { removeItem(k) { steps.push("session:" + k); } },
  location: { pathname: "/", replace(url) { steps.push("replace:" + url); } },
});
vm.runInContext(clearSource[0], home);
vm.runInContext(homeSource[0], home);

vm.runInContext("goHome()", home);
assert.deepEqual(steps, [
  "local:toki-conn",
  // The session now lives in localStorage so it survives the tab closing; the sessionStorage
  // removal stays behind it to clear what an older build of this page left there.
  "local:toki-session:https://my-mac.example-tailnet.ts.net:abc",
  "session:toki-session:https://my-mac.example-tailnet.ts.net:abc",
  // The bare path: no query and no fragment, so nothing revives the connection we just left.
  "replace:/",
]);

// A storage failure (Safari private mode) must not strand the user on the screen they're escaping.
steps.length = 0;
vm.runInContext("localStorage.removeItem=()=>{throw new Error('denied')}", home);
vm.runInContext("goHome()", home);
assert.deepEqual(steps.filter(s => s.startsWith("replace:")), ["replace:/"]);

// --- Manual entry for machines without a camera: host + token, same connect flow ---
assert.match(html, /id="manualhost"/);
assert.match(html, /id="manualtoken"/);
assert.match(html, /id="manualconnect"/);
assert.match(html, /id="connectmethods"/);
assert.match(app, /function manualConnect/);
assert.match(app, /remoteAPIBase\(host\)/);
assert.match(app, /connectmethods"\)\.hidden\s*=\s*false/);
assert.match(css, /#manualfields input\{[^}]*16px/);
const jsqr = fs.readFileSync(path.join(root, "jsqr.js"), "utf8");
const sandbox = {}; sandbox.self = sandbox; sandbox.window = sandbox;
vm.createContext(sandbox);
vm.runInContext(jsqr, sandbox);
assert.equal(typeof sandbox.jsQR, "function", "vendored jsqr.js must expose window.jsQR");

// --- Scroll no longer yanks; connection loss is surfaced ---
assert.match(app, /function nearBottom/);
assert.match(app, /if\s*\(added\)\s*\{\s*if\s*\(stick\)\s*scrollToLatest\(\)/);
assert.match(html, /id="tolatest"/);
assert.match(html, /id="conn"/);
assert.match(app, /function setConnected/);
assert.match(css, /\.conn-dot/);

// --- Attention notifications: permission affordance, transition-only firing, SW click handler ---
assert.match(html, /id="enablealerts"/);
assert.match(app, /function notifyAttention/);
assert.match(app, /Notification\.permission\s*!=\s*"granted"/);
assert.match(app, /notifySeeded\s*&&\s*notifiedAttention\[a\.pid\]\s*!=\s*key/);
assert.match(app, /showNotification\(title,\s*opts\)/);
assert.match(app, /requestPermission\(\)/);
assert.match(sw, /addEventListener\("notificationclick"/);

// --- Installed PWA relaunch restores the last connection instead of the invalid-link screen ---
assert.match(app, /const CONN_KEY\s*=\s*"toki-conn"/);
assert.match(app, /function savedConn/);
assert.match(app, /const REVIVE\s*=\s*PARAMS\.get\("token"\)\s*\?\s*null\s*:\s*savedConn\(\)/);
assert.match(app, /localStorage\.setItem\(CONN_KEY/);
assert.match(app, /localStorage\.removeItem\(CONN_KEY\)/);

// --- The session outlives the tab, and no longer than the Mac says it should ---
// sessionStorage dies when the browser closes and when iOS discards a backgrounded tab, which
// ended sessions the Mac still considered live. localStorage keeps them for exactly the lifetime
// /api/pair granted.
const sessionSources = ["loadSession", "saveSession", "clearSession"].map(name => {
  const found = app.match(new RegExp("^function " + name + "\\([\\s\\S]*?^}", "m"));
  assert.ok(found, name + " must be a top-level function in app.js");
  return found[0];
});

function sessionContext(stored, now) {
  const store = { value: stored };
  const context = vm.createContext({
    SESSION_KEY: "k",
    Date: { now: () => now },
    localStorage: {
      getItem: () => store.value,
      setItem: (_, v) => { store.value = v; },
      removeItem: () => { store.value = null; },
    },
    sessionStorage: { removeItem() {} },
  });
  sessionSources.forEach(source => vm.runInContext(source, context));
  return { context, store };
}

// A session stored with a future expiry is restored.
const live = sessionContext(JSON.stringify({ token: "tok", expires: 2000 }), 1000);
assert.equal(vm.runInContext("loadSession()", live.context), "tok");

// Past its expiry it is dropped rather than replayed against a server that would refuse it.
const dead = sessionContext(JSON.stringify({ token: "tok", expires: 500 }), 1000);
assert.equal(vm.runInContext("loadSession()", dead.context), "");
assert.equal(dead.store.value, null, "an expired session must be cleared from storage");

// Sessions written by an older build were bare tokens; upgrading must not sign those devices out.
const legacy = sessionContext("bare-token", 1000);
assert.equal(vm.runInContext("loadSession()", legacy.context), "bare-token");

// saveSession records the lifetime /api/pair reported.
const fresh = sessionContext(null, 1000);
vm.runInContext("saveSession('new-token', 60)", fresh.context);
assert.deepEqual(JSON.parse(fresh.store.value), { token: "new-token", expires: 1000 + 60 * 1000 });

// No lifetime reported: keep the token and let the server be the judge.
vm.runInContext("saveSession('no-expiry', 0)", fresh.context);
assert.deepEqual(JSON.parse(fresh.store.value), { token: "no-expiry" });

// --- A 403 that isn't about the token must not end the session ---
// The host setting refuses networks it was not meant to answer; that is a different Wi-Fi, not a
// dead session, and signing out there would make leaving the house a logout.
assert.match(app, /detail\.includes\("bad token"\)/);

// --- Coming back to a backgrounded tab polls immediately ---
assert.match(app, /addEventListener\("visibilitychange"/);

// --- Tool calls show that they finished, and how long they took ---
// The transcript already carried tool_result entries; the client dropped them, so every call sat
// looking like it was still running.
assert.match(app, /function resolveToolNode/);
assert.match(app, /toolNodes\[entry\.id\]/);
assert.match(app, /classList\.add\(entry\.failed \? "failed" : "ok"\)/);
assert.match(css, /\.tool\.running \.tool-state/);
assert.match(css, /\.tool\.failed \.tool-state/);

const durationSource = app.match(/^function shortDuration\([\s\S]*?^}/m);
assert.ok(durationSource, "shortDuration must be a top-level function in app.js");
const duration = vm.createContext({ Math });
vm.runInContext(durationSource[0], duration);
const took = ms => vm.runInContext("shortDuration", duration)(ms);
assert.equal(took(2400), "2s");
assert.equal(took(65000), "1m 5s");
// A call that returned instantly says nothing rather than "0s", and a missing timestamp on either
// end must not render "NaN".
assert.equal(took(200), "");
assert.equal(took(NaN), "");
assert.equal(took(-5), "");

// --- Usage strip: same reading as the menu bar, one line until asked ---
assert.match(html, /id="usagetoggle"/);
assert.match(html, /id="usage"/);
assert.match(app, /setInterval\(pollUsage/);
assert.match(css, /#usagetoggle/);

const usageSources = ["usageClass", "renderUsage"].map(name => {
  const found = app.match(new RegExp("^function " + name + "\\([\\s\\S]*?^}", "m"));
  assert.ok(found, name + " must be a top-level function in app.js");
  return found[0];
});

// Colour follows how close the account is to running out, not the provider.
const usage = vm.createContext({ Math });
vm.runInContext(usageSources[0], usage);
const band = r => vm.runInContext("usageClass", usage)(r);
assert.equal(band(0.8), "");
assert.equal(band(0.3), "warn");
// 20% is where Toki itself calls an account low and notifies, so the bar agrees with the alert.
assert.equal(band(0.2), "low");
assert.equal(band(0.05), "low");

// The summary names the account with least left, since that is the one about to bite, and an
// account with no quota API shows its figure rather than a bar drawn from a number nobody has.
const nodes = {};
const el = () => ({ hidden: true, textContent: "", innerHTML: "", attrs: {},
  setAttribute(k, v) { this.attrs[k] = v; } });
["#usagetoggle", "#usage", "#usagesummary"].forEach(id => { nodes[id] = el(); });
const render = vm.createContext({
  Math,
  $: id => nodes[id],
  dispTitle: t => t,
  esc: t => t,
  usageOpen: true,
});
vm.runInContext(usageSources[0], render);
vm.runInContext(usageSources[1], render);
vm.runInContext(`renderUsage({accounts:[
  {id:"a",name:"Claude Code",remaining:0.62},
  {id:"b",name:"Codex",remaining:0.11},
  {id:"c",name:"Grok",primary:"no quota API"}
],stale:true})`, render);
assert.match(nodes["#usagesummary"].textContent, /^Codex 11% left/);
assert.match(nodes["#usagesummary"].textContent, /3 accounts/);
assert.match(nodes["#usage"].innerHTML, /width:62%/);
assert.match(nodes["#usage"].innerHTML, /u-fill low/);
assert.match(nodes["#usage"].innerHTML, /no quota API/);
// A reading the Mac stopped refreshing says so rather than looking current.
assert.match(nodes["#usage"].innerHTML, /out of date/);

// Nothing to show means no strip at all, rather than an empty panel.
vm.runInContext("renderUsage({accounts:[]})", render);
assert.equal(nodes["#usagetoggle"].hidden, true);

console.log("remote pwa + qr + ux tests passed");
