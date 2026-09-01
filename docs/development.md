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

- **Stable** — tag `vX.Y.Z` (e.g. `v2.5.0`). Published as a full GitHub release, offered to everyone, and both Homebrew casks are updated (`toki` and `toki-beta`).
- **Beta** — tag with a prerelease suffix (e.g. `v2.5.0-beta.1`). Published as a GitHub prerelease, offered only to users who picked the Beta channel in Settings > Updates, and the `toki-beta` cask is updated. The stable cask is not touched.

Set `appVersion` in `Sources/Toki/Config/Constants.swift` to match the tag's base version (without the `v` and without any prerelease suffix) before tagging — the packaging script, the in-app updater's version check, and the DMG verification all read it. `CFBundleShortVersionString` must stay dotted-numeric; the prerelease identity travels in the tag, which the release workflow stamps into `TokiReleaseVersion` in Info.plist. The DMG filename is built from the base version (`Toki_2.5.0_universal.dmg`) even for a beta tag.

To graduate a beta to production:

1. Tag `v2.5.0-beta.1` (with `appVersion = "2.5.0"`) and test on the Beta channel. Iterate with `-beta.2`, `-beta.3`, … as needed.
2. When it's ready, set `appVersion = "2.5.0"` and tag `v2.5.0`. That build ships to everyone: stable users see it as a normal update, and beta users are offered it too, because `2.5.0` outranks `2.5.0-beta.N` — so testers land back on the production build without touching their channel setting. The same graduation happens for brew: the stable tag bumps both casks, so `brew upgrade` carries `toki-beta` users onto the stable build.

Version ordering is semver-aware (`2.4.3` < `2.5.0-beta.1` < `2.5.0-beta.2` < `2.5.0`); the logic and its tests live in `UpdateChecker.compareVersions` and `Tests/TokiTests/UpdateChannelTests.swift`. Homebrew's own ordering agrees, which is what makes the single `toki-beta` cask work across iterations and graduation.

## Homebrew

Two casks live in the tap (`aashutoshrathi/homebrew-tap`): `toki` (stable) and `toki-beta` (prereleases). They conflict with each other — install one.

`scripts/update-cask.sh <cask.rb> [version]` rewrites a cask's version and DMG sha256. The version argument defaults to `appVersion`; prerelease tags must pass the full version (e.g. `3.2.0-beta.1`) because it exists only in the tag. The DMG filename always carries the base version (`Toki_3.2.0_universal.dmg`), which the script and the cask's URL handle.

When Toki was installed by a cask, the in-app updater detects it (`BrewCask.installedCask` — the Caskroom entry is a symlink to the installed bundle) and routes "Install update" through `brew upgrade --cask <toki|toki-beta>` instead of swapping the DMG underneath brew. This keeps brew's receipt in sync with the app on disk; the DMG path would desync it, and the next `brew upgrade` would then clobber the newer build with the cask's older one. Dev builds and manual installs keep the direct DMG path.

The channel picker and the installed cask are kept in agreement in both directions. Picking a channel moves a brew install onto the matching cask (`fetch`, then `uninstall`, then `install` — `conflicts_with` rules out installing over the top, and fetching first means a network failure cannot strand the uninstall with nothing to reinstall). Swapping casks with brew directly moves the channel instead: the cask decides what brew will install, so the preference follows it on the next check. A failed switch reinstalls the cask that was there and puts the preference back.

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
- **`brew finished but Toki wasn't updated`** — the tap may be stale; run `brew update && brew upgrade --cask toki` (or `toki-beta`) manually and check the tap has the version the app offered.
- **`Beta builds ship in the toki-beta cask`** — the Beta channel is on but brew installed the stable `toki` cask, which never carries a prerelease. Re-pick the channel in Settings to move the install; by hand it is `brew uninstall --cask toki && brew install --cask toki-beta`, since `conflicts_with` makes a bare install refuse.
