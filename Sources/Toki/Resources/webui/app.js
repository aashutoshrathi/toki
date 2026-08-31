// Fragments keep tokens out of static-host logs; query params support older links.
const PARAMS = new URLSearchParams(location.hash.slice(1) || location.search);

// Installed PWAs relaunch at start_url without the fragment, so restore the last connection.
const CONN_KEY = "toki-conn";

function savedConn() {
  try {
    return JSON.parse(localStorage.getItem(CONN_KEY) || "null");
  } catch (e) {
    return null;
  }
}

const REVIVE = PARAMS.get("token") ? null : savedConn();
const LINK_TOKEN = PARAMS.get("token") || (REVIVE && REVIVE.token) || "";
const REMOTE_HOST = PARAMS.get("host") || (REVIVE && REVIVE.host) || "";

let API_BASE = "";
let CONFIG_ERROR = "";
try {
  API_BASE = REMOTE_HOST ? remoteAPIBase(REMOTE_HOST) : "";
} catch (e) {
  CONFIG_ERROR = e.message;
}

// An empty host is meaningful: it restores a direct same-origin connection.
let connSaved = false;
if (LINK_TOKEN && !CONFIG_ERROR) {
  try {
    localStorage.setItem(CONN_KEY, JSON.stringify({ host: REMOTE_HOST, token: LINK_TOKEN }));
    connSaved = true;
  } catch (e) {}
}

// Remove a token from the visible/synced URL only after localStorage preserves the sole copy.
if (connSaved && (location.hash || location.search)) {
  try {
    history.replaceState(null, "", location.pathname);
  } catch (e) {}
}

function isTailscaleHost(host) {
  return /^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.ts\.net$/i.test(host);
}

function remoteAPIBase(host) {
  if (!isTailscaleHost(host))
    throw new Error("Invalid Tailscale host");
  return "https://" + host;
}

const $ = s => document.querySelector(s);

function feedback(kind = "tap") {
  if (!navigator.vibrate) return;
  const pattern = kind == "success" ? [10, 24, 10] : kind == "error" ? [24, 35, 24] : 7;
  navigator.vibrate(pattern);
}

const SESSION_KEY = "toki-session:" + API_BASE + ":" + LINK_TOKEN;

// localStorage survives iOS discarding a backgrounded tab; server revocation still wins.
function loadSession() {
  let raw = null;
  try {
    raw = localStorage.getItem(SESSION_KEY);
  } catch (e) {}
  if (!raw) {
    // Migrate pre-2.7 sessions without deleting the legacy copy unless persistence succeeds.
    let legacy = null;
    try {
      legacy = sessionStorage.getItem(SESSION_KEY);
    } catch (e) {}
    if (legacy) {
      try {
        localStorage.setItem(SESSION_KEY, legacy);
        sessionStorage.removeItem(SESSION_KEY);
      } catch (e) {}
      raw = legacy;
    }
  }
  if (!raw) return "";
  let saved;
  try {
    saved = JSON.parse(raw);
  } catch (e) {
    return raw;
  }
  if (!saved || !saved.token) return "";
  if (saved.expires && Date.now() >= saved.expires) {
    clearSession();
    return "";
  }
  return saved.token;
}

function saveSession(token, expiresInSeconds) {
  const record = { token };
  if (expiresInSeconds > 0) record.expires = Date.now() + expiresInSeconds * 1000;
  try {
    localStorage.setItem(SESSION_KEY, JSON.stringify(record));
  } catch (e) {}
}

function clearSession() {
  try {
    localStorage.removeItem(SESSION_KEY);
  } catch (e) {}
  // Pre-2.7 builds used sessionStorage.
  try {
    sessionStorage.removeItem(SESSION_KEY);
  } catch (e) {}
}

let TOKEN = loadSession();

let current = null;
let offset = 0;
let agents = [];
let privacyMode = false;

function maskText(t) {
  return "•".repeat(Math.min(Math.max((t || "").length, 4), 14));
}

function dispTitle(t) {
  return privacyMode ? maskText(t) : esc(t);
}

function plainTitle(t) {
  return privacyMode ? maskText(t) : (t || "");
}

function dispPath(p) {
  if (!p) return "";
  return privacyMode ? maskText(p) : esc(p);
}

function dispLinked(t) {
  return privacyMode ? maskText(t) : linkify(t);
}

// Headers keep session tokens out of history and proxy logs. Hosted UI and Mac versions can drift,
// so servers before 2.6.0 still get their query-token fallback after a safe GET probe.
let tokenTransport = null;

function tokenedRequest(p, o, inQuery) {
  const url = API_BASE + p +
    (inQuery ? (p.includes("?") ? "&" : "?") + "token=" + encodeURIComponent(TOKEN) : "");
  const opts = Object.assign({}, o);
  if (!inQuery) {
    opts.headers = Object.assign({}, o && o.headers, { Authorization: "Bearer " + TOKEN });
  }
  return fetch(url, opts);
}

// Probe with GET: old servers either return 403 same-origin or fail the header preflight cross-origin.
async function resolveTokenTransport() {
  if (tokenTransport) return tokenTransport;
  try {
    const probe = await tokenedRequest("/api/agents", undefined, false);
    if (probe.status != 403) {
      tokenTransport = "header";
      return tokenTransport;
    }
  } catch (blocked) {}
  try {
    const probe = await tokenedRequest("/api/agents", undefined, true);
    if (probe.ok) {
      tokenTransport = "query";
      return tokenTransport;
    }
  } catch (unreachable) {}
  // Do not latch query mode on ambiguous failure; that would keep exposing tokens in URLs.
  return "header";
}

// Concurrent startup polls share one compatibility probe.
let transportProbe = null;

function tokenTransportOnce() {
  if (tokenTransport) return Promise.resolve(tokenTransport);
  if (!transportProbe) {
    transportProbe = resolveTokenTransport().finally(() => {
      transportProbe = null;
    });
  }
  return transportProbe;
}

async function api(p, o) {
  // Never retry terminal mutations: a lost response may arrive after the keystroke was delivered.
  const transport = await tokenTransportOnce();
  const r = await tokenedRequest(p, o, transport === "query");
  if (!r.ok) {
    const detail = await r.text();
    // A generic 403 may be a transient network-policy mismatch; only bad-token ends the session.
    if (r.status == 403 && detail.includes("bad token")) lockApp();
    throw new Error(detail);
  }
  return r.json();
}

function lockApp() {
  TOKEN = "";
  clearSession();
  setDocTitle(null);
  document.body.classList.add("locked");
  $("#paircontrols").hidden = false;
  $("#connectmethods").hidden = true;
  $("#pairtitle").textContent = "Verify this device";
  $("#pairinstructions").textContent = "Enter the six-digit code shown by Toki on your Mac.";
  $("#paircode").focus();
}

function invalidLink(message) {
  TOKEN = "";
  clearSession();
  setDocTitle(null);
  try {
    localStorage.removeItem(CONN_KEY);
  } catch (e) {}
  document.body.classList.add("locked");
  $("#pairtitle").textContent = "Open a new link from Toki";
  $("#pairinstructions").textContent = message;
  $("#paircontrols").hidden = true;
  $("#connectmethods").hidden = false;
  $("#pairstatus").textContent = "";
}

let started = false;
let failCount = 0;

function setConnected(ok) {
  if (ok) {
    failCount = 0;
    $("#conn").hidden = true;
    return;
  }
  if (document.body.classList.contains("locked")) return;
  if (++failCount >= 2) $("#conn").hidden = false;
}

let usageOpen = false;
let lastUsage = null;

// Match Toki's default 20% low-quota alert threshold.
function usageClass(remaining) {
  if (remaining <= 0.2) return "low";
  if (remaining <= 0.35) return "warn";
  return "";
}

function renderUsage(data) {
  lastUsage = data;
  const toggle = $("#usagetoggle");
  const panel = $("#usage");
  const accounts = (data && data.accounts) || [];
  if (!accounts.length) {
    toggle.hidden = true;
    panel.hidden = true;
    return;
  }
  toggle.hidden = false;
  const withRatio = accounts.filter(a => typeof a.remaining == "number");
  const lowest = withRatio.length
    ? withRatio.reduce((a, b) => (a.remaining <= b.remaining ? a : b))
    : accounts[0];
  const lowestValue = typeof lowest.remaining == "number"
    ? Math.round(lowest.remaining * 100) + "% left"
    : (lowest.value || lowest.primary || "");
  const summary = accounts.length > 1
    ? plainTitle(lowest.name) + " " + lowestValue + " · " + accounts.length + " accounts"
    : plainTitle(lowest.name) + " " + lowestValue;
  const stale = !!(data && data.stale);
  $("#usagesummary").textContent = stale ? summary + " · may be out of date" : summary;
  toggle.classList.toggle("stale", stale);
  toggle.setAttribute("aria-expanded", usageOpen ? "true" : "false");
  panel.hidden = !usageOpen;
  if (!usageOpen) return;

  panel.innerHTML = accounts.map(a => {
    const name = '<span class="u-name">' + dispTitle(a.name) + "</span>";
    if (typeof a.remaining != "number") {
      return '<div class="u-row' + (a.error ? " err" : "") + '">' + name +
        '<span class="u-track"></span><span class="u-value">' +
        esc(a.value || a.primary || "") + "</span></div>";
    }
    const pct = Math.max(0, Math.min(100, Math.round(a.remaining * 100)));
    return '<div class="u-row' + (a.error ? " err" : "") + '">' + name +
      '<span class="u-track"><span class="u-fill ' + usageClass(a.remaining) +
      '" style="width:' + pct + '%"></span></span>' +
      '<span class="u-value">' + pct + "%</span></div>";
  }).join("") + (data.stale
    ? '<div class="u-stale">Toki stopped sending updates, so this may be out of date.</div>'
    : "");
}

async function refreshUsage() {
  renderUsage(await api("/api/usage"));
}

function pollUsage() {
  if (TOKEN) refreshUsage().then(() => setConnected(true), () => {});
}

function pollAgents() {
  if (TOKEN) refreshAgents().then(() => setConnected(true), () => setConnected(false));
}

function pollLog() {
  if (TOKEN) refreshLog().then(() => setConnected(true), () => setConnected(false));
}

function startApp() {
  document.body.classList.remove("locked");
  updateAlertsButton();
  if (started) return;
  started = true;
  pollAgents();
  pollLog();
  pollUsage();
  setInterval(pollAgents, 4000);
  setInterval(pollLog, 2500);
  setInterval(pollUsage, 20000);
}

