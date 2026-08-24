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
};

function providerLogo(p) {
  if (p == "claude" || p == "claudeCode" || p == "anthropic") return LOGOS.claude;
  if (p == "codex" || p == "openai" || p == "chatgpt") return LOGOS.codex;
  if (p == "opencode" || p == "openCode") return LOGOS.opencode;
  if (p == "antigravity") return LOGOS.antigravity;
  if (p == "fx") return LOGOS.fx;
  return '<svg class="plogo" viewBox="0 0 24 24" fill="#888"><circle cx="12" cy="12" r="8"/></svg>';
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
  // agent.screen gates the button off for older servers that lack /api/screen to mirror the picker.
  $("#model").hidden = !(writable && agent && agent.screen && MODEL_COMMANDS[agent.provider]);
  if (!writable || (modelMirror && (!agent || modelMirror.pid != agent.pid))) closeModelMirror();
  document.querySelectorAll("footer button,footer input,footer textarea").forEach(el => el.disabled = !enabled);
  $("#msg").placeholder = writable ? "Reply to the agent\u2026" : (agent ? "Read-only session" : "No active session");
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
  opencode: "/models",
  fx: "/model",
  antigravity: "/model",
};

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
    if (r.ok && r.text) pre.textContent = r.text;
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

function openModelMirror(agent) {
  const cmd = agent && MODEL_COMMANDS[agent.provider];
  if (!cmd) return;
  closeModelMirror();
  // Fire the CLI's own model command, then mirror the picker it opens on the terminal.
  send({ text: cmd });
  modelMirror = { pid: agent.pid, inflight: false };
  $("#modelmirror").hidden = false;
  $("#modelscreen").textContent = "Opening " + cmd + "…";
  modelMirror.timer = setTimeout(refreshModelMirror, 450);
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
  if (uploading && (b.id == "send" || b.id == "clear" || b.id == "model" ||
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
  input.style.height = "auto";
  input.style.height = Math.min(input.scrollHeight, 200) + "px";
  input.style.overflowY = input.scrollHeight > 200 ? "auto" : "hidden";
}

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
