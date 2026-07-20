# Changelog

## 2.4.0 - 2026-07-21

### Added

- Experimental "live in the notch" mode, off by default, replaces the menu bar item with a Dynamic Island style panel at the display notch, and expands it on hover.

  The camera housing itself cannot be drawn on - it is hardware, with no pixels behind it - but the menu bar band either side of it is ordinary display. The panel uses that band, and where it needs to appear continuous with the housing it simply lets the hardware mask the part behind it. Three resting positions are offered: Hanging drops below the housing matching its width, Sideways sits in the band against its right edge, and Around splits the readout across both bands so it wraps the housing, with a gap sized to the housing exactly so the two halves read as one interrupted strip.

  The resting pill is sized from the same measurement the menu bar item uses, so the readout is never truncated as providers are added. The status item is only hidden once the panel is confirmed on screen; if the geometry is unavailable it stays in the menu bar rather than leaving nothing visible. Clicking opens the popover anchored to the pill itself, wherever it is resting.
- OpenCode sessions waiting on input are now detected alongside Claude Code ones, using the same idea: a tool invocation whose recorded state is still `running` after a quiet period has stopped and is waiting on you.
- Spend Analytics gained a daily-usage heatmap covering the last 30 days, filterable by provider and including Claude Code, OpenCode and Pi.

  Activity is read from each tool's own session store rather than from Toki's recorded quota samples. Those samples only exist for days Toki was running, so the chart would be empty for any period before install and could be lost entirely if local state were reset; and they cannot represent cost-based providers at all, since OpenCode and Pi have no quota percentage to sample. Session files are durable, predate Toki, and cover every provider. Claude Code usage is priced per message via published model rates, so a session that switched models bills each stretch at its own rate.

  Days are shaded by rank among your active days rather than as a share of the busiest one. Daily token counts are heavily skewed - a single long session can run an order of magnitude above a normal day - and scaling linearly against that outlier crushes every other day into the lowest step, leaving a grid that shows no pattern. Ranking guarantees the full scale is used. The shade therefore means "busy compared to your other days", which is why hovering gives the real token and cost figures, broken down by provider.

  Colours were validated rather than eyeballed: every adjacent pair of steps clears the normal-vision separation floor and holds above the floor for all three common forms of colour blindness. "No data" is a neutral grey rather than a pale tint of the ramp, so it cannot be misread as a very light day, and cell borders carry the palest steps, which fall below the 3:1 contrast bar on their own.
- The menu bar carries a badge with the number of agent sessions waiting on you, so a blocked session is visible without opening the popover. The count is knocked out of a filled dot rather than drawn in a fixed colour, so it stays readable against a light or dark menu bar alike.
- Agents waiting on you are now called out with a red dot. A Claude Code session that has asked a question or is sitting on a permission prompt shows a red dot on its card, the question text (or the tool awaiting approval) right underneath, and turns the Agents tab badge red with a count of just the blocked sessions. Clicking the card jumps straight to the terminal that's asking. Detection keys off a tool call with no matching result, gated on ten seconds of quiet in the session file - a tool that is merely running writes its result almost immediately, so the quiet period is what separates "working" from "waiting". The list is deliberately not re-ordered to put blocked agents first: rows that move while you are looking at them cancel the click you were making.
- Claude Code sessions now show an estimated dollar cost alongside their token counts. Claude Code records no cost figure in its session files, so the tokens are priced against published per-model rates. Cache tokens are priced at their own rates (writes 1.25x input, reads 0.1x) rather than as plain input - a long session is mostly cache reads, so pricing them as input would overstate cost several-fold. Cost accumulates per message, so a `/model` switch mid-session bills each half at its own rate; an unrecognized model shows tokens without a cost rather than a guessed figure.

### Changed

- The session-cost donut in Spend Analytics responds to the pointer directly. Selection previously came only from hovering the legend rows beneath it, so pointing at a slice did nothing. The donut hole and the area outside the ring select nothing, rather than snapping to whichever slice happens to be nearest.
- Heatmap figures are shown in a detail line under the grid instead of a tooltip. System tooltips wait out a delay and often never appear inside a popover at all, so reading a value was a gamble; the line updates the instant the pointer moves, and the hovered cell is ringed so it is clear which day the figures belong to.
- Daily usage shows a loading skeleton while session files are read. That scan takes a moment on a machine with real history, and without it the empty grid rendered first - indistinguishable from having no activity at all.
- The Tracked / Oldest data / Active agents summary cards have been removed from Spend Analytics.
- Default history retention raised from 14 to 30 days so the usage heatmap can fill its full window; at the old default the chart silently rendered half as many days.
- claude-swap accounts now read as "Claude - user@example.com" instead of the registry's internal `claude-1-user@example.com` key. An explicit nickname still wins, and an account with no email falls back to plain "Claude". The underlying account id is unchanged, so existing aliases, usage adjustments, and cached state stay attached.

