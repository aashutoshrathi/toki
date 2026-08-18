// Fragments keep the token out of static-host access logs. Query params remain supported for
// links created from the original hosting plan.
const PARAMS = new URLSearchParams(location.hash.slice(1) || location.search);

// An installed PWA relaunches at start_url with no fragment; fall back to the last connection so
// it reopens on the verify screen (or resumes) instead of the invalid-link screen.
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

// Save whenever we have a link token, even with no host: the direct same-host flow serves the
// PWA from the Mac's own origin, so an empty host restores to the same origin on relaunch.
let connSaved = false;
if (LINK_TOKEN && !CONFIG_ERROR) {
  try {
    localStorage.setItem(CONN_KEY, JSON.stringify({ host: REMOTE_HOST, token: LINK_TOKEN }));
    connSaved = true;
  } catch (e) {}
}

// The link token has been read and remembered, so take it back out of the address bar: on a phone
// that URL is on screen, in history, and in whatever the browser syncs. Only once the connection
// is safely in localStorage -- with storage unavailable, the address bar is the only copy left and
// a reload would have nothing to come back to.
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

// The session lives in localStorage, not sessionStorage: sessionStorage dies with the tab (a
// closed browser, or iOS discarding a backgrounded tab), which used to sign the device out. The
// stored expiry matches what /api/pair granted; a revoke on the Mac still ends it immediately.
function loadSession() {
  let raw = null;
  try {
    raw = localStorage.getItem(SESSION_KEY);
  } catch (e) {}
  if (!raw) {
    // An older build kept the session in sessionStorage, which the tab discards; move it across so
    // upgrading doesn't sign the device out. Keep the old copy if the write fails.
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
  // /api/pair reports the lifetime it granted; without it the token is kept until the server
  // rejects it.
  if (expiresInSeconds > 0) record.expires = Date.now() + expiresInSeconds * 1000;
  try {
    localStorage.setItem(SESSION_KEY, JSON.stringify(record));
  } catch (e) {}
}

function clearSession() {
  try {
    localStorage.removeItem(SESSION_KEY);
  } catch (e) {}
  // Older builds kept it here; clear both so an upgrade cannot leave a stale copy behind.
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

// Same masking, but for a textContent assignment: no HTML escaping, or names would show entities.
function plainTitle(t) {
  return privacyMode ? maskText(t) : (t || "");
}

// The folder an agent is working in, masked alongside its title so the privacy toggle doesn't
// leave your project names on screen.
function dispPath(p) {
  if (!p) return "";
  return privacyMode ? maskText(p) : esc(p);
}

// For the text of a tool row, which is often the URL the call is fetching. Masking still wins:
// a masked row has nothing left worth linking.
function dispLinked(t) {
  return privacyMode ? maskText(t) : linkify(t);
}

// The session token rides in the Authorization header rather than the query string, so it stays
// out of the phone's history and out of the request line any proxy in front of the Mac writes to
// its log -- Cloudflare's, on the tunnel path.
//
// Servers before 2.6.0 read the token only from the query string. This page is also served from
// rc.toki.aashutosh.dev, which updates the moment a release lands while the Mac it talks to
// updates whenever its owner gets round to it, so the two versions have to meet. Try the header,
// and on the one status an old server answers with, fall back and remember for the session.
// null until proven, then "header" or "query" for the rest of the session.
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

// Settle the question with a GET, before it can be asked with something that types into a
// terminal. A server predating the header refuses it two different ways: cross-origin it is
// preflighted and the browser blocks the call outright, with no response to read a status from;
// same-origin the request goes through and comes back 403, because the token was never seen.
// Treat both as a reason to try the query string.
async function resolveTokenTransport() {
  if (tokenTransport) return tokenTransport;
  try {
    const probe = await tokenedRequest("/api/agents", undefined, false);
    // Anything other than a refusal means the header was read, whatever else went wrong.
    if (probe.status != 403) {
      tokenTransport = "header";
      return tokenTransport;
    }
  } catch (blocked) {
    // Preflight rejected. Nothing to inspect; fall through and try the older shape.
  }
  try {
    const probe = await tokenedRequest("/api/agents", undefined, true);
    if (probe.ok) {
      tokenTransport = "query";
      return tokenTransport;
    }
  } catch (unreachable) {
    // Neither shape got through.
  }
  // No evidence either way: an expired token refused both ways, or the Mac is unreachable. Latch
  // nothing, and let the caller's own request produce the real error. Deciding here on a dropped
  // connection would put the token back in URLs for the rest of the session.
  return "header";
}

// The agent and transcript polls both start at once, so share one probe between them rather than
// asking twice.
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
  // Never retry the caller's request. A reply, an approval key and /clear are all delivered to
  // the terminal before the response is written, so a retry after a lost answer types them a
  // second time. The probe above is a GET and is the only thing repeated.
  const transport = await tokenTransportOnce();
  const r = await tokenedRequest(p, o, transport === "query");
  if (!r.ok) {
    const detail = await r.text();
    // A 403 also means "wrong Wi-Fi": the host setting refuses networks it was not meant to answer,
    // which fixes itself. Only a token the Mac rejects should end the session.
    if (r.status == 403 && detail.includes("bad token")) lockApp();
    throw new Error(detail);
  }
  return r.json();
}

function lockApp() {
  TOKEN = "";
  clearSession();
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

// Quota, from the same reading the menu bar shows: one line by default, the whole list when asked.
let usageOpen = false;
let lastUsage = null;

// Red is the low-quota notification threshold (lowQuotaThreshold, 20% by default), so the strip and
// the alerts agree on "low"; amber is the warning before it.
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
  // The summary line is the account with least left, because that is the one about to bite.
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
  // Stale shows in the collapsed strip too, not only the expanded panel, or a reading the Mac
  // stopped refreshing would look current until the user opened it.
  const stale = !!(data && data.stale);
  $("#usagesummary").textContent = stale ? summary + " · may be out of date" : summary;
  toggle.classList.toggle("stale", stale);
  toggle.setAttribute("aria-expanded", usageOpen ? "true" : "false");
  panel.hidden = !usageOpen;
  if (!usageOpen) return;

  panel.innerHTML = accounts.map(a => {
    const name = '<span class="u-name">' + dispTitle(a.name) + "</span>";
    if (typeof a.remaining != "number") {
      // No quota API, or a cost figure instead: show the figure, not a bar for a number nobody has.
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
  // Quota moves in minutes, not seconds; polling it like a transcript would be noise.
  setInterval(pollUsage, 20000);
}

$("#usagetoggle").addEventListener("click", () => {
  usageOpen = !usageOpen;
  feedback();
  refreshUsage();
});

// A backgrounded tab has its timers throttled, so it showed stale state until the next tick. Poll
// the moment it is visible again.
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
// Escapes and links in one step, for the messages that are not Markdown. Every caller assigns the
// result to innerHTML, so nothing may reach it that has not been through here or esc().
const linkify = renderMarkdown.linkify;

const LOGOS = {
  claude: '<svg class="plogo" viewBox="0 0 100 100" fill="#d97757"><path d="m19.6 66.5 19.7-11 .3-1-.3-.5h-1l-3.3-.2-11.2-.3L14 53l-9.5-.5-2.4-.5L0 49l.2-1.5 2-1.3 2.9.2 6.3.5 9.5.6 6.9.4L38 49.1h1.6l.2-.7-.5-.4-.4-.4L29 41l-10.6-7-5.6-4.1-3-2-1.5-2-.6-4.2 2.7-3 3.7.3.9.2 3.7 2.9 8 6.1L37 36l1.5 1.2.6-.4.1-.3-.7-1.1L33 25l-6-10.4-2.7-4.3-.7-2.6c-.3-1-.4-2-.4-3l3-4.2L28 0l4.2.6L33.8 2l2.6 6 4.1 9.3L47 29.9l2 3.8 1 3.4.3 1h.7v-.5l.5-7.2 1-8.7 1-11.2.3-3.2 1.6-3.8 3-2L61 2.6l2 2.9-.3 1.8-1.1 7.7L59 27.1l-1.5 8.2h.9l1-1.1 4.1-5.4 6.9-8.6 3-3.5L77 13l2.3-1.8h4.3l3.1 4.7-1.4 4.9-4.4 5.6-3.7 4.7-5.3 7.1-3.2 5.7.3.4h.7l12-2.6 6.4-1.1 7.6-1.3 3.5 1.6.4 1.6-1.4 3.4-8.2 2-9.6 2-14.3 3.3-.2.1.2.3 6.4.6 2.8.2h6.8l12.6 1 3.3 2 1.9 2.7-.3 2-5.1 2.6-6.8-1.6-16-3.8-5.4-1.3h-.8v.4l4.6 4.5 8.3 7.5L89 80.1l.5 2.4-1.3 2-1.4-.2-9.2-7-3.6-3-8-6.8h-.5v.7l1.8 2.7 9.8 14.7.5 4.5-.7 1.4-2.6 1-2.7-.6-5.8-8-6-9-4.7-8.2-.5.4-2.9 30.2-1.3 1.5-3 1.2-2.5-2-1.4-3 1.4-6.2 1.6-8 1.3-6.4 1.2-7.9.7-2.6v-.2H49L43 72l-9 12.3-7.2 7.6-1.7.7-3-1.5.3-2.8L24 86l10-12.8 6-7.9 4-4.6-.1-.5h-.3L17.2 77.4l-4.7.6-2-2 .2-3 1-1 8-5.5Z"/></svg>',
  codex: '<svg class="plogo" viewBox="0 0 250 250" fill="#7a9dff"><path d="m84.3 5.1q3.7-1.5 7.7-2.6 3.9-1 7.9-1.6 4-0.5 8.1-0.6 4 0 8 0.5 20.7 2.4 37.1 17.7 0.1 0.1 0.4 0.3 0.1 0 0.2 0 0 0 0.2 0 0 0 0.1 0 0 0 0.1 0 5.2-1.4 10.7-1.9 5.4-0.4 10.7 0.1 5.5 0.4 10.7 1.9 5.2 1.3 10.1 3.6l0.6 0.4 1.6 0.8q5.2 2.5 9.7 6.1 4.7 3.4 8.6 7.7 3.8 4.3 6.9 9.2 3 4.8 5.2 10.2 4.3 10.5 4.3 22.1 0.2 2.1 0 4.2-0.1 2.2-0.2 4.3-0.3 2.1-0.7 4.3-0.4 2.1-0.9 4.1 0 0.2 0 0.4 0 0.2 0 0.5 0 0.1 0.1 0.4 0.1 0.1 0.3 0.3 12.3 12.6 16.3 30 6 29.7-12.2 53.5l-1.9 2.2q-3 3.5-6.5 6.4-3.4 3.1-7.3 5.5-3.8 2.4-8.1 4.2-4.1 1.9-8.5 3.2-0.3 0-0.4 0.2-0.3 0-0.4 0.1-0.1 0.1-0.3 0.4 0 0.1-0.1 0.3c-2.7 7.7-5.3 14.2-10.2 20.7-12.5 16.5-30.8 25.5-51.5 25.5q-24.6-0.1-43.6-18.1-0.2-0.1-0.4-0.2-0.2-0.1-0.4-0.1-0.2 0-0.3 0-0.3 0-0.4 0c-5.4 1.7-10.9 1.9-16.7 1.9q-3.5 0-7-0.5-3.4-0.4-6.9-1.2-3.3-0.8-6.6-2-3.3-1.2-6.4-2.8-3.3-1.6-6.4-3.6-3-2-5.8-4.3-3-2.3-5.5-5-2.5-2.6-4.6-5.6c-2.2-2.7-4.3-5.4-5.8-8.5q-0.8-1.6-1.6-3.2-0.6-1.7-1.3-3.3-0.7-1.7-1.2-3.4-0.5-1.6-1-3.4-1.1-4-1.6-7.9-0.6-4-0.6-8 0-4 0.6-8 0.4-4 1.4-8 0 0 0-0.1 0-0.1 0-0.1 0.2-0.2 0.2-0.3 0-0.1-0.2-0.1 0-0.2 0-0.3 0-0.1-0.1-0.1 0-0.2 0-0.2-0.1-0.1-0.1-0.1-2.4-2.5-4.6-5.2-2.1-2.7-4-5.4-1.7-3-3.2-6-1.5-3.1-2.6-6.3-0.8-2-1.3-4.1-0.7-2-1.1-4-0.4-2.1-0.7-4.2-0.2-2.2-0.4-4.3-0.2-2.8-0.1-5.6 0-2.8 0.3-5.4 0.1-2.8 0.6-5.6 0.4-2.8 1.1-5.5 7-23.1 26.9-36.3 4.3-2.9 8.2-4.5 4.5-1.9 9-3.2 0.2 0 0.3-0.1 0.1-0.2 0.3-0.3 0.1 0 0.1-0.3 0.1-0.1 0.1-0.2 1-3.1 2.2-6 1-2.9 2.5-5.7 1.5-3 3.2-5.6 1.7-2.7 3.7-5.1 2.5-3.2 5.3-5.9 3-2.8 6.1-5.4 3.2-2.4 6.8-4.4 3.5-2 7.2-3.5zm48.3 146.4c-2.3 0.1-4.4 1-6 2.8-1.5 1.6-2.4 3.7-2.4 5.9 0 2.3 0.9 4.4 2.4 6.2 1.6 1.6 3.7 2.5 6 2.6h50.4c2.4 0.1 4.8-0.6 6.5-2.4 1.7-1.6 2.8-4 2.8-6.4 0-2.4-1.1-4.7-2.8-6.3-1.7-1.8-4.1-2.6-6.5-2.4zm-56.7-64.9c-1.2-1.9-3-3.4-5.3-3.9-2.2-0.5-4.5-0.3-6.5 0.9-2 1.1-3.5 3-4.1 5.2-0.7 2.2-0.4 4.6 0.6 6.5l17.7 30.9-17.5 29.5c-1.2 2-1.6 4.5-1.1 6.8 0.7 2.3 2.1 4.1 4.1 5.3 2 1.2 4.4 1.6 6.7 0.9 2.2-0.5 4.2-1.9 5.4-3.9l20.1-34.1q0.7-0.9 0.9-2.1 0.3-1.1 0.3-2.3 0-1.2-0.3-2.2-0.2-1.2-0.8-2.2z"/></svg>',
  opencode: '<svg class="plogo" viewBox="0 0 240 300"><rect x="60" y="60" width="120" height="180" fill="#f1ecec"/><rect x="60" y="120" width="120" height="120" fill="#4b4646"/></svg>',
};

function providerLogo(p) {
  if (p == "claude" || p == "claudeCode" || p == "anthropic") return LOGOS.claude;
  if (p == "codex" || p == "openai" || p == "chatgpt") return LOGOS.codex;
  if (p == "opencode" || p == "openCode") return LOGOS.opencode;
  return '<svg class="plogo" viewBox="0 0 24 24" fill="#888"><circle cx="12" cy="12" r="8"/></svg>';
}

// Two lines: the chat's title, and under it the folder the agent is running in. Several agents
// often share a title (or carry none worth reading), and the folder is what actually tells them
// apart, so it belongs on the row you pick from rather than a screen away.
function agentRow(a) {
  const path = dispPath(a.path);
  return providerLogo(a.provider) +
    '<span class="t">' +
    '<span class="tl">' + (a.attention ? '<span class="dot">\u25cf</span> ' : "") + dispTitle(a.title) + "</span>" +
    (path ? '<span class="tp">' + path + "</span>" : "") +
    "</span>";
}

function renderAgents() {
  const btn = $("#ddbtn");
  const list = $("#ddlist");
  if (!agents.length) {
    btn.innerHTML = '<span class="t">no agents found</span>';
    list.innerHTML = "";
    updateComposer(null);
    return;
  }
  const cur = agents.find(a => a.pid == current) || agents[0];
  btn.innerHTML = agentRow(cur) + '<span class="caret">\u25be</span>';
  updateComposer(cur);
  // The server hands agents back writable-first, so the read-only ones are a single run at the
  // end. Label that run once, where it starts, rather than badging every row in it.
  list.innerHTML = agents.map((a, i) => {
    const startsReadOnly = !a.writable && (i == 0 || agents[i - 1].writable);
    return (startsReadOnly ? '<div class="ddgroup">Read-only</div>' : "") +
      '<div class="dditem' + (a.pid == current ? " sel" : "") + '" data-pid="' + a.pid + '">' + agentRow(a) + "</div>";
  }).join("");
  list.querySelectorAll(".dditem").forEach(el => el.onclick = ev => {
    ev.stopPropagation();
    current = +el.dataset.pid;
    resetTranscript();
    document.getElementById("dd").classList.remove("open");
    renderAgents();
    refreshLog();
  });
}

function updateComposer(agent) {
  const writable = !!(agent && agent.writable);
  const enabled = writable && !sending && !uploading;
  $("#readonly").style.display = agent && !writable ? "block" : "none";
  document.querySelectorAll("footer button,footer input,footer textarea").forEach(el => el.disabled = !enabled);
  $("#msg").placeholder = writable ? "Reply to the agent\u2026" : (agent ? "Read-only session" : "No active session");
}

// Clearing an agent's context cannot be undone, and this button sits a thumb's width from Send on
// a phone. So the first tap only arms it; the second one within a few seconds actually sends.
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
  // No optimistic echo: /clear is a command to the agent, not a message in the conversation, and
  // the transcript it belongs to is about to be replaced. Drop the log as soon as the command is
  // away rather than waiting to be told, so the conversation you just cleared doesn't linger.
  send({ text: "/clear" }).then(ok => {
    if (ok) resetTranscript();
  });
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
  }
  renderAgents();
  renderAttention(agents.find(x => x.pid == current));
}

// A picker the phone is answering: the provider whose TUI the keystrokes have to drive, the
// questions, and the option indices chosen for each. Kept across polls so a selection survives the
// alert being rebuilt, and reset (in renderAttention) when the pending question changes.
let answer = null;

// The pid is in the signature so switching to another agent whose question happens to read the same
// never carries the first agent's selections onto -- and then submits them to -- the second. Built
// with JSON.stringify rather than joined delimiters so a header or label that happens to contain a
// separator character cannot make two different pickers collide onto one signature.
function questionSignature(pid, provider, qs) {
  return JSON.stringify([pid, provider, qs.map(q =>
    [q.header || "", q.question || "", q.multi ? 1 : 0, (q.options || []).map(o => o.label)])]);
}

// Older servers describe a question's options as bare strings (under `options`, or inside the
// `questions` array a pre-2.7.1 server still sends); normalise both shapes so the renderer only
// ever deals with {label, description}.
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
  const al = $("#alert");
  if (!a || !a.attention) {
    answer = null;
    al.style.display = "none";
    return;
  }
  al.style.display = "block";
  al.className = a.attention.kind == "question" ? "q" : "";
  if (a.attention.kind != "question") {
    answer = null;
    al.innerHTML = '<div class="ahead">Needs your approval</div>' +
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

// A lone single-select question keeps the old one-tap behaviour: tapping an option is the answer,
// with no separate Submit step. Anything with a multi-select or a second question needs the panel
// to stay open while choices accumulate.
function isQuickPick(qs) {
  return qs.length == 1 && !qs[0].multi;
}

// Every question that actually offers options needs one chosen before the answer can go. An
// option-less question (malformed, or a free-text-only prompt) is not gated on, or its picker could
// never be submitted at all.
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
      // role + aria-checked so a screen reader announces each option as a checkbox/radio and reads
      // its on/off state, which the tick or dot conveys only visually.
      html += `<button class="opt${on ? " on" : ""}" data-opt="${qi}:${oi}" ` +
        `role="${q.multi ? "checkbox" : "radio"}" aria-checked="${on}">` +
        `<span class="mark ${q.multi ? "box" : "radio"}" aria-hidden="true"></span>` +
        `<span class="olab"><b>${esc(o.label)}</b>` +
        (o.description ? `<em>${esc(o.description)}</em>` : "") + "</span></button>";
    });
  });
  if (!isQuickPick(qs)) {
    // Submit stays disabled until every answerable question has a pick: an unanswered one is
    // otherwise dropped (Claude) or silently sent as its first option (OpenCode's buildKeySequence).
    html += '<div class="decision-row one"><button class="decision approve" data-submit="1"' +
      (answerComplete(qs, sel) ? "" : " disabled") + ">Submit</button></div>";
  }
  $("#alert").innerHTML = html;
}

