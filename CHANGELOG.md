# Changelog

## 2.2.0 - 2026-07-16

### Added

- A "What's new" page reachable from a header icon, showing this changelog inside the app.

### Changed

- Custom AI insight instructions now fully override Toki's default behavior - tone, style, format, and length - instead of only taking priority over tone/length while still competing with the default framing. The one thing that still can't be overridden is the anti-hallucination rule (never invent quota numbers, account names, or reset times), which is now appended as a separate fixed constraint rather than presented as a rule the custom instructions merely take priority over.

### Fixed

- The AI insight instructions box in Settings showed its placeholder text and real typing caret at slightly different positions, because the placeholder was drawn with hand-picked padding that didn't match SwiftUI TextEditor's own (private, undocumented) internal inset. It's now backed by a custom text view with an explicit inset that the placeholder matches exactly.
- Provider logos (menu bar icon and account cards alike) could get stuck showing the generic SF Symbol fallback instead of the real brand mark for the rest of the app's lifetime. The logo loader cached failed lookups exactly like successful ones, so if the very first attempt to load a given logo - which can happen as early as the menu bar status item's first render, before the rest of the app has finished starting up - ever came back empty for a transient reason, nothing ever re-tried it. Only successful loads are cached now.
- The AI insight's guided-generation schema declared its suggestions list with `.count(3)`, which FoundationModels treats as an exact element count, not a maximum - so the model was structurally forced to emit exactly 3 suggestion objects on every response regardless of what custom instructions asked for. Changed to `.maximumCount(3)` and reworded the per-request prompt so custom instructions can actually suppress suggestions entirely.
- The header's "/toki" wordmark could wrap onto two lines - it lost the fight for space to the header icon row once a 5th icon (the new changelog button) was added. The wordmark no longer wraps, and the popover is a bit wider to give the header room.

## 2.1.9 - 2026-07-16

### Added

- Grok (xAI's own CLI) and Gemini support: detection, sign-in, and a real account card for each. Neither has a usage API (confirmed directly against both CLIs), so their cards show active session count instead of a percentage - and Grok's sessions now resolve their real conversation title instead of a generic "Grok agent" label.
- Providers auto-connect the moment they're detected, signed in and running - no manual "Connect" click needed. The "Add account" button/page is gone; opening the popover is enough.
- "Remove" action on each account card's expanded section, with a confirmation dialog (only edits local config, doesn't sign anything out).
- A small session-count badge on every account card's logo, and on the Agents tab icon.
- AI insight instructions get their own Settings page, reachable even when Apple Intelligence isn't available yet on the Mac (with an inline note explaining why generation is inactive).
- Basic syntax highlighting in the Config JSON editor.

### Changed

- Custom AI instructions now take priority over Toki's default tone and length instead of competing with a hardcoded "summarize in one sentence" line - they're composed with the anti-hallucination grounding rather than replacing it outright.
- Settings reorganized into labeled sections (General, Notifications, Updates, Advanced) instead of one flat list.
- The main account list now orders cards by how much they can actually show: real usage data first, then agent-detection-only accounts with something running right now, then idle ones.
- Assorted polish: smaller toggles, de-emphasized "Send debug report"/Save/Revert buttons, cleaner error-state cards (no more mid-word truncation, no redundant provider badge), plainer Accounts tab icon, "Active coding agents" renamed to "Active agents".
- Removed the unused History tab.

### Fixed

- `ConfigLoader.validate()` still rejected any config.json account for Grok/Copilot, a holdover from before either had a real config entry - this would have made connecting Grok fail outright, and broken loading the entire config on the next launch.
- Several icon buttons (header row, event-log clear, account-card actions) were only clickable on the glyph itself, not the visible rounded button behind it.
- The menu bar icon (and the popover anchored to it) could shift position on refresh, since its width was recalculated from the fitted percentage text and digit count changes (e.g. "9%" to "58%" to "100%") every poll. The percentage now renders in a fixed-width field so the status item's width - and therefore its screen position - stays stable.
- Rarely, the popover would open pinned to the top-left corner of the screen instead of under the menu bar icon - a timing race where the popover anchored before the status item's own layout pass had settled. The popover now defers to the next run loop tick before anchoring, and falls back to a sane rect if the button's bounds are momentarily degenerate.

## 2.1.8 - 2026-07-15

### Changed

- Codex's collapsed account-card summary now shows its two rate-limit windows (rolling 5h and 7-day/weekly) explicitly and separately instead of one generic percentage - or, when only one window has data, just that one - rather than falling back to a raw token count whenever the other window happened to be unavailable. Claude's card is unaffected; it only ever has one window.

## 2.1.7 - 2026-07-15

### Fixed

- Codex accounts were completely broken in 2.1.6: `codex app-server` is a single-client stdio transport that exits as soon as it sees EOF on stdin, but the 2.1.6 poll-loop rewrite closed stdin within ~0.4s of sending the last request (no trailing sleep), so app-server tore itself down before the network round-trip for `account/rateLimits/read` could return. Combined with 2.1.6's new hard failure on a missing rate-limits response, every Codex fetch errored out. The subshell feeding stdin now stays open for the full poll window so app-server isn't killed mid-round-trip; the process is still torn down explicitly as soon as (or as soon after as) all expected responses arrive.

## 2.1.6 - 2026-07-13

### Added

- "Reset now" button on the Codex account card when OpenAI has banked rate-limit reset credits available (shows the count when more than one is banked). Disabled until the current window is at least 80% used, so a reset isn't spent while there's still plenty of quota left.

### Fixed