### Fixed

- Claude Code accounts could fail to connect on a machine that had never granted Keychain access. Credentials are read with the `security` CLI, and the first read puts up the system's Keychain access prompt, which blocks the command until it is answered. That read shared a 15-second timeout intended for non-interactive key-fetching commands, so the clock was really measuring how quickly the user noticed a dialog - miss it and the read was killed, the account reported as not connected, and nothing indicated a prompt had been the reason. The Keychain read now gets a far longer ceiling, and failing it says to allow the prompt and refresh. Introduced in 2.3.2.
- An account that fails to connect now shows the actual reason when its card is opened, in full and selectable, instead of the word "Unavailable" - which only repeated what the collapsed card's "not connected" badge already said, in the one place with room for the detail.
- Clicking an agent card now reliably focuses its terminal. Navigation identified the host app by name and by bundle identifier, both ambiguous when two builds of the same terminal are running - as iTerm and iTermAI are, sharing an identifier prefix - so it could raise a copy holding none of the agent's windows. The agent's own host process is now activated by PID, which names exactly one process. The AppleScript also no longer runs on the main actor: it was waited on synchronously, so anything that made it hang froze the app, which reads as a dead click rather than a hang.
- The popover no longer jumps while it is open. It is anchored to the status item's button, so any change to that item's width moved the anchor and macOS repositioned the whole popover - and the width changes exactly when something noteworthy happens, such as the waiting-agent badge appearing or a quota segment dropping out, so it slid away precisely while being read. Width changes are now held until the popover closes; content still refreshes live throughout.
- Compact token counts no longer lose their decimal. `formatCompact` chose its precision from the unscaled value, so anything above 100 also got zero decimals after scaling - 1,500,000 rendered as "2M", rounding away the digit that carries the meaning at that size. It now reads 1.5M.
- Saved preferences and history are no longer discarded when a new preference is added. `AppPreferences` relied on the synthesized decoder, which requires every field to be present and never falls back to a property's default, so a state file written before a newly added field existed failed to decode outright. The loader treats that as an unreadable state and starts fresh, and the next save overwrites the file - meaning a single added preference wiped accumulated usage history. Preferences are now decoded field by field with per-field defaults, so adding one is additive by construction, and a state file that still cannot be read is copied aside as `.unreadable` rather than being silently replaced.
- Update checks no longer stop after an update is found, so a release that lands while an earlier one is still pending is now picked up. Checks were driven by a chain of one-shot timers, each scheduling its successor from inside its own fire handler - any single missed or invalidated firing ended the chain permanently, leaving the app parked on a stale version. The timer is now a repeating one registered in the common run loop modes, so it also keeps firing while the popover or a menu is open, and a skipped firing is no longer fatal.
- Menu bar status text no longer disappears against a dark menu bar. The status view pinned its appearance to the app's (which follows the system light/dark setting) rather than inheriting the menu bar's own, so in full-screen - where the bar renders dark even in light mode - the text was drawn in the light-mode label color on a dark background and became invisible. It now inherits from the status item's button, which carries the real menu-bar appearance.

## 2.3.3 - 2026-07-19

### Added

- Spend Analytics tab with quota history line chart (7/30/all days), per-agent session cost bars, and Pi spend breakdown.

## 2.3.2 - 2026-07-19

### Security

