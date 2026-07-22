# Development

## Requirements

- macOS 14 or newer
- Swift 6 toolchain

Providers are optional — Toki shows what is installed and authenticated. Claude Code plus `claude-swap` covers multi-account Claude workflows; Codex, Pi, OpenCode, Copilot CLI, Gemini CLI, and Grok CLI are each picked up when present.

## Building

```sh
swift build
swift run Toki
scripts/build-app.sh          # bundle to .build/Toki.app
scripts/install-app.sh        # bundle and install to ~/Applications
```

Before shipping a local change:

```sh
swift build
swift test
scripts/build-app.sh
plutil -p .build/Toki.app/Contents/Info.plist
```

## Concurrency checking

CI builds with stricter concurrency than a plain `swift build`, and the difference has broken this project's CI more than once — a pure static helper on a `@MainActor` type needs `nonisolated`, which only the stricter mode catches. Reproduce it locally before pushing:

```sh
swift build --build-tests -Xswiftc -strict-concurrency=complete
```

## Conventions

`swift-format` is not vendored here. Keep changes compiler-clean, locally scoped, and consistent with the surrounding SwiftUI/AppKit style.

Comments should explain what the code cannot: why a timeout is the value it is, why a coordinate space is not flipped, why an ordering is deliberate. Comments that restate the line below them are noise and get deleted.

## Troubleshooting

- **`Config needed`** — create `~/.toki/config.json` or set `TOKI_CONFIG`.
- **`No credentials found`** — confirm Claude Code and `claude-swap` are authenticated and Keychain access was allowed.
- **`Claude Code usage unavailable`** — Anthropic returned no usage for that account. Retry later, or check the account in Claude Code.
- **`Codex usage unavailable`** — confirm `codex login` has created `~/.codex/auth.json`, then refresh.
- **Pi missing** — confirm its session directory has JSONL history and any override path is absolute, exactly `~`, or starts with `~/`.
- **Switch fails** — run `claude-swap --switch-to <slot>` in Terminal to see the underlying error.
- **No notifications** — check the Events tab for DND or cooldown suppression, then confirm macOS notification permission.