$("#usagetoggle").addEventListener("click", () => {
  usageOpen = !usageOpen;
  feedback();
  refreshUsage();
});

// Backgrounded tabs throttle timers; refresh immediately on return.
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState != "visible" || !started || !TOKEN) return;
  pollAgents();
  pollLog();
  pollUsage();
});

$("#pairform").addEventListener("submit", async e => {
  e.preventDefault();
  const code = $("#paircode").value.replace(/\s/g, "");
  if (!/^\d{6}$/.test(code)) {
    $("#pairstatus").textContent = "Enter all six digits.";
    return;
  }
  $("#pairstatus").textContent = "verifying\u2026";
  try {
    const r = await fetch(API_BASE + "/api/pair?token=" + encodeURIComponent(LINK_TOKEN), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code }),
    });
    const body = await r.json();
    if (!r.ok) {
      if (body.error == "bad link token") {
        invalidLink("This Remote Control link is invalid or expired. Open Connect in Toki and use its latest link.");
        return;
      }
      if (body.error == "incorrect verification code")
        throw new Error("That code is incorrect or has rotated. Check the current code in Toki and try again.");
      throw new Error(body.error || "verification failed");
    }
    TOKEN = body.token;
    saveSession(TOKEN, body.expiresIn);
    $("#pairstatus").textContent = "";
    startApp();
  } catch (err) {
    feedback("error");
    $("#pairstatus").textContent = err.message;
  }
});

function esc(s) {
  const d = document.createElement("div");
  d.textContent = s;
  return d.innerHTML;
}

const md = renderMarkdown;
// Non-Markdown text reaches innerHTML only through this escaping linkifier.
const linkify = renderMarkdown.linkify;