- Codex usage sometimes displayed a raw token count instead of the percentage-based rate limit like Claude Code does. The `account/usage/read` and `account/rateLimits/read` app-server calls were fired together but raced a single fixed 5s sleep before the pipe closed; rate limits (which round-trip to OpenAI's backend) could lose that race while usage won, silently falling back to token display. Now polls for every expected response instead of guessing a fixed delay.

## 2.1.5 - 2026-07-13

### Added

- Launch at login toggle in Settings, backed by `SMAppService` so it stays in sync with System Settings > Login Items (including surfacing a "Needs approval" prompt when macOS requires it).
- `Toki status` CLI (`--compact` / `--json`) for scripting and shell prompt integrations. Reads a cache the app writes after every refresh at `~/.toki/status.json` instead of doing a live fetch, so it's instant.
- Optional Developer ID signing and notarization in the release pipeline, gated entirely on repo secrets - inactive (falls back to the existing ad-hoc signing) until those are configured.
- Gemini CLI agent detection, matching the existing Copilot tier: shows up in the Agents tab when running, and in onboarding as signed-in (via its Google OAuth token). No quota tracking - confirmed directly against the `@google/gemini-cli` package source that it has no such API for personal accounts, same situation as Copilot.
- "Add account" button in the header (next to Settings), reopening the connect screen after the first account is already set up - useful for starting with just Claude and adding Codex (or anything else) later without hand-editing config.json. Only offers providers not already connected.

### Changed

- Internal restructuring, no user-facing changes: split the `UsageStore` god-object (685 lines mixing config/onboarding, refresh, sessions, notifications, AI insight, and debug logging) into per-concern extension files, and broke up `SmartPanels.swift` (a 532-line grab-bag of unrelated views accumulated across the last few features) into one file per view, matching the rest of the codebase's one-type-per-file convention.

## 2.1.4 - 2026-07-12

### Added

- Click-to-connect onboarding: when no `config.json` exists yet, the popover scans for Claude Code (Keychain), Codex (`~/.codex/auth.json`), and OpenCode (local database) and lets you add them with one click instead of hand-writing JSON. A manual JSON editor link remains for advanced setups.

### Fixed

- `ConfigLoader.save` now creates `~/.toki` if it doesn't exist yet, so the first-ever config write (including from the new onboarding flow) no longer fails on a fresh install.

## 2.1.3 - 2026-07-12

### Fixed

- Fixed a launch crash in the released app: resources are now resolved via `Bundle.main` from `Contents/Resources` instead of the SwiftPM `Bundle.module` accessor, which fatal-errored because its resource bundle can't sit at the code-signed app root.

## 2.1.2 - 2026-07-12

### Added

- Settings editor for the AI insight instructions (`aiInstructions`), with the default prompt shown as placeholder and reset-to-default; saving regenerates the insight immediately. Shown only when on-device AI is available.

### Changed

- Release builds now run on the macOS 26 runner so the on-device AI insight (Foundation Models) is compiled into the shipped app instead of being stripped on an older SDK.

### Fixed

- Settings back button now responds across its whole surface, not only the chevron glyph.
- AI instructions editor surfaces a save failure inline instead of showing a false "Saved".

## 2.1.1 - 2026-07-12

### Added

- Active-agent discovery for Codex, Claude Code, Copilot CLI, OpenCode, and ChatGPT-hosted Codex with runtime, terminal metadata, and working directory display.
- Conversation title and project folder display for each agent, shown relative to home (`~/Code/project`).
- Best-effort navigation to matching terminal tabs (iTerm2, Terminal, WezTerm) and editor-hosted sessions (VS Code, Cursor, ChatGPT) via bundle ID resolution.
- On-device AI insight card using Apple Intelligence (macOS 26+) for natural-language account summaries, with a deterministic recommendation fallback and expandable suggestions.
- Session recording banner with a live animated stopwatch while tracking is active.
- Session play/stop toggle moved to the header controls bar.
- OpenCode usage tracking from its local SQLite database (today's spend, tokens, all-time totals), auto-detected when available.
- OpenCode SVG logo resource.
- Claude SVG logo resource.
- Automatic GitHub release checks and verified one-click DMG installation.
- Six-hour update polling with a manual "Check now" action in Settings.
- Privacy-safe rotating local diagnostics and an attached debug-report share action.
- Config migration from `name`/`provider`/`id` to `label`/`type` with automatic migration and `.bak` backup.
- In-app JSON config editor.
- Optional `aiInstructions` config field for customizing the on-device LLM prompt.
- Homebrew cask installation (`brew install --cask toki`).
- Cask update automation script.
- Full-page settings view replacing the Settings tab.
- Copilot provider entry (agent-detection only, no quota tracking).

### Changed

- Release bundles are ad-hoc signed so downloaded updates can be verified before installation.
- Overview panel now uses a unified AIInsightCard replacing three separate stat blocks.
- Account config format migrated to `label`/`type`; legacy configs load and convert automatically.
- Provider logos switched to SVG assets with fallback marks for new providers.

### Fixed

- Pipe deadlock in subprocess runner: drain stdout and stderr before `waitUntilExit`.
- Update download URL validation now enforces `https` scheme alongside host check.

## 2.1.0 - 2026-07-11

### Added

- Smart recommendation panel that suggests the healthiest AI coding account to use next.
- One-click switch to the recommended Claude Code account from the overview (Claude Code accounts only, via `claude-swap`).
- Native low-quota and session-warning notifications with DND mode, cooldowns, and local event history.
- Local usage history retained in `~/.toki/usage-state.json`.
- Session mode for tracking quota burn during focused coding work.
- Settings tab for notifications, DND, thresholds, history retention, and menu bar display mode.
- Menu bar display modes for smart, lowest, Claude, Codex, combined, or account-count status.

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