function toggleOption(spec) {
  // Ignore taps mid-submit: the keystrokes were computed from the selection as it was, so letting it
  // change now would show a set the terminal never received, and the tap could not re-submit anyway.
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

// Translate the accumulated selections into the exact keypresses each TUI needs. The two pickers
// diverge, so this is the one place that knows how:
//
//   OpenCode's `question` tool: arrows move the highlight, Enter toggles a multi-select option and
//   Tab moves to the next question; a single-select's Enter both selects and advances. A final tab
//   lands on the "Confirm" step, where Enter submits. (Confirmed against OpenCode's TUI.)
//
//   Claude's AskUserQuestion: number keys pick options directly, so a single-select's number is the
//   whole answer, a multi-select toggles each number then Enter confirms, and Tab moves between
//   questions in a multi-question prompt.
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
    } else {
      // A single digit per option: only the number path (Claude) reaches here, and its picker caps
      // at a handful of options, so the index never needs two digits -- which /api/send would reject
      // as a key anyway. OpenCode, the one provider that can list many options, navigates by arrow.
      chosen.forEach(i => keys.push(String(i + 1)));
      if (qi < last) keys.push("tab");
    }
  });
  // OpenCode shows a Confirm step whenever there is more than one question or any multi-select;
  // land on it and submit. A lone single-select has already submitted on its Enter.
  if (provider == "opencode" && (questions.length > 1 || anyMulti)) keys.push("enter");
  // Claude submits a multi-question or multi-select prompt with a closing Enter; a lone
  // single-select was answered by its number alone.
  else if (provider != "opencode" && !isQuickPick(questions)) keys.push("enter");
  return keys;
}

