# Threat model

## What this project does and where untrusted input enters

Toki is a macOS menu-bar app that shows usage and rate limits for AI coding agents (Claude Code,
Codex, Cursor, opencode and others) and lists the agents running on the Mac. It is single-user
software that runs as the logged-in user.

The part with a real remote attack surface is **Remote Control**: a companion HTTP server,
`Sources/Toki/Resources/toki_remote.py`, plus the web app it serves from
`Sources/Toki/Resources/webui/`. A paired phone uses it to read agent transcripts and to type into
the terminal an agent is running in. A successful bypass of its authentication is therefore
arbitrary command execution as the user, which is why it is the focus of this scan.

Untrusted input enters through:

- **HTTP requests to the companion server** from any peer the access policy admits: the path,
  query string, `Host`, `Origin`, `X-Forwarded-For`, `Authorization`, `User-Agent` and JSON bodies
  of `/api/pair`, `/api/send`, `/api/upload`, `/api/reset` and `/api/open`.
- **Agent transcripts and session databases on disk** (`~/.claude/projects`, `~/.codex/sessions`,
  opencode and Zed SQLite databases, and similar). Their content is written by agents that may be
  processing attacker-controlled repositories or web pages, so treat it as untrusted. It is parsed
  by the server and rendered by `webui/app.js` and `webui/markdown.js` in the phone's browser.
- **Process metadata** from `ps` and `lsof` (argv, cwd, tty), which another local process can
  influence.
- **The stdin control channel** from the Toki app (`--agent-snapshot-stdin`), which carries agent
  snapshots, usage snapshots and device revocations. The server writes `reset=` and `open=` lines
  back to Toki on stdout; anything a remote client can put on those lines matters.

## Security model of the companion server

Three gates must all pass before a client can act:

1. **Network**: `peer_allowed` / `request_allowed` admit a peer only if it matches the access
   policy (`loopback`, `tunnel`, `tailnet`, `private`, `any`). Behind a local proxy such as
   `tailscale serve`, the forwarded address is checked against the same policy. `host_allowed`
   rejects unknown `Host` headers (DNS rebinding).
2. **Link token**: a random `TOKEN` in the connect URL, required by `/api/pair`.
3. **Pairing code**: six digits, rotated every two minutes, rate limited to five failures per
   minute per direct peer.

Pairing returns a session token (default 12 hours, at most 2 days) sent as `Authorization: Bearer`.
State-changing POSTs also require an allowed `Origin`. The only cross-origin caller allowed is the
hosted app at `https://rc.toki.aashutosh.dev`.

## Components that matter most / least

In scope, highest priority first:

1. `toki_remote.py`: authentication, session handling, access policy, Host/Origin checks, the
   pairing rate limit, and anything reachable before `_authed` succeeds.
2. `toki_remote.py`: terminal input delivery (`send_input`, `send_sequence`, the tmux, iTerm,
   Ghostty and Terminal routes, `applescript_str`, `safe_tty`). Injection into AppleScript, tmux
   arguments or a different tty than the selected agent's is critical.
3. `toki_remote.py`: `/api/upload` (image decoding, file naming, pruning, path handling),
   `/api/transcript` and `/api/screen` (which files and ttys an authenticated client can make the
   server read), and the stdout lines written for `/api/reset` and `/api/open`.
4. `webui/app.js`, `webui/markdown.js`, `webui/sw.js`: XSS from transcript content, token
   handling and storage, and the Content-Security-Policy the server sends.
5. Swift sources under `Sources/Toki` (credential readers, provider API clients, the updater in
   `Updates/`, and `Server/RemoteControlServer.swift` which launches the companion server). These
   are in scope for source review, but they only build on macOS and cannot be built or run in
   this image.

Lower priority: the QR code encoder in `toki_remote.py`, widgets (`Sources/TokiWidgets`), and UI
code under `Sources/Toki/Views`.

Out of scope: `graphify-out/`, `docs/`, `homebrew/`, `examples/`, and the third-party `jsqr.js`.

## How to exercise it

The image has Python 3, Node 22, git, `ps`, `lsof` and tmux. The companion server uses only the
Python standard library.

- Run the server: `python3 -u Sources/Toki/Resources/toki_remote.py --access any --no-qr --port 8765`.
  It prints the link token in the URL and a `pairing_code=NNNNNN` line, and prints a new code each
  time it rotates. Keep `-u` when redirecting its output, or the token sits in the stdout buffer.
- Pair: `POST /api/pair?token=<TOKEN>` with body `{"code":"<PAIRING_CODE>"}` and an `Origin` and
  `Host` that match the server. The response holds the session token.
- Agents are found by scanning `ps` for processes whose argv[0] basename is a known provider. To
  make one appear, run something like `tmux new -d 'exec -a claude cat'`.
- `/api/send` only delivers to macOS tty names (`ttys001`), so Linux `pts/N` agents show as
  read-only. That is expected on Linux and not a finding by itself.
- Tests: `python3 -m unittest discover -s Tests -p 'test_*.py'` and
  `for t in Tests/test_*.js; do node "$t"; done`. `Tests/test_remote_control_server.py` shows how
  to drive the server in-process.

## How you rate severity

- **Critical**: unauthenticated or cross-origin input delivery to a terminal, or command execution
  on the Mac; bypassing the link token, pairing code or session check; a pairing rate limit
  bypass that makes brute forcing the six-digit code practical.
- **High**: an authenticated client reaching a terminal or tty that is not the selected agent's;
  reading or writing files outside what the API intends (path traversal in upload or transcript
  handling); XSS in the web app from transcript content, since it runs with a session token;
  forging `reset=` or `open=` lines on the control channel; a request from outside the configured
  access policy being admitted.
- **Medium**: leaking the link or session token into logs, caches, referrers or history; DNS
  rebinding or Host check gaps that need an extra precondition; denial of service that stops the
  server or exhausts memory or disk from a single peer.
- **Low**: information disclosure of non-secret metadata (machine name, paths, model names) to a
  peer that is already authenticated, and resource use that needs an authenticated session.

## Anything to leave alone

- Anything that requires an already paired session to do what the API is designed to do (typing
  into the agent's terminal, reading its transcript) is intended behavior.
- Behavior under `--access any` that follows from the user's explicit choice to accept every peer.
  Bugs in the other gates still count under that policy.
- The hosted app origin being trusted for CORS is a documented tradeoff (see
  `docs/remote-control.md`); report it only if the trust is wider than that origin.
- `/api/send` refusing Linux `pts/N` ttys.
- Local attackers who already run code as the same macOS user.
