# Features

## Agents

The Agents tab inspects the local process table without persisting command lines, prompts, workspace names, or session titles. Each agent shows its conversation title when available, otherwise the project folder name. OpenCode, Pi, and Claude Code agents also show the session's running cost and token counts.

Clicking an agent with a terminal TTY selects its tab in iTerm2 or Terminal; other hosts (VS Code, Cursor, ChatGPT) are activated by bundle ID.

**Agents waiting on you** are marked with a red dot and the question they asked — on the card, on the Agents tab, and in the menu bar. Supported for Claude Code and OpenCode. The signal is a tool call that has gone unanswered for at least ten seconds: a tool that is genuinely running writes its result promptly, so quiet time is what separates "working" from "blocked on you".

## Daily usage heatmap

Thirty days of activity, filterable by provider, covering Claude Code, OpenCode, and Pi. Read from each tool's own session history, so it reflects work done before Toki was installed. Hover a day for its detail.

The scale runs through 64 interpolated shades. Adjacent shades are deliberately *not* separately identifiable — that is what a spectrum is for — so exact figures stay in the hover line and the accessibility label. Colour carries the shape; text carries the value.

Days Toki could not read are distinguished from days with no activity. The first is a failure and says so; the second says "No usage".

## Live in the notch (experimental)

Off by default, notched Macs only. Puts the readout at the display notch instead of the menu bar, in one of three resting positions — hanging below, sideways beside it, or spread around both sides — expanding on hover. Clicking opens the popover anchored to the pill, so it appears on the side you actually clicked.

## Insights

A single card on the overview. On macOS 26+ with Apple Intelligence available it generates a natural-language summary with suggestions, marked by a purple sparkle. On older systems it shows the same deterministic recommendation with a lightbulb. Steer the prompt with `aiInstructions`, or the Settings page for custom instructions, which takes priority over the default tone and format.

## Notifications and session mode

Native low-quota and session warnings with cooldowns and a DND mode. DND suppresses delivery but still records events, so you can audit what would have fired — the Events tab shows this.

Session mode records starting quota for visible accounts, then shows a banner with a live stopwatch and per-account burn, logging warnings when quota drops sharply or crosses your threshold. Its toggle sits next to refresh in the header.

## Launch at login

Backed by `SMAppService`, reflecting what System Settings → General → Login Items actually says rather than a separate stored preference. macOS sometimes needs a freshly-added login item approved in that pane first; when it does, the toggle shows a "Needs approval" note linking straight there.

## Updates and diagnostics

Toki checks the latest public GitHub release every five minutes while running; Settings has a "Check now" that bypasses the schedule. An update banner you aren't ready to act on can be snoozed for six hours.

A newer release shows an Update button that downloads the DMG, verifies bundle identity, version, and code signature, stages the app, and replaces the installed bundle after Toki exits, then relaunches. Set `TOKI_MOCK_UPDATE_VERSION=9.9.9` to preview the banner while developing.

Rotating diagnostics go to `~/.toki/logs/toki.log` — error categories and status codes only, never credentials, config, prompts, session titles, workspace names, or full paths. "Send debug report" creates a local attachment and opens the share picker; nothing is sent automatically.