const LOGOS = {
  claude: '<svg class="plogo" viewBox="0 0 100 100" fill="#d97757"><path d="m19.6 66.5 19.7-11 .3-1-.3-.5h-1l-3.3-.2-11.2-.3L14 53l-9.5-.5-2.4-.5L0 49l.2-1.5 2-1.3 2.9.2 6.3.5 9.5.6 6.9.4L38 49.1h1.6l.2-.7-.5-.4-.4-.4L29 41l-10.6-7-5.6-4.1-3-2-1.5-2-.6-4.2 2.7-3 3.7.3.9.2 3.7 2.9 8 6.1L37 36l1.5 1.2.6-.4.1-.3-.7-1.1L33 25l-6-10.4-2.7-4.3-.7-2.6c-.3-1-.4-2-.4-3l3-4.2L28 0l4.2.6L33.8 2l2.6 6 4.1 9.3L47 29.9l2 3.8 1 3.4.3 1h.7v-.5l.5-7.2 1-8.7 1-11.2.3-3.2 1.6-3.8 3-2L61 2.6l2 2.9-.3 1.8-1.1 7.7L59 27.1l-1.5 8.2h.9l1-1.1 4.1-5.4 6.9-8.6 3-3.5L77 13l2.3-1.8h4.3l3.1 4.7-1.4 4.9-4.4 5.6-3.7 4.7-5.3 7.1-3.2 5.7.3.4h.7l12-2.6 6.4-1.1 7.6-1.3 3.5 1.6.4 1.6-1.4 3.4-8.2 2-9.6 2-14.3 3.3-.2.1.2.3 6.4.6 2.8.2h6.8l12.6 1 3.3 2 1.9 2.7-.3 2-5.1 2.6-6.8-1.6-16-3.8-5.4-1.3h-.8v.4l4.6 4.5 8.3 7.5L89 80.1l.5 2.4-1.3 2-1.4-.2-9.2-7-3.6-3-8-6.8h-.5v.7l1.8 2.7 9.8 14.7.5 4.5-.7 1.4-2.6 1-2.7-.6-5.8-8-6-9-4.7-8.2-.5.4-2.9 30.2-1.3 1.5-3 1.2-2.5-2-1.4-3 1.4-6.2 1.6-8 1.3-6.4 1.2-7.9.7-2.6v-.2H49L43 72l-9 12.3-7.2 7.6-1.7.7-3-1.5.3-2.8L24 86l10-12.8 6-7.9 4-4.6-.1-.5h-.3L17.2 77.4l-4.7.6-2-2 .2-3 1-1 8-5.5Z"/></svg>',
  codex: '<svg class="plogo" viewBox="0 0 250 250" fill="#7a9dff"><path d="m84.3 5.1q3.7-1.5 7.7-2.6 3.9-1 7.9-1.6 4-0.5 8.1-0.6 4 0 8 0.5 20.7 2.4 37.1 17.7 0.1 0.1 0.4 0.3 0.1 0 0.2 0 0 0 0.2 0 0 0 0.1 0 0 0 0.1 0 5.2-1.4 10.7-1.9 5.4-0.4 10.7 0.1 5.5 0.4 10.7 1.9 5.2 1.3 10.1 3.6l0.6 0.4 1.6 0.8q5.2 2.5 9.7 6.1 4.7 3.4 8.6 7.7 3.8 4.3 6.9 9.2 3 4.8 5.2 10.2 4.3 10.5 4.3 22.1 0.2 2.1 0 4.2-0.1 2.2-0.2 4.3-0.3 2.1-0.7 4.3-0.4 2.1-0.9 4.1 0 0.2 0 0.4 0 0.2 0 0.5 0 0.1 0.1 0.4 0.1 0.1 0.3 0.3 12.3 12.6 16.3 30 6 29.7-12.2 53.5l-1.9 2.2q-3 3.5-6.5 6.4-3.4 3.1-7.3 5.5-3.8 2.4-8.1 4.2-4.1 1.9-8.5 3.2-0.3 0-0.4 0.2-0.3 0-0.4 0.1-0.1 0.1-0.3 0.4 0 0.1-0.1 0.3c-2.7 7.7-5.3 14.2-10.2 20.7-12.5 16.5-30.8 25.5-51.5 25.5q-24.6-0.1-43.6-18.1-0.2-0.1-0.4-0.2-0.2-0.1-0.4-0.1-0.2 0-0.3 0-0.3 0-0.4 0c-5.4 1.7-10.9 1.9-16.7 1.9q-3.5 0-7-0.5-3.4-0.4-6.9-1.2-3.3-0.8-6.6-2-3.3-1.2-6.4-2.8-3.3-1.6-6.4-3.6-3-2-5.8-4.3-3-2.3-5.5-5-2.5-2.6-4.6-5.6c-2.2-2.7-4.3-5.4-5.8-8.5q-0.8-1.6-1.6-3.2-0.6-1.7-1.3-3.3-0.7-1.7-1.2-3.4-0.5-1.6-1-3.4-1.1-4-1.6-7.9-0.6-4-0.6-8 0-4 0.6-8 0.4-4 1.4-8 0 0 0-0.1 0-0.1 0-0.1 0.2-0.2 0.2-0.3 0-0.1-0.2-0.1 0-0.2 0-0.3 0-0.1-0.1-0.1 0-0.2 0-0.2-0.1-0.1-0.1-0.1-2.4-2.5-4.6-5.2-2.1-2.7-4-5.4-1.7-3-3.2-6-1.5-3.1-2.6-6.3-0.8-2-1.3-4.1-0.7-2-1.1-4-0.4-2.1-0.7-4.2-0.2-2.2-0.4-4.3-0.2-2.8-0.1-5.6 0-2.8 0.3-5.4 0.1-2.8 0.6-5.6 0.4-2.8 1.1-5.5 7-23.1 26.9-36.3 4.3-2.9 8.2-4.5 4.5-1.9 9-3.2 0.2 0 0.3-0.1 0.1-0.2 0.3-0.3 0.1 0 0.1-0.3 0.1-0.1 0.1-0.2 1-3.1 2.2-6 1-2.9 2.5-5.7 1.5-3 3.2-5.6 1.7-2.7 3.7-5.1 2.5-3.2 5.3-5.9 3-2.8 6.1-5.4 3.2-2.4 6.8-4.4 3.5-2 7.2-3.5zm48.3 146.4c-2.3 0.1-4.4 1-6 2.8-1.5 1.6-2.4 3.7-2.4 5.9 0 2.3 0.9 4.4 2.4 6.2 1.6 1.6 3.7 2.5 6 2.6h50.4c2.4 0.1 4.8-0.6 6.5-2.4 1.7-1.6 2.8-4 2.8-6.4 0-2.4-1.1-4.7-2.8-6.3-1.7-1.8-4.1-2.6-6.5-2.4zm-56.7-64.9c-1.2-1.9-3-3.4-5.3-3.9-2.2-0.5-4.5-0.3-6.5 0.9-2 1.1-3.5 3-4.1 5.2-0.7 2.2-0.4 4.6 0.6 6.5l17.7 30.9-17.5 29.5c-1.2 2-1.6 4.5-1.1 6.8 0.7 2.3 2.1 4.1 4.1 5.3 2 1.2 4.4 1.6 6.7 0.9 2.2-0.5 4.2-1.9 5.4-3.9l20.1-34.1q0.7-0.9 0.9-2.1 0.3-1.1 0.3-2.3 0-1.2-0.3-2.2-0.2-1.2-0.8-2.2z"/></svg>',
  opencode: '<svg class="plogo" viewBox="0 0 240 300"><rect x="60" y="60" width="120" height="180" fill="#f1ecec"/><rect x="60" y="120" width="120" height="120" fill="#4b4646"/></svg>',
  antigravity: '<svg class="plogo" viewBox="0 0 433.6116 399.5841"><defs><clipPath id="agshape"><path d="M392.7093,390.1368c24.1674,18.1304,60.4188,6.0437,27.1881-27.1951C320.2075,266.2476,341.3537.3394,217.4969.3394S114.7857,266.2475,15.0959,362.9417c-36.2508,36.2602,3.0208,45.3255,27.1881,27.1952,93.6484-63.4553,87.6065-175.2576,175.2129-175.2576s81.5645,111.8022,175.2124,175.2576h0Z"/></clipPath><linearGradient id="agleft" x1="15%" y1="100%" x2="50%" y2="0%"><stop offset="0%" stop-color="#3087FC"/><stop offset="25%" stop-color="#2C96D4"/><stop offset="45%" stop-color="#3DA7AE"/><stop offset="65%" stop-color="#67C073"/><stop offset="82%" stop-color="#AEC741"/><stop offset="100%" stop-color="#DFBB26"/></linearGradient><linearGradient id="agright" x1="50%" y1="0%" x2="85%" y2="100%"><stop offset="0%" stop-color="#DFBB26"/><stop offset="12%" stop-color="#ED852E"/><stop offset="25%" stop-color="#F6563A"/><stop offset="45%" stop-color="#CB5A77"/><stop offset="65%" stop-color="#8E77C2"/><stop offset="82%" stop-color="#578DF7"/><stop offset="100%" stop-color="#3087FC"/></linearGradient><linearGradient id="agblend" x1="30%" y1="0%" x2="70%" y2="0%"><stop offset="0%" stop-color="#FFF"/><stop offset="100%" stop-color="#000"/></linearGradient><mask id="agmask"><rect width="434" height="400" fill="url(#agblend)"/></mask></defs><g clip-path="url(#agshape)"><rect width="434" height="400" fill="url(#agright)"/><rect width="434" height="400" fill="url(#agleft)" mask="url(#agmask)"/></g></svg>',
  fx: '<svg class="plogo" viewBox="166.241 0 155.861 156" fill="currentColor"><path d="M237.89 0C243.18 0 249.38 1.42 253.03 3.07L255.09 4.01L250.08 18.63L247.68 17.75C244.9 16.72 241.94 15.8 238.49 15.8C234.98 15.8 232.79 16.56 231.08 18.32C229.23 20.23 227.63 23.64 226.23 29.76L225.14 34.85H241.67L260.43 34.95L260.69 34.95L260.84 35.17L278.85 61.63L296.74 34.95H320.87L291.68 76.74L322.1 119.75H299.33L299.18 119.55L241.14 40.48L239.35 49.4H222.07L205.69 127.21C203.93 135.71 201.19 142.84 196.78 147.87C192.27 153.01 186.2 155.75 178.34 155.75C174.18 155.75 170.75 155.11 167.91 154.11L166.24 153.52V137.18L166.9 137.4L169.53 138.28C172.18 139.16 174.41 139.8 177.14 139.8C178.53 139.8 179.7 139.53 180.73 138.98C181.76 138.43 182.68 137.6 183.52 136.44C185.3 133.99 186.72 130.13 187.9 124.67L203.76 49.4H189.87L191.76 39.44L192.04 39.35L206.82 34.47L208.15 28.64C210.52 18.21 213.77 10.94 218.71 6.32C223.74 1.61 230.13 0 237.89 0ZM273.99 99.08L260.07 120.25H234.54L261 82.02L273.99 99.08Z"/></svg>',
  sarvam: '<svg class="plogo" viewBox="0 0 253 250" fill="#f56133"><path d="M252 109C252 108 251 107 251 106C247 100 243 94 237 89L237 89C237 88 236 87 236 87C232 84 228 80 224 77C224 77 224 77 224 77C223 77 223 77 223 76C223 76 222 76 222 76C222 76 222 76 222 76C222 76 222 76 222 75C222 75 222 75 222 75C222 70 222 65 221 60L221 60C221 59 221 58 220 58V58C219 50 216 43 213 36C213 35 212 34 212 33L211 32L210 32C209 32 208 31 207 31C204 30 200 29 197 28C193 27 190 27 186 26C185 26 185 26 184 26C178 26 173 26 167 26C167 26 167 26 166 26C166 26 166 26 166 26C163 22 159 19 155 15C154 15 154 14 153 14L153 14C147 9 140 5 133 2C132 1 132 1 131 0L130 0L129 0C128 1 127 1 126 1C119 4 112 7 106 12L105 12C105 12 105 13 104 13C100 16 95 20 91 24C86 23 81 23 76 23C75 23 74 23 73 23C65 23 58 24 50 26C49 27 48 27 47 27L46 28L46 29C45 29 45 30 44 31C40 38 38 45 36 52C35 52 35 53 35 54C34 59 33 65 32 71C28 74 24 77 19 80C19 81 18 81 18 82C12 87 7 93 2 99L2 99C2 100 1 101 1 101L0 102L0 103C0 104 1 105 1 106C2 114 4 121 8 128L8 128C8 129 8 129 9 130L9 131C11 136 14 140 17 144C16 149 14 155 13 160V160C13 161 13 161 13 162C12 170 12 177 12 185C12 186 12 187 13 188L13 189L14 190C14 191 15 191 16 192L16 192C22 197 28 201 35 204L35 204C36 204 36 204 36 204L37 205C42 207 48 209 53 210C55 215 57 220 60 225L60 225C61 226 61 227 61 227C65 233 70 239 76 245C76 245 77 246 78 247L78 248H80C81 248 82 248 83 248C86 247 90 247 93 247C97 246 100 246 104 245L105 244C106 244 107 244 107 244C113 242 118 240 123 238C123 238 123 238 123 238C123 238 123 238 123 238C128 241 133 243 138 245C138 245 139 245 139 245L140 245C147 248 155 249 162 250L164 250C164 250 165 250 165 250L166 250L167 249C168 249 169 248 170 247C175 243 180 238 184 232L185 231V231C185 230 186 229 186 229C188 226 189 224 191 221L191 220C192 218 193 217 194 215C194 215 194 215 194 214C194 214 194 214 194 214C194 214 194 214 194 214C194 214 194 214 194 214C194 214 195 214 195 214C195 214 196 214 196 214C201 213 206 211 210 210L211 209C212 209 212 209 212 209C219 206 226 202 232 198L233 197L235 196L235 194C236 194 236 194 236 193L236 192C237 184 237 177 237 169C237 168 237 168 237 167C236 164 236 161 235 159C235 156 234 154 234 152C234 152 234 152 234 152C234 151 234 151 234 151C233 151 233 151 233 150C234 150 234 150 234 150C234 149 234 149 234 149C234 149 234 149 235 149C237 145 240 142 242 138L243 137C243 136 243 135 244 135C247 128 250 121 252 114L252 112C253 112 253 111 253 111L253 110L252 109L252 109ZM214 81L215 81L215 81V81L215 82L215 84V84C214 89 213 94 212 100L212 101C211 102 211 103 211 104C210 106 209 108 209 110C203 105 197 101 191 97H191C190 97 190 97 190 96L189 96C189 96 189 96 189 96C189 96 189 96 189 96L187 95L187 94C188 93 188 92 188 91C188 84 188 77 187 70C190 71 192 71 194 72L195 72C196 73 197 73 198 73C203 75 207 77 212 79L214 80L214 80V81ZM189 135L184 140L188 149C190 155 192 161 193 168L193 168C193 169 193 169 193 169C192 169 192 170 192 170C185 172 179 173 173 174L172 174C172 174 171 174 171 174L163 175L161 182C160 182 160 183 160 184L160 184C158 190 155 196 152 201L152 201C151 202 151 202 151 203L150 202C143 200 138 197 132 193C132 193 132 192 131 192L131 192L124 187L118 191C117 192 117 192 116 192C111 196 105 198 99 200H99C98 201 98 201 97 201C97 201 97 201 97 200L96 200C93 194 91 188 89 182L89 181C89 181 89 181 89 180L87 172L81 172C80 171 79 171 78 171C78 171 78 171 77 171C74 171 71 170 68 169C65 168 62 167 59 166L58 166C58 166 57 166 57 165C57 165 57 164 57 164L57 163C59 157 61 151 63 145C63 145 64 145 64 144L64 144C64 143 65 142 65 141L67 136L63 132L62 131C62 131 61 130 61 130C59 127 57 125 55 122C53 119 52 117 50 114L50 114C50 113 49 113 49 112C49 112 49 112 49 112L49 112L51 111C55 107 60 104 66 102L67 101C68 101 68 100 69 100L75 97V90C75 90 75 90 75 90V89C75 89 75 88 75 88V88C75 81 76 75 77 69L77 67C77 67 77 67 77 67C78 67 79 67 80 67L81 67C87 67 92 68 98 69C99 70 100 70 100 70L108 72L112 65C112 65 113 65 113 65L113 64C117 59 122 55 127 51L128 50C128 50 128 50 128 50L128 50C129 50 129 51 130 51L130 51C135 55 139 60 143 65L143 66L143 66C143 66 143 67 144 67L148 73L155 72C155 72 156 72 156 71C156 71 157 71 157 71C164 70 171 69 177 70H178C178 70 178 70 178 70C178 70 178 71 179 72C179 78 180 84 179 91V91L179 91C179 91 179 92 179 93L178 100L185 104C185 104 185 104 185 104L187 105C192 107 197 111 202 115L203 116C203 116 203 117 204 117C203 117 203 118 203 118C198 126 192 133 191 133C190 134 190 135 189 135L189 135H189ZM67 88V88C67 88 67 89 67 90V90C67 90 67 90 67 90C67 90 67 90 67 90C67 90 67 90 67 90V92L65 92C65 93 64 93 63 93L62 94C56 97 51 100 46 104C46 102 45 100 45 98L44 98C44 97 44 96 44 95C43 90 42 84 42 79L42 76L45 75H45C50 72 55 70 61 69C62 69 63 68 64 68C65 68 67 68 68 67C67 74 66 81 67 88L67 88ZM183 35C184 35 184 35 185 35H185C189 35 192 36 195 36C198 37 201 38 205 39H205C205 39 205 39 205 39C205 39 205 40 205 40C208 46 211 53 212 59L212 60C212 60 212 61 212 62L213 64C213 66 213 68 213 70C209 68 205 66 200 65C199 65 198 64 197 64L197 64H197C193 63 190 62 186 62C186 59 185 56 183 53V53C183 52 183 51 182 50C180 44 177 39 174 35C177 34 180 34 183 35ZM164 36L164 36H164L165 38L166 38C169 43 172 48 174 53V53C175 54 175 55 175 56L175 56C176 58 177 59 177 61C170 61 163 61 155 63C155 63 154 63 154 63C154 63 153 63 153 63L152 64L151 62C150 62 150 61 150 60V60C146 55 141 50 136 45C138 44 140 43 142 42L143 42C144 41 145 41 146 41L146 40C151 39 156 37 161 36L164 36L164 36ZM109 20L109 20C110 20 110 19 110 19L111 19C117 15 123 12 129 9H129C129 9 129 9 129 9C129 9 130 9 130 9C136 12 142 16 148 20L148 20C148 21 149 21 149 22C152 24 154 26 156 28C152 29 147 31 143 33L143 33C142 33 141 34 140 34L138 35L138 35C135 36 132 37 130 39C127 37 124 36 122 34L122 34C121 34 120 33 119 33L118 33C113 30 107 28 101 26C104 24 107 22 109 20V20ZM94 36L95 34L98 34L98 34C104 36 110 38 115 40L115 41C116 41 116 41 117 41L118 42C119 43 120 43 122 44L121 44C116 49 111 54 106 59L106 60C106 60 106 60 105 60L104 62L103 62C102 62 101 61 100 61C94 60 88 59 81 58H81C82 56 83 54 84 52C84 51 85 50 85 49L85 49C88 44 90 40 94 36H94ZM43 56C44 55 44 55 44 54C46 47 48 41 52 35L52 35C52 35 52 35 52 35C59 33 66 32 73 32H74C74 32 75 32 76 32C79 32 82 32 86 32C83 36 80 40 78 45V45C77 46 76 47 76 48C74 51 73 55 72 58C72 58 72 58 72 58C71 58 71 58 71 58C68 59 65 59 62 60C61 60 60 60 59 61C53 62 47 64 42 67C42 63 43 59 44 56L43 56ZM17 127L16 126C16 126 16 125 16 125L15 124C13 118 10 111 9 105C9 105 9 104 9 104L10 103C14 97 18 92 23 88C24 87 24 87 25 87C28 84 30 82 33 80C34 86 34 91 35 96C36 97 36 99 36 100V100C37 103 38 106 39 110C39 110 39 110 39 110C39 110 39 110 39 110C39 110 39 110 39 111C39 111 39 111 39 111C37 113 35 115 33 118L32 119C31 120 31 120 31 121C27 125 24 130 22 136C20 133 18 130 17 127ZM41 197L40 196C40 196 39 196 39 196L39 196C33 193 27 189 21 185L21 185L21 184C20 177 20 170 21 163V163C21 163 22 162 22 161V161C22 158 23 154 24 151C28 155 32 159 37 163L38 164C38 164 39 165 39 165C42 167 45 169 47 170C48 170 48 171 48 171C48 171 48 171 48 171C48 174 48 178 48 181C48 182 48 183 48 185C49 190 50 195 51 201C48 200 44 198 41 197V197ZM55 142C53 148 51 154 49 161L49 161C47 160 46 159 44 158C44 158 44 157 43 157L42 156C38 153 34 149 30 145L28 143L29 140L29 140C32 135 35 130 38 126C38 125 38 125 39 125L40 123C41 122 42 120 43 119C44 122 46 124 48 127C50 130 52 133 55 135C55 136 56 137 56 137L57 138L57 138C57 139 56 140 56 141C56 141 56 142 56 142L55 142ZM61 203L60 200L60 200C58 195 57 189 57 184V184C57 183 57 182 57 181C57 179 57 177 57 175C60 176 63 177 65 177C69 178 72 179 76 180C76 180 77 180 77 180C78 180 79 180 80 180L80 182C80 182 80 182 80 182L80 182C80 183 81 183 81 184C83 191 85 197 89 203C87 204 85 204 83 204C82 204 81 204 80 204C79 204 78 204 77 204C72 204 68 204 64 203L61 203V203ZM105 235C104 236 104 236 103 236L102 236C98 237 95 238 92 238C89 239 86 239 82 239C82 239 82 239 82 239C82 239 82 239 81 239C77 234 72 228 69 223C68 222 68 222 68 221L67 221C66 218 64 215 63 212C69 213 75 213 81 213C82 213 83 213 84 213C87 212 91 212 94 211C96 214 98 217 101 220C102 220 102 221 103 222C107 226 111 229 115 232C111 233 108 234 105 235L105 235ZM127 226C126 227 125 228 124 228L122 226L122 226C117 223 113 220 109 216C109 215 108 214 107 214C106 212 104 210 103 208C109 206 115 203 121 200C121 199 122 199 123 199L124 198L125 199C125 199 126 199 126 199H126C126 199 127 200 127 200C133 204 140 207 146 210C145 211 144 213 143 214L141 215C141 216 140 216 140 216C136 220 131 223 127 226L127 226L127 226ZM183 216L183 217C182 219 180 222 179 224C178 225 178 225 178 226L177 227C173 232 169 237 164 241C164 241 164 241 163 241L163 241C156 241 149 239 143 237L142 237C141 237 141 237 141 237C138 236 135 234 132 233C137 230 142 227 146 223C146 222 147 222 147 221L148 220C151 218 153 216 155 213C158 214 162 215 165 215L167 215C168 215 168 215 169 215C174 216 179 216 184 216C184 216 184 216 183 216L183 216ZM194 183L194 184C194 185 194 186 194 187C193 193 192 198 190 203L189 206L189 206L189 207L188 207L186 207H186C180 207 175 207 170 207H169C169 207 169 207 168 207L167 206C164 206 162 206 159 205C163 199 166 193 168 186V186C168 186 169 185 169 184L169 183L171 183C171 183 171 183 171 183H171C172 182 173 182 173 182H173C180 182 188 180 194 178C194 178 194 178 194 178C194 180 194 181 194 183L194 183ZM196 146L194 142L195 141C196 141 196 140 197 140C198 138 205 131 210 123C210 123 210 123 210 123C212 124 213 126 214 127L215 128C215 129 216 130 216 131L217 132C220 136 222 141 224 146L224 147L225 148L225 148L225 148C225 148 225 148 225 148L225 149L224 149L224 149L223 150L223 151C219 154 214 158 210 161C209 162 208 162 207 163C205 164 203 165 201 166C200 159 198 152 196 146L196 146ZM228 190L227 191L227 191C221 195 215 198 209 201H209C209 201 208 201 208 201L207 202C204 203 202 203 199 204C200 199 202 194 202 189C202 187 203 186 203 185L203 184C203 181 203 178 203 175C206 174 209 172 212 170C213 170 214 169 215 168C219 165 223 162 227 159C227 159 227 160 227 160C227 163 228 165 228 168C228 168 228 169 228 170V170C229 177 228 183 227 190L228 190ZM244 111C242 118 239 125 236 131C236 131 236 132 235 132L235 133C233 136 232 138 231 140C229 135 226 131 224 127L224 126C223 125 222 125 222 124L222 124C220 121 218 118 215 115C217 112 218 109 219 106C219 105 220 104 220 103L220 102C221 97 222 92 223 87C225 89 228 91 230 93C230 94 231 94 231 95L232 96C237 100 240 105 244 110C244 111 244 111 244 111L244 111L244 111Z"/><path fill-rule="evenodd" d="M135 134C132 136 130 139 126 141C123 139 121 136 118 134C115 131 113 128 111 125C113 122 115 119 118 116C121 114 123 111 126 109C130 111 132 114 135 116C138 119 140 122 142 125C140 128 138 131 135 134Z"/></svg>',
};