- Config, state, cache, and debug-report files now written with `0o600` permissions via new `SecureStore.write()` helper.
- `SecretResolver.runShell()` hardened with 15-second timeout, concurrent pipe reads (deadlock-safe), and generic error messages — no command or path leakage on failure.
- `CodexUsageClient.call()` raw output in errors truncated to 200 characters.
- `FileManager.enumerator` in `PiUsageClient` now filters symbolic links.
- Log redaction extended with patterns for `sk-` prefixed tokens and base64-like credential strings.
- `expandedPath()` now calls `standardizingPath` to resolve `..` traversal in env-var path overrides.
- `SecureStore.write()` resolves symlinks before writing (prevents atomic-write symlink following).
- `safeSQLPath()` validates absolute paths and rejects single quotes before SQL interpolation in agent session queries.
- `HTTPClient.requestJSON()` debug log no longer includes response body preview; error body truncated to 200 chars.
- Debug report filenames use `UUID().uuidString` instead of predictable timestamps.
- Config and Codex auth errors use generic messages instead of leaking full file paths.
- `CodexUsageClient` unparsed output truncated to 200 characters.
- Keychain access retained via `security` CLI (reverted from `SecItemCopyMatching` which requires code-signing entitlements for unsandboxed binaries).

### Changed

- README reorganized — Install sections moved above Requirements and Features.
- README header now has downloads and stars badges.
- README hero section replaced with a split table showing the menu bar screenshot alongside a `toki status` CLI output sample.

## 2.3.1 - 2026-07-19

### Added

- Pi spend is now broken out into this-week and this-month estimated totals alongside today and all-time, so the card reads as a proper spend tracker rather than just a daily figure. Week and month use half-open calendar ranges (matching the existing day window), so a turn on a week or month boundary lands in exactly one bucket.
- Pi now shows its today-spend directly in the menu bar. Cost-based providers have no quota percentage, so they were never chosen for the Claude/Codex quota segments and stayed invisible there - a Pi-only user was left staring at the "-- / --" placeholder. Pi's compact spend value ("$1.20") fills a menu-bar slot in Smart mode when one is free. Smart mode is hard-capped at two segments so the status item never grows wide enough for macOS to drop it entirely on a crowded or notched menu bar; quota providers take priority and a cost provider only fills a remaining slot, so a Pi-only user still sees Pi while a Claude+Codex+Pi user stays at two.
- CLI grew several scriptable options. `Toki status <filter>` narrows output to a provider (`pi`, `codex`, `claude`, ...) or account name; `Toki status --watch[=secs]` redraws live every few seconds; `Toki status --exit-code` exits 2 when the matching tracked quota is exhausted (so `Toki status codex --exit-code || notify` works without parsing text); and `Toki status --help` lists it all. A new `Toki pi [--json]` prints Pi's today/this-week/this-month/all-time spend breakdown - computed directly from local session history, so unlike `Toki status` it needs no running app or cache.
- Active agent cards now show session-wise cost and token usage when available - OpenCode (cost + tokens), Pi (cost + tokens), and Claude Code (token counts only) all display their per-session figures directly on the card, so you can see what each running session has burned at a glance without switching to the account overview.

### Changed

- Pi usage aggregation no longer re-reads and re-parses every session file on every poll. Each file's parsed per-message contributions are cached and keyed by the file's size and modification date; since session logs are append-only, an unchanged file is served from cache and only the cheap dedup/date-bucketing re-runs. The sliding today/week/month windows are still recomputed against a fresh clock each poll, so the cache never staleness-skews the totals. This also collapses what were two reads per file (session header, then messages) into one.
- Trimmed the README again - condensed the auto-detection, AI insight, updates, and Pi sections, and removed a paragraph that restated recommendation behavior already covered elsewhere.
- The save icon on the Config JSON editor and AI instructions editor was replaced from `square.and.arrow.down` to `arrow.down.doc` for a less ambiguous document-oriented save affordance.
- Update check interval reduced from 6 hours to 5 minutes for faster discovery of new releases, with rate-limit (429) responses handled silently without error messages.
- The Config JSON and AI instructions editors now properly respond to Cmd+A (select all) by routing `selectAll:` through the coordinator, and the account alias TextField auto-focuses when entering edit mode.
- Added 12 new tests covering `AgentSessionUsage` display formatting, Claude Code JSONL token parsing, and session usage dispatch. CI workflow runs tests on every PR.

### Fixed

