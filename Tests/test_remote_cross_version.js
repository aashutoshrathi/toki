"use strict";

// The companion page and the Mac it talks to do not update together. rc.toki.aashutosh.dev
// redeploys the moment a release lands on main, while the Mac updates whenever its owner gets
// round to it, and during a beta main trails the release branch instead. So the page has to
// authenticate against a server of either vintage, and this drives its real token-transport
// logic against both rather than asserting on the source text.

const assert = require("node:assert");
const { execFileSync, spawn } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const net = require("node:net");
const os = require("node:os");

const repo = path.join(__dirname, "..");
const appSource = fs.readFileSync(
  path.join(repo, "Sources", "Toki", "Resources", "webui", "app.js"),
  "utf8"
);

// Lift the token transport out of the browser file: everything from the fallback flag up to the
// first function that touches the DOM.
const start = appSource.indexOf("let legacyTokenTransport");
const end = appSource.indexOf("function lockApp");
assert.ok(start > -1 && end > start, "app.js no longer exposes the token transport as expected");
const transport = appSource.slice(start, end);

const currentServer = path.join(repo, "Sources", "Toki", "Resources", "toki_remote.py");

// The last released server, read straight out of git so the test tracks whatever shipped rather
// than a copy that quietly rots. Skipped where that history is unavailable (shallow CI clones).
function previousServer() {
  const ref = process.env.TOKI_PREVIOUS_SERVER_REF || "origin/main";
  const target = path.join(os.tmpdir(), `toki-prev-server-${process.pid}.py`);
  try {
    const body = execFileSync(
      "git",
      ["show", `${ref}:Sources/Toki/Resources/toki_remote.py`],
      { cwd: repo, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], maxBuffer: 8 << 20 }
    );
    fs.writeFileSync(target, body);
    return target;
  } catch {
    return null;
  }
}

// The server prints whatever --port it was given rather than what it bound, so ask the OS for a
// free one and hand it over.
function freePort() {
  return new Promise((resolve, reject) => {
    const probe = net.createServer();
    probe.on("error", reject);
    probe.listen(0, "127.0.0.1", () => {
      const { port } = probe.address();
      probe.close(() => resolve(port));
    });
  });
}

function startServer(script, port, extraArgs) {
  return spawn(
    "python3",
    ["-u", script, "--port", String(port), "--bind", "127.0.0.1", "--no-qr", ...extraArgs],
    { stdio: ["ignore", "pipe", "pipe"] }
  );
}

// The server prints its link token and pairing code on stdout as it comes up. Be generous about
// how long that takes: HTTPServer.server_bind resolves the bound address with getfqdn(), which on
// a CI runner with unhelpful DNS can sit there for a while before anything is printed.
const STARTUP_TIMEOUT_MS = Number(process.env.TOKI_TEST_STARTUP_TIMEOUT_MS || 90000);

function credentials(server) {
  return new Promise((resolve, reject) => {
    let seen = "";
    const done = outcome => {
      clearTimeout(timer);
      outcome();
    };
    const timer = setTimeout(
      () => done(() => reject(new Error(
        `server never announced itself within ${STARTUP_TIMEOUT_MS}ms. Output so far:\n${seen || "(nothing)"}`
      ))),
      STARTUP_TIMEOUT_MS
    );
    // Report a server that dies on startup straight away, rather than as a timeout that says
    // nothing about why.
    server.on("error", err => done(() => reject(new Error(`could not spawn python3: ${err.message}`))));
    server.on("exit", (code, signal) => done(() => reject(new Error(
      `server exited early (code ${code}, signal ${signal}). Output:\n${seen || "(nothing)"}`
    ))));
    const read = chunk => {
      seen += chunk.toString();
      const token = seen.match(/token=([\w-]+)/);
      const code = seen.match(/pairing_code=(\d{6})/);
      if (token && code) {
        done(() => resolve({ token: token[1], code: code[1] }));
      }
    };
    server.stdout.on("data", read);
    server.stderr.on("data", read);
  });
}

// Node's fetch does not enforce CORS, so on its own it will happily complete a request a browser
// would have refused to send. The hosted app is cross-origin by definition, and the difference is
// exactly where this went wrong once: Authorization is not a safelisted header, so the browser
// preflights, and a server that does not list it blocks the call with no response to inspect.
// Wrap fetch in the part of the CORS protocol that matters here.
const SAFELISTED = new Set(["accept", "accept-language", "content-language", "content-type"]);

