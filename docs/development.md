# Development

## Requirements

- macOS 14 or newer
- Swift 6 toolchain

Providers are optional — Toki shows what is installed and authenticated. Claude Code plus `claude-swap` covers multi-account Claude workflows; Codex, Pi, Sarvam Code, OpenCode, Copilot CLI, Gemini CLI, and Grok CLI are each picked up when present.

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

## Widgets

The `TokiWidgets.appex` extension is embedded under `Contents/PlugIns` by both build scripts. Toki and the extension are separate sandboxed processes, so they share a snapshot (`widget-data.json`) through one of two channels, chosen at package time by `TokiWidgetDataMode` in each `Info.plist`:

- **`app-group`** — used only when `APPLE_SIGNING_IDENTITY` is set. The snapshot lives in the `group.com.aashutoshrathi.toki` App Group container. This requires the App Group to be enabled for **both** the app and the widget-extension signing identifiers in your Apple Developer configuration. If it isn't provisioned, the extension can't read the container and every widget stays empty — there is no runtime fallback.
- **`local`** — used for ad-hoc/unsigned builds (no `APPLE_SIGNING_IDENTITY`). The snapshot goes to `~/Library/Application Support/Toki/widget-data.json`, and the extension is signed with `Config/TokiWidgets.local.entitlements`, a scoped read-only exception to that one folder. No Team ID or App Group provisioning is needed, so this mode is self-contained and portable.

Because the public DMG is ad-hoc signed (not notarized), released builds ship in **`local`** mode. The one caveat that carries to another Mac is Gatekeeper: the appex inherits the same "unidentified developer" friction as the app, so the quarantine flag must be cleared from the **whole bundle** for the extension to load and register — `xattr -dr com.apple.quarantine` (note `-r`, recursive) does this; clearing only the top level leaves the appex quarantined and the widget absent from the gallery. Test on a second Mac or a fresh user account before relying on it, since WidgetKit registration for ad-hoc extensions is not something Apple formally supports.

When a widget looks wrong:

- **Empty "Open Toki"** — the app hasn't written a snapshot in the last 30 minutes (`tokiWidgetStaleAfter`), or `widget-data.json` is missing/unreadable. Launch Toki and let it refresh once.
- **Widget missing from the gallery** — confirm registration with `pluginkit -mv | grep toki`; if absent, re-clear quarantine recursively and relaunch the app.

## Releases and update channels

Every release starts from a tag push; `.github/workflows/release.yml` builds the DMG and publishes the GitHub release. The tag decides the channel:

- **Stable** — tag `vX.Y.Z` (e.g. `v2.5.0`). Published as a full GitHub release, offered to everyone, and the Homebrew cask is updated.
- **Beta** — tag with a prerelease suffix (e.g. `v2.5.0-beta.1`). Published as a GitHub prerelease, offered only to users who picked the Beta channel in Settings > Updates. The Homebrew cask is not touched.

Set `appVersion` in `Sources/Toki/Config/Constants.swift` to match the tag (without the `v`) before tagging — the packaging script, the in-app updater's version check, and the DMG verification all read it.

To graduate a beta to production:

1. Tag `v2.5.0-beta.1` (with `appVersion = "2.5.0-beta.1"`) and test on the Beta channel. Iterate with `-beta.2`, `-beta.3`, … as needed.
2. When it's ready, set `appVersion = "2.5.0"` and tag `v2.5.0`. That build ships to everyone: stable users see it as a normal update, and beta users are offered it too, because `2.5.0` outranks `2.5.0-beta.N` — so testers land back on the production build without touching their channel setting.

Version ordering is semver-aware (`2.4.3` < `2.5.0-beta.1` < `2.5.0-beta.2` < `2.5.0`); the logic and its tests live in `UpdateChecker.compareVersions` and `Tests/TokiTests/UpdateChannelTests.swift`.

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