- Active-agent cards ignored a Claude Code chat's `/rename`, always showing the AI-inferred title instead. Claude Code records the auto-generated title as `aiTitle` and a user's explicit rename as a separate `customTitle`, but Toki only ever read `aiTitle`. It now prefers `customTitle` when present and falls back to the inferred `aiTitle` only when the chat was never explicitly named. (Grok, OpenCode, and Pi were already correct - each overwrites its single title field on rename, so the name Toki already reads is the renamed one.)
- OpenCode today-spend always showed "0 in / 0 out" because `strftime('%s', ...)` returns TEXT, not INTEGER, and SQLite's type-rules for NONE-affinity expressions treat TEXT as always greater than INTEGER, causing the `>=` comparison against `time_updated/1000` to always evaluate to false. The `strftime` result is now explicitly cast to INTEGER so the comparison works correctly.
- The popover could still open pinned to the top-left corner of the screen when the menu bar is set to auto-hide, when the status item is mid-reveal, or when the item is hidden behind the notch / collapsed into the overflow menu: the button exists and its local `bounds` are non-empty, so the previous `bounds.isEmpty` fallback never triggered, but the button's *window* has no valid on-screen position, and NSPopover falls back to the screen origin. Toki now checks the button's actual screen position (converting its bounds to screen coordinates and confirming they land on a connected display) and briefly retries until the status item settles before anchoring. When it never settles - the notch/overflow case, where retrying can't help because the item has no reachable position at all - the popover anchors to a transient 1x1 window parked just under the menu bar (on the screen under the pointer), so it opens near the top center instead of the corner. That anchor window is click-through and is torn down as soon as the popover closes.
- Active agent card navigation was only tappable on the label text area, not the full card surface. The navigate button's background styling was moved from the inner label to the outer card container and the quit button was moved to a sibling position alongside (instead of nested inside) the navigate button, so the whole card responds to click-to-navigate while the quit button works independently without triggering navigation.

## 2.3.0 - 2026-07-18

### Added

- Pi support (#16, by @thepushkarp) using local JSONL session metadata for token and estimated-cost usage, active-agent detection with session titles, and automatic session-root discovery without authentication or Toki account configuration.

## 2.2.1 - 2026-07-16

### Added

- Active agent cards now show memory usage (RSS, the same figure Activity Monitor's "Memory" column shows) alongside the host app.
- A quit button on each active agent card, with a confirmation dialog before it sends the process a terminate signal. Since the confirmation can sit open for a while (and PIDs get reused), it re-verifies the process still matches what was shown before actually signalling it, rather than trusting a possibly-stale PID.

## 2.2.0 - 2026-07-16

### Added

- A "What's new" page, reachable from a header icon, that renders this changelog inside the app. The popover is a bit wider to give the header room for the new icon.

### Changed

- Custom AI insight instructions now genuinely override Toki's default behavior instead of just nudging it. Several things were limiting how much a custom prompt could actually change the output: the instructions were composed after a fixed grounding rule and only given priority over tone/length, not format or content; the guided-generation schema declared its suggestions list with an exact-count guide, so the model was structurally forced to produce exactly 3 suggestions no matter what you asked for; the instructions text itself was only ever stated once, in an early system prompt, with the summary field's own guide referring to it abstractly rather than restating it; the summary field's guide description and property name both hardcoded "a summary of coding usage" as required content - schema-level constraints the model has to satisfy regardless of the system prompt; and the account/quota data was always handed over unconditionally as the thing to respond to, which a small on-device model anchors on hard even when told to ignore it. Custom instructions now lead the request entirely, account data is offered as optional reference the model is explicitly told it may disregard, and a separate, content-agnostic guided-generation schema (with a neutral `response` field instead of `summary`) is used whenever custom instructions are set.
- The AI insight instructions editor moved from its own page back into an expandable row inline in Settings, so editing a prompt doesn't lose your place in the rest of the list.

### Fixed

- The AI insight instructions box in Settings showed its placeholder text and real typing caret at slightly different positions, because the placeholder was drawn with hand-picked padding that didn't match SwiftUI TextEditor's own (private, undocumented) internal inset. It's now backed by a custom text view with an explicit inset that the placeholder matches exactly.
- Provider logos (menu bar icon and account cards alike) could get stuck showing the generic SF Symbol fallback instead of the real brand mark for the rest of the app's lifetime. The logo loader cached failed lookups exactly like successful ones, so if the very first attempt to load a given logo - which can happen as early as the menu bar status item's first render, before the rest of the app has finished starting up - ever came back empty for a transient reason, nothing ever re-tried it. Only successful loads are cached now.
- Provider logos and the new changelog page both failed to load when running from source via `swift run Toki` (the documented dev workflow) - none of their resource-lookup candidates reached the SPM-generated resource bundle that layout actually uses, so every logo showed its SF Symbol fallback and the changelog page always said "unavailable." Both now also check that bundle.

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