function providerLogo(p) {
  if (p == "claude" || p == "claudeCode" || p == "anthropic") return LOGOS.claude;
  if (p == "codex" || p == "openai" || p == "chatgpt") return LOGOS.codex;
  if (p == "opencode" || p == "openCode") return LOGOS.opencode;
  if (p == "antigravity") return LOGOS.antigravity;
  if (p == "fx") return LOGOS.fx;
  if (p == "sarvam" || p == "sarvamCode") return LOGOS.sarvam;
  return '<svg class="plogo" viewBox="0 0 24 24" fill="#888"><circle cx="12" cy="12" r="8"/></svg>';
}

// Same aliases providerLogo folds together, so the composer names whoever its avatar is showing.
function providerLabel(p) {
  if (p == "claude" || p == "claudeCode" || p == "anthropic") return "Claude";
  if (p == "codex" || p == "openai" || p == "chatgpt") return "Codex";
  if (p == "opencode" || p == "openCode") return "OpenCode";
  if (p == "antigravity") return "Antigravity";
  if (p == "fx") return "fx";
  if (p == "sarvam" || p == "sarvamCode") return "Sarvam Code";
  return p ? p.charAt(0).toUpperCase() + p.slice(1) : "";
}

// Trim a model id to the part worth glancing at on a phone: drop a provider path prefix
// (anthropic/\u2026, zai/\u2026) and the redundant "claude-" vendor tag.
function shortModel(m) {
  return String(m).split("/").pop().replace(/^claude-/, "");
}

function agentRow(a) {
  const path = dispPath(a.path);
  const model = a.model ? '<span class="tm">' + esc(shortModel(a.model)) + "</span>" : "";
  const dot = a.attention ? '<span class="dot">\u25cf</span>' : "";
  return providerLogo(a.provider) +
    '<span class="t">' +
    '<span class="tl">' + dot + '<span class="ttl">' + dispTitle(a.title) + "</span>" + model + "</span>" +
    (path ? '<span class="tp">' + path + "</span>" : "") +
    "</span>";
}

const DEFAULT_TITLE = "Toki Remote Control";

function setDocTitle(agent) {
  if (!agent) {
    document.title = DEFAULT_TITLE;
    return;
  }
  const chat = plainTitle(agent.title) || DEFAULT_TITLE;
  document.title = agent.machine ? agent.machine + " - " + chat : chat;
}

function renderAgents() {
  const btn = $("#ddbtn");
  const list = $("#ddlist");
  if (!agents.length) {
    btn.innerHTML = '<span class="t">no agents found</span>';
    list.innerHTML = "";
    updateComposer(null);
    setDocTitle(null);
    return;
  }
  const cur = agents.find(a => a.pid == current) || agents[0];
  btn.innerHTML = agentRow(cur) + '<span class="caret">\u25be</span>';
  updateComposer(cur);
  setDocTitle(cur);
  // The server sorts writable agents first, making read-only agents one contiguous group.
  list.innerHTML = agents.map((a, i) => {
    const startsReadOnly = !a.writable && (i == 0 || agents[i - 1].writable);
    return (startsReadOnly ? '<div class="ddgroup">Read-only</div>' : "") +
      '<div class="dditem' + (a.pid == current ? " sel" : "") + '" data-pid="' + a.pid + '">' + agentRow(a) + "</div>";
  }).join("");
  list.querySelectorAll(".dditem").forEach(el => el.onclick = ev => {
    ev.stopPropagation();
    if (+el.dataset.pid == current) {
      $("#dd").classList.remove("open");
      return;
    }
    current = +el.dataset.pid;
    resetTranscript();
    clearPendingImage();  // Attachments are agent-scoped.
    $("#dd").classList.remove("open");
    renderAgents();
    refreshLog();
  });
}