let submitting = false;

async function submitAnswer() {
  if (!answer || submitting) return;
  // Never deliver a partial answer, whatever state the Submit button is in: an unanswered question
  // would be dropped or sent as a default.
  if (!answerComplete(answer.questions, answer.sel)) return;
  const keys = buildKeySequence(answer.provider, answer.questions, answer.sel);
  if (!keys.length) return;
  // Hold the selection until the send is known to have landed. If it fails, the panel stays with
  // every pick intact rather than making the user rebuild the whole answer from scratch.
  const pending = answer;
  submitting = true;
  const ok = await send({ keys });
  submitting = false;
  // A poll (or an agent switch) may have swapped in a different picker while the send was in flight.
  // Only clear or re-render the exact one we submitted, never whatever took its place.
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
  // Linked here as well as when the transcript echoes it back, so a message does not change
  // appearance under you the moment the agent confirms it.
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

function showTyping() {
  if ($("#typing")) return;
  const d = document.createElement("div");
  d.className = "m assistant typing";
  d.id = "typing";
  d.setAttribute("role", "status");
  d.setAttribute("aria-label", "Agent is replying\u2026");
  d.innerHTML = '<span class="td"></span><span class="td"></span><span class="td"></span>';
  $("#log").appendChild(d);
}

function hideTyping() {
  const t = $("#typing");
  if (t) t.remove();
}

function clearPending() {
  pendingEcho = null;
  awaitingReply = false;
  hideTyping();
  setClearArmed(false);
}

// Which transcript the offset below counts into, and how many times we've thrown that offset away.
// A poll that was already in flight when the transcript changed carries an offset into a log that
// no longer exists, so it has to be dropped instead of appended.
let logSession = null;
let logEpoch = 0;

// Tool calls arrive before their results, so the row has to be found again when the result turns
// up. Keyed by the tool_use id the transcript already carries.
let toolNodes = {};

function resetTranscript() {
  logEpoch++;
  logSession = null;
  offset = 0;
  toolNodes = {};
  $("#log").innerHTML = "";
  clearPending();
}

// Whole seconds up to a minute, then minutes: a tool call's duration is interesting at a glance,
// not to three decimal places.
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

// The result carries no output, only that the call ended, when, and whether it failed: enough to
// stop a finished call looking like one still running.
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
  // The server names the transcript this offset belongs to. When that name changes the agent has
  // moved to a new session (/clear, or a new conversation started on the Mac) and the offset we
  // hold points into a file that is gone -- start over rather than parse one file at another's
  // position. The size check the server does catches this only while the new transcript is still
  // shorter than the old offset.
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
    // The agent echoes back the message we optimistically showed; drop the placeholder so it isn't doubled.
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
      // Only spin what can stop spinning: OpenCode tools carry no id and no completion, so marking
      // them running would leave every finished call in flight forever.
      if (e.id) {
        d.classList.add("running");
        toolNodes[e.id] = { el: d, ts: e.ts };
      }
    }
    else if (e.role == "assistant") d.innerHTML = md(e.text);
    // Your own messages stay verbatim -- no Markdown, and the bubble's pre-wrap keeps the line
    // breaks -- but a URL in one is as worth tapping as a URL in a reply.
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
// True only while an image is being read and uploaded, before its reply is sent. Every send-capable
// control is disabled through it: the footer via updateComposer, and the alert panel's approve and
// answer buttons via the body class, so answering another agent's prompt cannot collide with the
// image's own send (which shares the single `sending` guard) and wrongly fail it.
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