function corsEnforcingFetch(pageOrigin) {
  return async (url, options = {}) => {
    const target = new URL(url);
    const headers = Object.assign({}, options.headers);
    const names = Object.keys(headers).map(h => h.toLowerCase());

    if (target.origin !== pageOrigin) {
      const needsPreflight =
        (options.method && !["GET", "HEAD", "POST"].includes(options.method.toUpperCase())) ||
        names.some(n => !SAFELISTED.has(n));

      if (needsPreflight) {
        const preflight = await fetch(url, {
          method: "OPTIONS",
          headers: {
            Origin: pageOrigin,
            "Access-Control-Request-Method": (options.method || "GET").toUpperCase(),
            "Access-Control-Request-Headers": names.join(", "),
          },
        });
        const allowedOrigin = preflight.headers.get("access-control-allow-origin");
        const allowedHeaders = (preflight.headers.get("access-control-allow-headers") || "")
          .split(",")
          .map(h => h.trim().toLowerCase())
          .filter(Boolean);
        const ok =
          preflight.ok &&
          (allowedOrigin === "*" || allowedOrigin === pageOrigin) &&
          names.every(n => SAFELISTED.has(n) || allowedHeaders.includes(n));
        // What the browser surfaces to fetch() when preflight fails: a bare TypeError.
        if (!ok) throw new TypeError("Failed to fetch");
      }

      const response = await fetch(url, {
        ...options,
        headers: Object.assign({}, headers, { Origin: pageOrigin }),
      });
      const allowedOrigin = response.headers.get("access-control-allow-origin");
      if (allowedOrigin !== "*" && allowedOrigin !== pageOrigin) {
        throw new TypeError("Failed to fetch");
      }
      return response;
    }
    return fetch(url, options);
  };
}

// Instantiate the page's transport with the globals it expects, and report whether it fell back.
function pageTransport(apiBase, token, fetchImpl) {
  let lockedOut = false;
  const build = new Function(
    "API_BASE",
    "TOKEN",
    "fetch",
    "lockApp",
    `${transport}\nreturn { api, get legacy() { return legacyTokenTransport; } };`
  );
  const mod = build(apiBase, token, fetchImpl, () => {
    lockedOut = true;
  });
  return { mod, lockedOut: () => lockedOut };
}

// The hosted origin the server is built to allow. Requests from it are genuinely cross-origin.
const HOSTED_ORIGIN = "https://rc.toki.aashutosh.dev";

async function check(name, script, extraArgs, expectFallback, { hosted = false } = {}) {
  const port = await freePort();
  const server = startServer(script, port, extraArgs);
  try {
    const { token, code } = await credentials(server);
    const apiBase = `http://127.0.0.1:${port}`;
    // Pairing sends the link token in the query string on every version, so it is not the part
    // that can break; get a session the plain way and test what the page does with it.
    const paired = await fetch(`${apiBase}/api/pair?token=${token}`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Origin: HOSTED_ORIGIN },
      body: JSON.stringify({ code }),
    }).then(r => r.json());
    assert.ok(paired.token, `${name}: pairing did not return a session token`);

    const fetchImpl = hosted ? corsEnforcingFetch(HOSTED_ORIGIN) : fetch;
    const { mod, lockedOut } = pageTransport(apiBase, paired.token, fetchImpl);
    const agents = await mod.api("/api/agents");

    assert.ok(Array.isArray(agents), `${name}: the page could not read agents`);
    assert.equal(mod.legacy, expectFallback, `${name}: unexpected token transport`);
    assert.equal(lockedOut(), false, `${name}: the page locked the user out`);
    console.log(`ok  ${name} (fell back to query token: ${mod.legacy})`);
  } finally {
    server.kill();
  }
}

(async () => {
  // Against the server it ships with, the token must stay in the header: the whole point is
  // keeping it out of URLs, and a needless fallback would put it back.
  await check("same-origin page, current server", currentServer, ["--access", "loopback"], false);
  await check("hosted page, current server", currentServer, ["--access", "loopback"], false, {
    hosted: true,
  });

  const previous = previousServer();
  if (!previous) {
    console.log("skip  previous server unavailable (no git history for origin/main)");
    return;
  }
  try {
    // A server from before the header existed reads the query string only. The page must notice
    // and fall back, or every hosted user on an older Toki is locked out the day rc redeploys.
    await check("same-origin page, previous server", previous, [], true);
    // The one that actually bites: cross-origin, the header is preflighted, and a server that
    // does not allow it makes the browser block the request with no status to branch on.
    await check("hosted page, previous server", previous, [], true, { hosted: true });
  } finally {
    fs.rmSync(previous, { force: true });
  }
})().catch(err => {
  console.error(err);
  process.exit(1);
});