function updateComposer(agent) {
  const writable = !!(agent && agent.writable);
  const enabled = writable && !sending && !uploading;
  $("#readonly").style.display = agent && !writable ? "block" : "none";
  // Hosted UI versions can be newer than the server; gate uploads on its capability flag.
  $("#attach").hidden = !(agent && agent.uploads);
  // agent.screen gates the buttons off for older servers that lack /api/screen. The Model button
  // is a shortcut for providers with a known command; the Screen button mirrors any app's terminal.
  const canMirror = writable && agent && agent.screen;
  $("#model").hidden = !(canMirror && MODEL_COMMANDS[agent.provider]);
  $("#screen").hidden = !canMirror;
  if (!writable || (modelMirror && (!agent || modelMirror.pid != agent.pid))) closeModelMirror();
  document.querySelectorAll("footer button,footer input,footer textarea").forEach(el => el.disabled = !enabled);
  // The avatar names who the reply is going to, which the placeholder alone never did once
  // more than one agent was running.
  $("#composeravatar").innerHTML = agent ? providerLogo(agent.provider) : "";
  const who = agent ? providerLabel(agent.provider) : "";
  $("#msg").placeholder = writable
    ? (who ? "Reply to " + who + "\u2026" : "Reply to the agent\u2026")
    : (agent ? "Read-only session" : "No active session");
}

// A tall field is worth having for a long reply and in the way the rest of the time, so it is a
// toggle rather than the default.
function toggleComposerExpanded() {
  const composer = document.querySelector(".composer");
  const expanded = composer.classList.toggle("expanded");
  $("#expand").setAttribute("aria-pressed", expanded ? "true" : "false");
  $("#expand").title = expanded ? "Collapse the composer" : "Expand the composer";
  if (!expanded) resizeComposer();
  $("#msg").focus();
}

// Clearing is irreversible, so require a second tap within five seconds.
let clearArmed = false;
let clearTimer = null;

function setClearArmed(on) {
  clearArmed = on;
  const b = $("#clear");
  b.classList.toggle("armed", on);
  b.setAttribute("aria-label", on ? "Tap again to clear the agent\u2019s context" : "Clear the agent\u2019s context");
  b.title = on ? "Tap again to clear" : "Clear the agent\u2019s context (/clear)";
  clearTimeout(clearTimer);
  if (on) clearTimer = setTimeout(() => setClearArmed(false), 5000);
}

function clearContext() {
  if (!clearArmed) {
    setClearArmed(true);
    setStatus("Tap again to clear this agent\u2019s context.", "");
    statusTimer = setTimeout(() => setStatus("", ""), 5000);
    return;
  }
  setClearArmed(false);
  send({ text: "/clear" }).then(ok => {
    if (ok) resetTranscript();
  });
}

// The slash command that opens each writable provider's model picker. Toki mirrors the picker the
// command draws; selection is driven with the arrow/Enter footer, so no per-provider parsing.
const MODEL_COMMANDS = {
  claude: "/model",
  codex: "/model",
  sarvam: "/model",
  opencode: "/models",
  fx: "/model",
  antigravity: "/model",
};

// A leading slash command (/usage, /help, /model) opens an interactive view or picker in the CLI's
// own TUI, so it is mirrored and driven with the key footer rather than sent as a plain reply that
// would strand the phone waiting on an answer. A path like /Users/me is deliberately not matched.
const SLASH_COMMAND_RE = /^\/[a-zA-Z][\w-]*( .*)?$/;
function isSlashCommand(text) {
  return SLASH_COMMAND_RE.test(text);
}

// Render a captured terminal screen (with the ANSI color codes tmux -e keeps) as HTML, so a picker
// whose selection is shown only by a highlight color reads correctly on the phone. Plain text with
// no codes passes straight through, escaped; non-color escape sequences are dropped.
const ANSI_BASIC = ["#1a1d23", "#e06c75", "#98c379", "#d5b26a", "#61afef", "#c678dd", "#56b6c2", "#c8cdd6"];
const ANSI_BRIGHT = ["#5c6370", "#ef5f6b", "#a6d189", "#e5c07b", "#7cc0ff", "#d19aea", "#66d0dc", "#ffffff"];

function ansiColor(n) {
  if (n < 8) return ANSI_BASIC[n];
  if (n < 16) return ANSI_BRIGHT[n - 8];
  if (n < 232) {
    n -= 16;
    const c = v => (v ? v * 40 + 55 : 0);
    return `rgb(${c((n / 36 | 0) % 6)},${c((n / 6 | 0) % 6)},${c(n % 6)})`;
  }
  const v = (n - 232) * 10 + 8;
  return `rgb(${v},${v},${v})`;
}