// `pid` defaults to the current agent, but a caller that awaited something first (an image upload)
// passes the agent it was bound to when the user pressed Send, so switching agents mid-flight cannot
// misdeliver the message.
async function send(body, pid = current) {
  // `uploading` blocks every send too: an image upload shares this single in-flight guard, and a
  // send that slipped in while it was reading would occupy the slot and fail the image's own send.
  // The image path calls send() only after clearing `uploading`, so it is never blocked by this.
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
    // The typing indicator and transcript refresh belong to the log on screen. When this send was
    // bound to an agent the user has since navigated away from, they belong to that other agent's
    // view, not the one now showing, so leave the current view alone.
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

// The client cap matches the server's, so an image too big to accept is refused before the upload
// rather than after. A camera shot or a screenshot is comfortably under this.
const MAX_IMAGE_BYTES = 12 * 1024 * 1024;
// Mirrors the server's per-message cap, so a caption long enough that appending the image path would
// overflow it is caught here, with the attachment kept, rather than 413'd into a failed bubble.
const MAX_SEND_CHARS = 8000;

// An image chosen (picker/camera) or pasted, waiting to go out with the next Send. One at a time.
let pendingImage = null;

function setPendingImage(blob) {
  if (!blob || !(blob.type || "").startsWith("image/")) return;
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
  const p = $("#attachpreview");
  if (!pendingImage) {
    p.hidden = true;
    p.innerHTML = "";
    return;
  }
  p.hidden = false;
  p.innerHTML = '<img alt="Attached image"><button type="button" id="attachremove" ' +
    'aria-label="Remove image">&#10005;</button>';
  // src as a property, never interpolated into the markup above.
  p.querySelector("img").src = pendingImage.url;
}

// Send the image bytes to the Mac and get back the path it was written to. The path, not the
// picture, is what the agent then reads -- a terminal cannot take a pasted image.
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

// The composer's Send: a plain reply when there's only text, or an image reply that uploads first
// and then sends the caption alongside the saved path for the agent to open.
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
  const pid = current;              // the agent chosen now; the upload must not misdeliver if it changes
  const image = pendingImage;
  pendingImage = null;
  renderAttachPreview();
  input.value = "";
  resizeComposer();
  setUploading(true);
  let echoed = false;
  try {
    const path = await uploadImage(image.blob);
    // With no caption the message would start with "/Users/…", which Claude Code and Codex read as a
    // slash command; a leading word keeps the path an argument the agent actually receives.
    const message = caption ? caption + " " + path : "Image: " + path;
    setUploading(false);
    // The path pushed an otherwise-fine caption over the server's limit: keep the attachment and
    // caption editable rather than sending a message /api/send will only 413.
    if (message.length > MAX_SEND_CHARS) {
      restoreAttachment(image, caption, pid);
      feedback("error");
      setStatus("Message is too long to send with an image. Shorten it and try again.", "error");
      return;
    }
    // Echo only when the log still shows the agent we're sending to; otherwise the message still
    // goes to that agent and its own transcript poll surfaces it. Echo the exact text sent, so the
    // transcript's copy dedupes it rather than leaving a duplicate bubble.
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
      // The failed bubble is the retry: tapping it re-sends the same text, and the uploaded file is
      // still on the Mac, so the path resolves. The blob is no longer needed.
      markEchoFailed();
      awaitingReply = false;
      hideTyping();
      URL.revokeObjectURL(image.url);
    } else {
      // No bubble to retry from -- the send was bound to an agent no longer on screen, or navigating
      // away cleared the echo -- so put the attachment back for a manual retry instead of dropping it.
      restoreAttachment(image, caption, pid);
    }
  } catch (e) {
    // Upload itself failed: the preview URL was never revoked, so the same attachment goes back for
    // a retry rather than a redo.
    setUploading(false);
    restoreAttachment(image, caption, pid);
    feedback("error");
    setStatus("Couldn’t upload the image: " + e.message, "error");
  }
}

