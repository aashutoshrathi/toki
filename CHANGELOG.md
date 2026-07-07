# Changelog

## 2.0.5 - 2026-07-08

### Changed

- Refactored monolithic 3166-line `main.swift` into ~30 files organized by concern (models, API, credentials, discovery, networking, utilities, views, config, store).
- Modularized all types into dedicated files for better maintainability and Swift 6 concurrency safety.
- Added GNU General Public License v3 and updated README license section.

## 2.0.4 - 2026-07-08

### Added

- CI workflow that automatically builds and attaches DMG to GitHub releases.

### Fixed

- Release CI uses `gh release create` instead of `upload` to handle fresh tag-triggered runs.

## 2.0.3 - 2026-07-08

### Added

- Debug mode accessible by tapping the version badge 5 times, showing live network request logs and error details.
- Universal binary build with DMG packaging in `scripts/package-release.sh`.
- CI workflow that automatically builds and attaches DMG to GitHub releases.

### Fixed

- Refresh guard now logs when skipped due to an in-progress refresh.

## 2.0 - 2026-07-08

### Changed

- Rebranded the product from TokenBar to Toki, including package, executable, app bundle, docs, and visible app chrome.
- Overhauled the menu bar popover with a `/toki` header, quota summary strip, compact account rows, always-visible progress, and cleaner expanded details.
- Swapped the popover header to a new `/toki` wallet-and-terminal app logo.
- Reworked README and repository docs for a more professional open-source project surface.
- Expanded the example config with `claudeSwapCommand`, `codexAuthPath`, and an optional manual ChatGPT ledger entry.
- Updated README guidance for the v2.0 UI and Codex logo resource.
- Moved header controls to the right side of the popover.
- Added provider-aware refresh throttling: Claude Code API calls paced at 7.5 minutes, Codex at 5-minute cadence, popover/manual reload at 1-minute floor.
- Handle 429 rate-limit responses by keeping the last good usage snapshot.

### Added

- Added the bundled Codex SVG logo resource and copy step for generated `.app` bundles.
- Added a bundled `/toki` SVG logo asset.
- Added a self-contained README preview image and contribution guide.

## 1.1 - 2026-07-08

### Added

- Codex usage support through the local Codex app-server and Codex credentials in `~/.codex/auth.json`.

## 1.0 - 2026-06-22

Toki 1.0 is the first stable release.

### Added

- Native macOS menu bar app for monitoring Claude Code usage.
- Claude Code account discovery through the same local account registry used by `claude-swap`.
- Keychain reads for active Claude Code credentials and inactive `claude-swap` credentials.
- Per-account utilization display for Claude Code 5-hour and 7-day usage windows.
- Account metadata display for email, slot, organization, and active status.
- Account switching for inactive Claude Code accounts through `claude-swap --switch-to`.
- Optional account presentation labels for nicknames, emoji, and colors.
- Manual consumer usage ledgers and API usage views for OpenAI and Anthropic organization keys.
- Build and install scripts for creating a local macOS app bundle.