function ansiToHtml(text) {
  // Drop cursor moves and other non-color escapes tmux -e can still emit.
  text = text.replace(/\x1b\[[0-9;?]*[A-Za-ln-z]/g, "").replace(/\x1b\][\s\S]*?(\x07|\x1b\\)/g, "");
  let fg = null, bg = null, bold = false, rev = false, out = "";
  const flush = seg => {
    if (!seg) return;
    let f = rev ? bg || "#0b0d10" : fg, b = rev ? fg || "#e6edf3" : bg;
    const s = (f ? "color:" + f + ";" : "") + (b ? "background:" + b + ";" : "") + (bold ? "font-weight:700" : "");
    out += s ? `<span style="${s}">` + esc(seg) + "</span>" : esc(seg);
  };
  const re = /\x1b\[([0-9;]*)m/g;
  let m, last = 0;
  while ((m = re.exec(text))) {
    flush(text.slice(last, m.index));
    last = re.lastIndex;
    const codes = m[1] ? m[1].split(";").map(Number) : [0];
    for (let j = 0; j < codes.length; j++) {
      const c = codes[j];
      if (c === 0) { fg = bg = null; bold = rev = false; }
      else if (c === 1) bold = true;
      else if (c === 22) bold = false;
      else if (c === 7) rev = true;
      else if (c === 27) rev = false;
      else if (c === 39) fg = null;
      else if (c === 49) bg = null;
      else if (c >= 30 && c <= 37) fg = ANSI_BASIC[c - 30];
      else if (c >= 90 && c <= 97) fg = ANSI_BRIGHT[c - 90];
      else if (c >= 40 && c <= 47) bg = ANSI_BASIC[c - 40];
      else if (c >= 100 && c <= 107) bg = ANSI_BRIGHT[c - 100];
      else if (c === 38 || c === 48) {
        const col = codes[j + 1] === 5 ? (Number.isFinite(codes[j + 2]) ? ansiColor(codes[j + 2]) : null)
          : codes[j + 1] === 2 ? `rgb(${codes[j + 2] || 0},${codes[j + 3] || 0},${codes[j + 4] || 0})` : null;
        j += codes[j + 1] === 5 ? 2 : codes[j + 1] === 2 ? 4 : 0;
        if (c === 38) fg = col; else bg = col;
      }
    }
  }
  flush(text.slice(last));
  return out;
}

// While mirroring, hold the agent whose picker is open and the poll that repaints it.
let modelMirror = null;

// One capture in flight at a time: a slow AppleScript reader can take seconds, so the next poll is
// scheduled only after this one settles rather than on a fixed interval that would stack requests.
async function refreshModelMirror() {
  const pid = modelMirror && modelMirror.pid;
  if (!pid || modelMirror.inflight) return;
  clearTimeout(modelMirror.timer);  // a manual refresh takes over any scheduled poll, never stacks
  modelMirror.inflight = true;
  const pre = $("#modelscreen");
  try {
    const r = await api("/api/screen?pid=" + pid);
    if (!modelMirror || modelMirror.pid != pid) return;
    if (r.ok && r.text) pre.innerHTML = ansiToHtml(r.text);
    else pre.textContent = r.error ? "Can’t read this terminal: " + r.error : "No picker on screen.";
  } catch (e) {
    if (modelMirror && modelMirror.pid == pid) pre.textContent = "Couldn’t read the screen: " + e.message;
  } finally {
    if (modelMirror && modelMirror.pid == pid) {
      modelMirror.inflight = false;
      modelMirror.timer = setTimeout(refreshModelMirror, 700);
    }
  }
}

function openMirror(agent, label, opening, delay) {
  if (!agent) return;
  closeModelMirror();
  modelMirror = { pid: agent.pid, inflight: false };
  $("#mmlabel").textContent = label;
  $("#modelmirror").hidden = false;
  $("#modelscreen").textContent = opening;
  modelMirror.timer = setTimeout(refreshModelMirror, delay);
}

// Mirror whatever the agent's terminal is already showing, for any app -- no command sent, so the
// phone can watch and drive an arbitrary picker or prompt with the key footer.
function openScreenMirror(agent) {
  openMirror(agent, "Live terminal: drive it with the keys below", "Reading the screen…", 250);
}

function openCommandMirror(agent, cmd, label) {
  if (!agent || !cmd) return;
  // Fire the command in the CLI's own TUI, then mirror whatever it draws -- a picker, /usage
  // output, /help -- and let the key footer drive it, rather than sending it as a reply.
  send({ text: cmd });
  openMirror(agent, label, "Opening " + cmd + "…", 450);
}

function openModelMirror(agent) {
  const cmd = agent && MODEL_COMMANDS[agent.provider];
  if (!cmd) return;
  openCommandMirror(agent, cmd, "Model picker: choose with the keys below");
}

function closeModelMirror() {
  if (!modelMirror) return;
  clearTimeout(modelMirror.timer);
  modelMirror = null;
  $("#modelmirror").hidden = true;
}

let notifiedAttention = {};
let notifySeeded = false;

function attentionKey(a) {
  if (!a.attention) return "";
  const q = a.attention.questions && a.attention.questions.length
    ? a.attention.questions.map(x => x.question).join("|")
    : (a.attention.prompt || "");
  return a.attention.kind + ":" + q;
}

function notifyAttention(list) {
  if (!("Notification" in window) || Notification.permission != "granted") {
    notifiedAttention = {};
    return;
  }
  const seen = {};
  for (const a of list) {
    const key = attentionKey(a);
    if (!key) continue;
    seen[a.pid] = key;
    if (notifySeeded && notifiedAttention[a.pid] != key) showAttentionNotification(a);
  }
  notifiedAttention = seen;
  notifySeeded = true;
}

function showAttentionNotification(a) {
  const kind = a.attention.kind == "permission" ? "needs approval" : "needs your input";
  const q = (a.attention.questions && a.attention.questions[0] && a.attention.questions[0].question)
    || a.attention.prompt || "";
  const opts = {
    body: q.replace(/[#*`>]/g, "").trim().slice(0, 140),
    tag: "toki-" + a.pid,
    renotify: true,
    data: { pid: a.pid },
  };
  const title = a.title + " " + kind;
  if (navigator.serviceWorker && navigator.serviceWorker.ready)
    navigator.serviceWorker.ready.then(r => r.showNotification(title, opts))
      .catch(() => {
        try {
          new Notification(title, opts);
        } catch (e) {}
      });
  else try {
    new Notification(title, opts);
  } catch (e) {}
}

function updateAlertsButton() {
  $("#enablealerts").hidden = !("Notification" in window) || Notification.permission != "default" || !TOKEN;
}

async function refreshAgents() {
  agents = await api("/api/agents");
  const prev = current;
  notifyAttention(agents);
  if (agents.length && !agents.some(a => a.pid == prev)) {
    current = agents[0].pid;
    resetTranscript();
    clearPendingImage();  // Attachments are agent-scoped.
  }
  renderAgents();
  renderAttention(agents.find(x => x.pid == current));
}

// Persist picker selections across polls until the pending question changes.
let answer = null;

// Include pid to prevent cross-agent selection leaks; JSON encoding avoids delimiter collisions.
function questionSignature(pid, provider, qs) {
  return JSON.stringify([pid, provider, qs.map(q =>
    [q.header || "", q.question || "", q.multi ? 1 : 0, (q.options || []).map(o => o.label)])]);
}

// Normalize pre-2.7.1 string options to the current object shape.
function attentionQuestions(att) {
  const qs = att.questions && att.questions.length
    ? att.questions
    : [{ question: att.prompt || "Agent is waiting on you", header: "", multi: false, options: att.options || [] }];
  return qs.map(q => ({
    question: q.question || "", header: q.header || "", multi: !!q.multi,
    options: (q.options || []).map(o => (typeof o == "string" ? { label: o, description: "" } : o)),
  }));
}

function renderAttention(a) {
  const panel = $("#alert");
  if (!a || !a.attention) {
    answer = null;
    panel.style.display = "none";
    return;
  }
  panel.style.display = "block";
  panel.className = a.attention.kind == "question" ? "q" : "";
  if (a.attention.kind != "question") {
    answer = null;
    panel.innerHTML = '<div class="ahead">Needs your approval</div>' +
      '<div class="qq">' + md(a.attention.prompt || "") + "</div>" +
      '<div class="decision-row"><button class="decision approve" data-key="enter">&#10003; Approve</button>' +
      '<button class="decision reject" data-key="esc">&#10005; Reject</button></div>';
    return;
  }
  const qs = attentionQuestions(a.attention);
  const sig = questionSignature(a.pid, a.provider, qs);
  if (!answer || answer.sig != sig)
    answer = { sig, provider: a.provider, questions: qs, sel: qs.map(() => new Set()) };
  renderQuestions();
}

function isQuickPick(qs) {
  return qs.length == 1 && !qs[0].multi;
}

function answerComplete(qs, sel) {
  return sel.every((s, i) => !(qs[i].options || []).length || s.size > 0);
}

function renderQuestions() {
  const { questions: qs, sel } = answer;
  let html = '<div class="ahead">Agent is asking</div>';
  qs.forEach((q, qi) => {
    if (q.header)
      html += '<div class="qhdr">' + esc(q.header) +
        (q.multi ? '<span class="qtag">select all that apply</span>' : "") + "</div>";
    html += '<div class="qq">' + md(q.question || "") + "</div>";
    (q.options || []).forEach((o, oi) => {
      const on = sel[qi].has(oi);
      html += `<button class="opt${on ? " on" : ""}" data-opt="${qi}:${oi}" ` +
        `role="${q.multi ? "checkbox" : "radio"}" aria-checked="${on}">` +
        `<span class="mark ${q.multi ? "box" : "radio"}" aria-hidden="true"></span>` +
        `<span class="olab"><b>${esc(o.label)}</b>` +
        (o.description ? `<em>${esc(o.description)}</em>` : "") + "</span></button>";
    });
  });
  if (!isQuickPick(qs)) {
    // The TUIs default or drop unanswered questions, so require every available choice.
    html += '<div class="decision-row one"><button class="decision approve" data-submit="1"' +
      (answerComplete(qs, sel) ? "" : " disabled") + ">Submit</button></div>";
  }
  $("#alert").innerHTML = html;
}

function toggleOption(spec) {
  // Freeze selection while its computed keystrokes are in flight.
  if (!answer || submitting) return;
  const [qi, oi] = spec.split(":").map(Number);
  const set = answer.sel[qi];
  if (answer.questions[qi].multi) {
    if (set.has(oi)) set.delete(oi);
    else set.add(oi);
  } else {
    set.clear();
    set.add(oi);
  }
  if (isQuickPick(answer.questions)) submitAnswer();
  else renderQuestions();
}

// OpenCode navigates with arrows/Enter/Tab; Claude selects by number and advances with Tab.
// Antigravity numbers its options too, but a single-select number both selects and advances (and on
// the last question submits), while a multi-select number toggles and Enter advances or submits.
function buildKeySequence(provider, questions, sel) {
  const keys = [];
  const anyMulti = questions.some(q => q.multi);
  const last = questions.length - 1;
  questions.forEach((q, qi) => {
    const chosen = [...sel[qi]].sort((x, y) => x - y);
    const n = (q.options || []).length;
    if (provider == "opencode") {
      if (q.multi) {
        for (let i = 0; i < n; i++) {
          if (sel[qi].has(i)) keys.push("enter");
          if (i < n - 1) keys.push("down");
        }
        keys.push("tab");
      } else {
        for (let i = 0, idx = chosen.length ? chosen[0] : 0; i < idx; i++) keys.push("down");
        keys.push("enter");
      }
    } else if (provider == "antigravity") {
      // The cursor resets to the top of each question, so no inter-question separator: a
      // single-select number carries straight on, and a multi-select needs Enter to move past it.
      chosen.forEach(i => keys.push(String(i + 1)));
      if (q.multi) keys.push("enter");
    } else {
      // Claude's picker caps options to single-digit shortcuts.
      chosen.forEach(i => keys.push(String(i + 1)));
      if (qi < last) keys.push("tab");
    }
  });
  if (provider == "opencode" && (questions.length > 1 || anyMulti)) keys.push("enter");
  else if (provider != "opencode" && provider != "antigravity" && !isQuickPick(questions)) keys.push("enter");
  return keys;
}

let submitting = false;

async function submitAnswer() {
  if (!answer || submitting) return;
  if (!answerComplete(answer.questions, answer.sel)) return;
  const keys = buildKeySequence(answer.provider, answer.questions, answer.sel);
  if (!keys.length) return;
  const pending = answer;
  submitting = true;
  const ok = await send({ keys });
  submitting = false;
  // A poll may replace the picker while sending; never settle its replacement.
  if (answer !== pending) return;
  if (ok) {
    answer = null;
    $("#alert").style.display = "none";
  } else {
    renderQuestions();
  }
}

function nearBottom() {
  const el = $("#log");
  return el.scrollHeight - el.scrollTop - el.clientHeight < 140;
}

function scrollToLatest() {
  const el = $("#log");
  el.scrollTop = el.scrollHeight;
  $("#tolatest").hidden = true;
}

let awaitingReply = false;
let pendingEcho = null;

function addEcho(text) {
  const d = document.createElement("div");
  d.className = "m user pending";
  d.innerHTML = linkify(text);
  $("#log").appendChild(d);
  pendingEcho = { node: d, text: text.trim() };
}

function markEchoFailed() {
  if (!pendingEcho) return;
  const n = pendingEcho.node;
  n.classList.remove("pending");
  n.classList.add("failed");
  n.setAttribute("role", "button");
  n.setAttribute("aria-label", "Failed to send. Tap to retry.");
  pendingEcho = null;
}

let typingTimer = null;
let awaitingSince = 0;

function fmtElapsed(ms) {
  const s = Math.max(0, Math.floor(ms / 1000));
  return s < 60 ? s + "s" : Math.floor(s / 60) + "m " + (s % 60) + "s";
}

function showTyping() {
  if ($("#typing")) return;
  awaitingSince = Date.now();
  const d = document.createElement("div");
  d.className = "m assistant typing";
  d.id = "typing";
  d.setAttribute("role", "status");
  d.setAttribute("aria-label", "Agent is replying\u2026");
  d.innerHTML = '<span class="td"></span><span class="td"></span><span class="td"></span>';
  const elapsed = document.createElement("span");
  elapsed.className = "elapsed";
  d.appendChild(elapsed);
  $("#log").appendChild(d);
  clearInterval(typingTimer);
  const tick = () => { elapsed.textContent = fmtElapsed(Date.now() - awaitingSince); };
  tick();
  typingTimer = setInterval(tick, 1000);
}

function hideTyping() {
  const t = $("#typing");
  if (t) t.remove();
  clearInterval(typingTimer);
  typingTimer = null;
}

function clearPending() {
  pendingEcho = null;
  awaitingReply = false;
  hideTyping();
  setClearArmed(false);
}

// Epoch invalidates polls that began against an earlier transcript.
let logSession = null;
let logEpoch = 0;

// Tool results resolve earlier rows by tool-use id.
let toolNodes = {};

function resetTranscript() {
  logEpoch++;
  logSession = null;
  offset = 0;
  toolNodes = {};
  $("#log").innerHTML = "";
  clearPending();
}

function shortDuration(ms) {
  if (!(ms > 0)) return "";
  const seconds = Math.round(ms / 1000);
  if (seconds < 1) return "";
  if (seconds < 60) return seconds + "s";
  return Math.floor(seconds / 60) + "m " + (seconds % 60) + "s";
}

function toolRow(e) {
  const detail = e.detail && e.detail != e.text
    ? '<span class="tool-detail">' + dispLinked(e.detail) + "</span>"
    : "";
  return '<span class="tool-state" aria-hidden="true"></span>&#128295; <b>' + esc(e.tool) + "</b> " +
    dispLinked(e.text || "") + detail;
}

function resolveToolNode(entry) {
  const node = toolNodes[entry.id];
  if (!node) return;
  delete toolNodes[entry.id];
  node.el.classList.remove("running");
  node.el.classList.add(entry.failed ? "failed" : "ok");
  const started = Date.parse(node.ts || "");
  const ended = Date.parse(entry.ts || "");
  const took = shortDuration(ended - started);
  if (took) {
    const stamp = document.createElement("span");
    stamp.className = "tool-took";
    stamp.textContent = took;
    node.el.appendChild(stamp);
  }
}

async function refreshLog() {
  if (!current) return;
  const epoch = logEpoch;
  const r = await api(`/api/transcript?pid=${current}&offset=${offset}`);
  if (epoch != logEpoch) return;
  if (r.reset) {
    resetTranscript();
    return;
  }
  // Session identity catches rotation even when the new file has already surpassed the old offset.
  if (r.session != null && r.session !== logSession) {
    const rotated = logSession !== null;
    logSession = r.session;
    if (rotated) {
      resetTranscript();
      return;
    }
  }
  offset = r.offset;
  const stick = nearBottom();
  let added = 0;
  for (const e of r.entries) {
    if (e.role == "resolved") {
      resolveToolNode(e);
      continue;
    }
    if (e.role == "meta") continue;
    if (e.role == "user" && pendingEcho && e.text.trim() == pendingEcho.text) {
      pendingEcho.node.remove();
      pendingEcho = null;
    }
    if (e.role == "assistant") {
      awaitingReply = false;
      pendingEcho = null;
    }
    if (!added) hideTyping();
    const d = document.createElement("div");
    d.className = "m " + e.role;
    if (e.role == "tool") {
      d.innerHTML = toolRow(e);
      // OpenCode tools lack completion ids, so they cannot safely show an in-flight state.
      if (e.id) {
        d.classList.add("running");
        toolNodes[e.id] = { el: d, ts: e.ts };
      }
    }
    else if (e.role == "assistant") d.innerHTML = md(e.text);
    else d.innerHTML = linkify(e.text);
    $("#log").appendChild(d);
    added++;
  }
  if (awaitingReply) showTyping();
  if (added) {
    if (stick) scrollToLatest();
    else $("#tolatest").hidden = false;
  }
}

let sending = false;
// Upload and terminal send share one guard; disable every send path while either owns it.
let uploading = false;
let statusTimer = null;

function setUploading(on) {
  uploading = on;
  document.body.classList.toggle("uploading", on);
  updateComposer(agents.find(a => a.pid == current) || null);
}

function setStatus(message, kind) {
  clearTimeout(statusTimer);
  $("#status").textContent = message;
  $("#status").className = kind || "";
}

// Callers that await first pass their captured pid to prevent cross-agent delivery.
async function send(body, pid = current) {
  if (!pid || sending || uploading) return false;
  const agent = agents.find(a => a.pid == pid);
  if (!agent || !agent.writable) return false;
  sending = true;
  updateComposer(agent);
  setStatus("Sending\u2026", "sending");
  try {
    const r = await api("/api/send", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ pid, ...body }),
    });
    feedback("success");
    setStatus("Sent \u2713 via " + r.how, "success");
    // Do not update the visible log if navigation changed agents during the request.
    if (pid == current) {
      const stick = nearBottom();
      awaitingReply = true;
      showTyping();
      if (stick) scrollToLatest();
      refreshLog().catch(() => {});
    }
    return true;
  } catch (e) {
    feedback("error");
    setStatus("Couldn\u2019t send: " + e.message, "error");
    return false;
  } finally {
    sending = false;
    updateComposer(agents.find(a => a.pid == current) || null);
    statusTimer = setTimeout(() => setStatus("", ""), 4000);
  }
}