// Put a not-yet-sent image (and caption) back for retry, but only while its agent is still the one
// on screen -- the composer is shared, so restoring into a different agent's view would send the
// retry to the wrong agent. When you've navigated away, drop it and say so rather than misdeliver.
function restoreAttachment(image, caption, pid) {
  if (current != pid) {
    URL.revokeObjectURL(image.url);
    // Re-enable the footer for the agent now on screen: `uploading` was true when navigation
    // disabled it, and this path would otherwise leave it stuck until the next successful poll.
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
  // While an image is uploading, no other send may start (it would occupy the shared send guard and
  // fail the image reply). Navigation stays live; only the send-capable controls are inert.
  if (uploading && (b.id == "send" || b.id == "clear" ||
      b.dataset.key || b.dataset.opt || b.dataset.submit || b.dataset.text)) return;
  if (b.id == "send") {
    submitComposer();
  } else if (b.id == "attach") {
    $("#fileinput").click();
  } else if (b.id == "attachremove") {
    clearPendingImage();
  } else if (b.id == "clear") {
    clearContext();
  } else if (b.dataset.key) {
    $("#alert").style.display = "none";
    await send({ key: b.dataset.key });
  } else if (b.dataset.opt) {
    toggleOption(b.dataset.opt);
  } else if (b.dataset.submit) {
    submitAnswer();
  }
});

