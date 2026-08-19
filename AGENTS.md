# AGENTS.md

## Cursor Cloud specific instructions

Toki is a **macOS-native menu-bar Swift app** (SwiftUI/AppKit/WidgetKit). Cursor Cloud VMs run
**Linux**, so the main `Toki`/`TokiWidgets` targets **cannot be built or run here** — `swift build`,
`swift test`, and `scripts/build-app.sh` require macOS + the Swift 6 / Xcode toolchain and Apple
frameworks. Those steps only run on the `macos-26` CI runner (see `.github/workflows/ci.yml`).

What *is* developable and runnable on Linux is the cross-platform **Remote Control companion
server** and its web UI, plus their tests — the same non-Swift steps CI runs:

- **Companion server (runnable app):** `python3 Sources/Toki/Resources/toki_remote.py`
  - Dependency-free (Python 3 stdlib only). Serves the web UI + JSON API, default port `8765`.
  - Useful flags: `--access any` (accept any peer, needed for non-loopback/browser testing on the
    VM), `--no-qr` (skip the terminal QR block), `--port N`, `--bind ADDR`.
  - On startup it prints a link `token=…` and a `pairing_code=NNNNNN`. The **pairing code rotates
    every 2 minutes** and each rotation prints a fresh `pairing_code=…` line — read the latest one
    from the server's stdout, not the first.
  - Connect flow: open `http://localhost:8765/?token=<TOKEN>`, enter the current 6-digit pairing
    code, then the API is reachable (`/api/agents`, `/api/usage`, `/api/transcript`, `/api/send`).
    Programmatic pair: `POST /api/pair?token=<TOKEN>` with body `{"code":"<PAIRING_CODE>"}` and an
    `Origin`/`Host` of the server → returns a session token for `Authorization: Bearer`.
- **Companion server tests:** `python3 -m unittest discover -s Tests -p 'test_*.py'`
- **Web UI tests (Node):** `for t in Tests/test_*.js; do node "$t" || break; done`

### Non-obvious gotchas

- **Agent discovery is by `ps` scan.** The server finds agents by scanning `/bin/ps` for processes
  whose argv[0] basename is `claude`, `codex`, or `opencode` (`provider_of` in `toki_remote.py`).
  On a VM with no AI CLIs, `/api/agents` is correctly empty. To make an agent appear for a demo,
  run a provider-named process on a TTY, e.g. `exec -a claude cat` inside a tmux pane.
- **`/api/send` is macOS-oriented and won't deliver on Linux.** `safe_tty` only accepts macOS tty
  names (e.g. `ttys001`); Linux `pts/N` fails that gate, so discovered agents show as
  `writable: false` / "read-only" and replies cannot be delivered here. This is expected on Linux,
  not a bug — do not "fix" it for the VM.
- No linter/formatter is vendored (`swift-format` is intentionally not included); there is no
  Python/JS lint step. "Lint" for this repo effectively means keeping the Swift compiler clean on
  macOS CI.
- Optional local config lives at `~/.toki/config.json` (example: `examples/config.example.json`);
  override the path with the `TOKI_CONFIG` env var. Not required to run the companion server.

See `docs/development.md` and `docs/remote-control-hosting.md` for the full (macOS-centric) build,
release, and Remote Control hosting details.