function sendText(text) {
  addEcho(text);
  awaitingReply = true;
  showTyping();
  scrollToLatest();
  send({ text }).then(ok => {
    if (!ok) {
      markEchoFailed();
      awaitingReply = false;
      hideTyping();
    }
  });
}

// Mirror server caps so invalid image replies stay editable instead of failing after upload.
const MAX_IMAGE_BYTES = 12 * 1024 * 1024;
const MAX_SEND_CHARS = 8000;

let pendingImage = null;

function uploadsSupported() {
  const a = agents.find(x => x.pid == current);
  return !!(a && a.uploads);
}

function setPendingImage(blob) {
  if (!blob || !(blob.type || "").startsWith("image/")) return;
  // Paste bypasses the capability-gated attach button.
  if (!uploadsSupported()) return;
  if (blob.size > MAX_IMAGE_BYTES) {
    feedback("error");
    setStatus("That image is too large (max 12 MB).", "error");
    return;
  }
  if (pendingImage) URL.revokeObjectURL(pendingImage.url);
  pendingImage = { blob, url: URL.createObjectURL(blob) };
  renderAttachPreview();
}

function clearPendingImage() {
  if (pendingImage) URL.revokeObjectURL(pendingImage.url);
  pendingImage = null;
  renderAttachPreview();
}

function renderAttachPreview() {
  const preview = $("#attachpreview");
  if (!pendingImage) {
    preview.hidden = true;
    preview.innerHTML = "";
    return;
  }
  preview.hidden = false;
  preview.innerHTML = '<img alt="Attached image"><button type="button" id="attachremove" ' +
    'aria-label="Remove image">&#10005;</button>';
  preview.querySelector("img").src = pendingImage.url;
}

async function uploadImage(blob) {
  const dataUrl = await new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(new Error("could not read the image"));
    reader.readAsDataURL(blob);
  });
  const r = await api("/api/upload", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ image: dataUrl }),
  });
  if (!r || !r.path) throw new Error("no path returned");
  return r.path;
}

async function submitComposer() {
  if (sending || uploading) return;
  const input = $("#msg");
  const caption = input.value.trim();
  if (!pendingImage) {
    if (!caption) return;
    input.value = "";
    resizeComposer();
    const agent = agents.find(a => a.pid == current);
    if (isSlashCommand(caption) && agent && agent.writable && agent.screen) {
      openCommandMirror(agent, caption, "Running " + caption + ": drive it with the keys below");
      return;
    }
    sendText(caption);
    return;
  }
  const pid = current;  // Bind the upload and reply to the selected agent.
  const image = pendingImage;
  pendingImage = null;
  renderAttachPreview();
  input.value = "";
  resizeComposer();
  setUploading(true);
  let echoed = false;
  try {
    const path = await uploadImage(image.blob);
    // A bare absolute path can be parsed as a slash command.
    const message = caption ? caption + " " + path : "Image: " + path;
    setUploading(false);
    if (message.length > MAX_SEND_CHARS) {
      restoreAttachment(image, caption, pid);
      feedback("error");
      setStatus("Message is too long to send with an image. Shorten it and try again.", "error");
      return;
    }
    // Echo only into the bound agent's log, using exact sent text for transcript deduplication.
    if (current == pid) {
      addEcho(message);
      echoed = true;
      awaitingReply = true;
      showTyping();
      scrollToLatest();
    }
    const ok = await send({ text: message }, pid);
    if (ok) {
      URL.revokeObjectURL(image.url);
    } else if (echoed && pendingEcho) {
      // The failed bubble retries the already-uploaded path, so the local blob is no longer needed.
      markEchoFailed();
      awaitingReply = false;
      hideTyping();
      URL.revokeObjectURL(image.url);
    } else {
      // Without a visible retry bubble, restore the attachment for a manual retry.
      restoreAttachment(image, caption, pid);
    }
  } catch (e) {
    setUploading(false);
    restoreAttachment(image, caption, pid);
    feedback("error");
    setStatus("Couldn’t upload the image: " + e.message, "error");
  }
}

// Restore only into the bound agent's shared composer; otherwise a retry could be misdelivered.
function restoreAttachment(image, caption, pid) {
  if (current != pid) {
    URL.revokeObjectURL(image.url);
    // Navigation may have disabled this footer while uploading was still true.
    updateComposer(agents.find(a => a.pid == current) || null);
    feedback("error");
    setStatus("Image not sent. Reopen that agent to try again.", "error");
    return;
  }
  pendingImage = image;
  renderAttachPreview();
  const input = $("#msg");
  if (!input.value.trim()) {
    input.value = caption;
    resizeComposer();
  }
  updateComposer(agents.find(a => a.pid == current) || null);
}

document.addEventListener("pointerdown", e => {
  const button = e.target.closest("button");
  if (button && !button.disabled) feedback("tap");
}, { passive: true });

document.addEventListener("click", async e => {
  const b = e.target.closest("button");
  if (!b) return;
  if (uploading && (b.id == "send" || b.id == "clear" || b.id == "model" || b.id == "screen" ||
      b.dataset.key || b.dataset.opt || b.dataset.submit || b.dataset.text)) return;
  if (b.id == "send") {
    submitComposer();
  } else if (b.id == "attach") {
    $("#fileinput").click();
  } else if (b.id == "attachremove") {
    clearPendingImage();
  } else if (b.id == "clear") {
    clearContext();
  } else if (b.id == "model") {
    openModelMirror(agents.find(a => a.pid == current));
  } else if (b.id == "screen") {
    openScreenMirror(agents.find(a => a.pid == current));
  } else if (b.id == "modelclose") {
    closeModelMirror();
  } else if (b.dataset.key) {
    $("#alert").style.display = "none";
    await send({ key: b.dataset.key });
    if (modelMirror) refreshModelMirror();
  } else if (b.dataset.opt) {
    toggleOption(b.dataset.opt);
  } else if (b.dataset.submit) {
    submitAnswer();
  } else if (b.dataset.text) {
    await send({ text: b.dataset.text, raw: true });
    if (modelMirror) refreshModelMirror();
  }
});

$("#log").addEventListener("click", e => {
  if (e.target.closest("a")) return;
  if (uploading) return;
  const f = e.target.closest(".m.user.failed");
  if (!f) return;
  const text = f.textContent;
  f.remove();
  feedback("tap");
  sendText(text);
});

function resizeComposer() {
  const input = $("#msg");
  if (document.querySelector(".composer").classList.contains("expanded")) {
    input.style.height = "";
    input.style.overflowY = "auto";
    return;
  }
  input.style.height = "auto";
  input.style.height = Math.min(input.scrollHeight, 200) + "px";
  input.style.overflowY = input.scrollHeight > 200 ? "auto" : "hidden";
}