$("#log").addEventListener("click", e => {
  // A link inside a failed message opens the link; tapping the bubble around it retries the send.
  if (e.target.closest("a")) return;
  // Not while an image upload holds the send slot -- the retry would fail against it.
  if (uploading) return;
  const f = e.target.closest(".m.user.failed");
  if (!f) return;
  // textContent, not the linked markup: a retry has to send what was typed, not what it renders as.
  const text = f.textContent;
  f.remove();
  feedback("tap");
  sendText(text);
});

function resizeComposer() {
  const input = $("#msg");
  input.style.height = "auto";
  input.style.height = Math.min(input.scrollHeight, 132) + "px";
}

$("#msg").addEventListener("input", resizeComposer);
$("#msg").addEventListener("keydown", e => {
  if (e.key == "Enter" && !e.isComposing && (e.metaKey || e.ctrlKey)) {
    e.preventDefault();
    $("#send").click();
  }
});

// The picker (accept="image/*") offers the photo library and, on a phone, the camera; the OS picks
// which. Reset the value so choosing the same file again after removing it still fires change.
$("#fileinput").addEventListener("change", e => {
  const file = e.target.files && e.target.files[0];
  if (file) setPendingImage(file);
  e.target.value = "";
});

// Paste an image straight into the composer (desktop, and keyboards that offer it on mobile).
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
new ResizeObserver(() =>
  document.documentElement.style.setProperty("--footer-height", footer.offsetHeight + "px")).observe(footer);
resizeComposer();

$("#ddbtn").addEventListener("click", e => {
  e.stopPropagation();
  document.getElementById("dd").classList.toggle("open");
});
document.addEventListener("click", () => document.getElementById("dd").classList.remove("open"));
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
  const b = $("#privacytoggle");
  b.setAttribute("aria-pressed", String(privacyMode));
  b.setAttribute("aria-label", privacyMode ? "Show agent names" : "Hide agent names");
  b.title = privacyMode ? "Show agent names" : "Hide agent names";
  renderAgents();
  if (lastUsage) renderUsage(lastUsage);
});

// Enter a fresh link from another device: scan Toki's Connect QR, or type its host and token.
// Both reload with the params in the fragment so the normal verify flow takes over.
//
// Save the connection before reloading, not after. Scanning and manual entry are only reachable
// from the invalid-link screen, which has just cleared the saved connection, so the fragment set
// below would be the only copy of the link -- and a reload does not always come back with it (an
// installed PWA relaunches at start_url, same reason REVIVE exists above). That dropped the freshly
// scanned link and bounced straight back to the invalid-link screen. Writing it here means the
// reload restores the same host and token whether or not the fragment survives.
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

// Start over from the landing screen. A link that points at a host the phone can no longer reach
// leaves the app sitting on the verify screen with nothing to do -- and because the link is
// remembered in localStorage and repeated in the address bar, reloading only restores it. So drop
// both, and navigate to the bare page instead of reloading, or the fragment would revive the very
// connection we were asked to leave. location.replace also keeps the tokened URL out of history.
function goHome() {
  try {
    localStorage.removeItem(CONN_KEY);
  } catch (e) {}
  clearSession();
  location.replace(location.pathname);
}

$("#home").addEventListener("click", goHome);
$("#pairhome").addEventListener("click", goHome);

$("#manualconnect").addEventListener("click", manualConnect);
[$("#manualhost"), $("#manualtoken")].forEach(el => el.addEventListener("keydown", e => {
  if (e.key == "Enter") {
    e.preventDefault();
    manualConnect();
  }
}));

// Scan Toki's Connect QR straight from the landing page, then verify the same way as an opened link.
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

// Toki's Connect QR comes in two shapes: a hosted link that names the Mac in its fragment
// (https://rc.toki.../#host=<mac>.ts.net&token=...), and a direct link to the Mac itself
// (https://<mac>.ts.net/?token=... over Tailscale, http://<lan-ip>:8765/?token=... on the LAN).
// Either one is usable here once it yields a token plus a host we're allowed to call, which is the
// same pair the manual host + token form asks for. So resolve both shapes instead of demanding the
// QR point at this exact page: on Tailscale the two shapes name the same Mac either way.
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
  // A direct link. Same origin means this page already reaches that server; otherwise only the
  // tailnet works, because an HTTPS page can't call a plain-HTTP address.
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