$("#expand").addEventListener("click", toggleComposerExpanded);
$("#msg").addEventListener("input", resizeComposer);
$("#msg").addEventListener("keydown", e => {
  if (e.key == "Enter" && !e.isComposing && (e.metaKey || e.ctrlKey)) {
    e.preventDefault();
    $("#send").click();
  }
});

// Reset so choosing the same file after removal still fires change.
$("#fileinput").addEventListener("change", e => {
  const file = e.target.files && e.target.files[0];
  if (file) setPendingImage(file);
  e.target.value = "";
});

$("#msg").addEventListener("paste", e => {
  for (const item of (e.clipboardData && e.clipboardData.items) || []) {
    if (item.type && item.type.startsWith("image/")) {
      const blob = item.getAsFile();
      if (blob) {
        e.preventDefault();
        setPendingImage(blob);
        return;
      }
    }
  }
});

const footer = $("footer");
new ResizeObserver(() => {
  const stick = nearBottom();
  document.documentElement.style.setProperty("--footer-height", footer.offsetHeight + "px");
  if (stick) scrollToLatest();
}).observe(footer);
resizeComposer();

$("#ddbtn").addEventListener("click", e => {
  e.stopPropagation();
  $("#dd").classList.toggle("open");
});
document.addEventListener("click", () => $("#dd").classList.remove("open"));
$("#tolatest").addEventListener("click", scrollToLatest);
$("#log").addEventListener("scroll", () => {
  if (nearBottom()) $("#tolatest").hidden = true;
}, { passive: true });

$("#enablealerts").addEventListener("click", async () => {
  try {
    await Notification.requestPermission();
  } catch (e) {}
  updateAlertsButton();
});

$("#privacytoggle").addEventListener("click", () => {
  privacyMode = !privacyMode;
  feedback("tap");
  document.body.classList.toggle("privacy", privacyMode);
  const button = $("#privacytoggle");
  button.setAttribute("aria-pressed", String(privacyMode));
  button.setAttribute("aria-label", privacyMode ? "Show agent names" : "Hide agent names");
  button.title = privacyMode ? "Show agent names" : "Hide agent names";
  renderAgents();
  if (lastUsage) renderUsage(lastUsage);
});

// Persist before reloading because an installed PWA may discard the new fragment at start_url.
function connectWith(host, token) {
  try {
    localStorage.setItem(CONN_KEY, JSON.stringify({ host, token }));
  } catch (e) {}
  const parts = host ? ["host=" + encodeURIComponent(host)] : [];
  parts.push("token=" + encodeURIComponent(token));
  location.hash = parts.join("&");
  location.reload();
}

function manualConnect() {
  const host = $("#manualhost").value.trim().replace(/^https?:\/\//i, "").replace(/\/+$/, "");
  const token = $("#manualtoken").value.trim();
  if (!token) {
    feedback("error");
    $("#pairstatus").textContent = "Enter the connection token from Toki.";
    return;
  }
  try {
    remoteAPIBase(host);
  } catch (e) {
    feedback("error");
    $("#pairstatus").textContent = "Enter your Mac\u2019s Tailscale host, like name.tailnet.ts.net.";
    return;
  }
  connectWith(host, token);
}

// Drop both persisted and URL state; replace also keeps the tokened URL out of history.
function goHome() {
  try {
    localStorage.removeItem(CONN_KEY);
  } catch (e) {}
  clearSession();
  location.replace(location.pathname);
}

function showDisconnectConfirm() {
  $("#confirm").hidden = false;
  $("#confirmcancel").focus();
}

function hideDisconnectConfirm() {
  $("#confirm").hidden = true;
  $("#home").focus();
}

$("#home").addEventListener("click", showDisconnectConfirm);
$("#confirmcancel").addEventListener("click", hideDisconnectConfirm);
$("#confirmok").addEventListener("click", () => {
  hideDisconnectConfirm();
  goHome();
});
$("#confirm").addEventListener("click", e => {
  if (e.target.id == "confirm") hideDisconnectConfirm();
});
// Trap focus inside the modal.
$("#confirm").addEventListener("keydown", e => {
  if (e.key == "Tab") {
    const first = $("#confirmcancel");
    const last = $("#confirmok");
    if (e.shiftKey && document.activeElement == first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && document.activeElement == last) {
      e.preventDefault();
      first.focus();
    }
  }
});
document.addEventListener("keydown", e => {
  if (e.key == "Escape" && !$("#confirm").hidden) hideDisconnectConfirm();
});
$("#pairhome").addEventListener("click", goHome);

$("#manualconnect").addEventListener("click", manualConnect);
[$("#manualhost"), $("#manualtoken")].forEach(el => el.addEventListener("keydown", e => {
  if (e.key == "Enter") {
    e.preventDefault();
    manualConnect();
  }
}));

const CAN_SCAN = !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia && window.isSecureContext);
$("#scanbtn").hidden = !CAN_SCAN;
$("#scanor").hidden = !CAN_SCAN;

let scanStream = null;
let scanRAF = null;
let scanDetector = null;
let jsqrPromise = null;
let lastScanValue = "";
let lastScanAt = 0;
let scanErrTimer = null;
const scanCanvas = document.createElement("canvas");

function loadJsQR() {
  if (window.jsQR) return Promise.resolve();
  if (!jsqrPromise) jsqrPromise = new Promise((res, rej) => {
    const s = document.createElement("script");
    s.src = "jsqr.js";
    s.onload = res;
    s.onerror = () => rej(new Error("load failed"));
    document.head.appendChild(s);
  });
  return jsqrPromise;
}

async function openScanner() {
  const video = $("#scanvideo");
  $("#scanstatus").textContent = "";
  $("#scanner").hidden = false;
  try {
    scanStream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: "environment" } } });
    video.srcObject = scanStream;
    await video.play();
  } catch (e) {
    $("#scanstatus").textContent = e.name == "NotAllowedError"
      ? "Allow camera access, then tap Scan again."
      : "Couldn\u2019t open the camera: " + e.message;
    return;
  }
  if ("BarcodeDetector" in window) {
    try {
      scanDetector = new BarcodeDetector({ formats: ["qr_code"] });
    } catch (e) {
      scanDetector = null;
    }
  }
  if (!scanDetector) {
    try {
      await loadJsQR();
    } catch (e) {
      $("#scanstatus").textContent = "Couldn\u2019t load the scanner. Check your connection and retry.";
      return;
    }
  }
  scanRAF = requestAnimationFrame(scanTick);
}

function closeScanner() {
  if (scanRAF) cancelAnimationFrame(scanRAF);
  scanRAF = null;
  if (scanStream) {
    scanStream.getTracks().forEach(t => t.stop());
    scanStream = null;
  }
  $("#scanvideo").srcObject = null;
  $("#scanner").hidden = true;
  scanDetector = null;
}

function decodeFrame(video) {
  if (scanDetector) return scanDetector.detect(video).then(c => c.length ? c[0].rawValue : null).catch(() => null);
  if (!window.jsQR) return Promise.resolve(null);
  const w = video.videoWidth;
  const h = video.videoHeight;
  scanCanvas.width = w;
  scanCanvas.height = h;
  const ctx = scanCanvas.getContext("2d", { willReadFrequently: true });
  ctx.drawImage(video, 0, 0, w, h);
  const img = ctx.getImageData(0, 0, w, h);
  const code = window.jsQR(img.data, w, h, { inversionAttempts: "dontInvert" });
  return Promise.resolve(code ? code.data : null);
}

async function scanTick() {
  if (!scanStream) return;
  const video = $("#scanvideo");
  if (video.readyState >= 2 && video.videoWidth) {
    let value = null;
    try {
      value = await decodeFrame(video);
    } catch (e) {}
    if (value && !(value == lastScanValue && Date.now() - lastScanAt < 2500)) {
      lastScanValue = value;
      lastScanAt = Date.now();
      handleScan(value);
    }
  }
  if (scanStream) scanRAF = requestAnimationFrame(scanTick);
}

function scanError(msg) {
  $("#scanstatus").textContent = msg;
  feedback("error");
  clearTimeout(scanErrTimer);
  scanErrTimer = setTimeout(() => {
    $("#scanstatus").textContent = "";
  }, 2600);
}

// Accept hosted links naming a Mac in their fragment and direct links to the Mac itself.
function resolveScanLink(value, pageURL) {
  let pageOrigin = "";
  try {
    pageOrigin = new URL(pageURL).origin;
  } catch (e) {}
  let target;
  try {
    target = new URL(value, pageURL);
  } catch (e) {
    return { error: "That QR code isn\u2019t a Toki link." };
  }
  const params = new URLSearchParams(target.hash.slice(1) || target.search);
  const token = params.get("token");
  if (!token) return { error: "That QR code isn\u2019t a Toki Remote Control link." };
  const named = (params.get("host") || "").trim();
  if (named)
    return isTailscaleHost(named)
      ? { host: named, token }
      : { error: "That link\u2019s address isn\u2019t a Tailscale name. Open Connect in Toki and scan its current code." };
  // Cross-origin HTTPS pages can reach only the Tailscale form, not a plain-HTTP LAN link.
  if (pageOrigin && target.origin == pageOrigin) return { host: "", token };
  if (isTailscaleHost(target.hostname)) return { host: target.hostname, token };
  return { error: "This page can\u2019t reach " + target.hostname + ". Open that link directly on this device, or switch Toki\u2019s host to Tailscale." };
}

function handleScan(value) {
  const link = resolveScanLink(value, location.href);
  if (link.error) return scanError(link.error);
  feedback("success");
  closeScanner();
  connectWith(link.host, link.token);
}

$("#scanbtn").addEventListener("click", openScanner);
$("#scancancel").addEventListener("click", closeScanner);
document.addEventListener("visibilitychange", () => {
  if (document.hidden && scanStream) closeScanner();
});

if ("serviceWorker" in navigator && window.isSecureContext)
  window.addEventListener("load", () => navigator.serviceWorker.register("sw.js").catch(() => {}));

if (CONFIG_ERROR)
  invalidLink("This link has an invalid server address. Open Connect in Toki and use a new link.");
else if (!LINK_TOKEN)
  invalidLink("This page needs a private link from Toki. Open Remote Control settings on your Mac, then choose Connect.");
else if (TOKEN) startApp();
else lockApp();
