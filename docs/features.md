# Features

## Agents

The Agents tab inspects the local process table without persisting command lines, prompts, workspace names, or session titles. Each agent shows its conversation title when available, otherwise the project folder name. OpenCode, Pi, and Claude Code agents also show the session's running cost and token counts.

Clicking an agent with a terminal TTY selects its exact surface in iTerm2, Ghostty, or Terminal; other hosts (VS Code, Cursor, ChatGPT) are activated by bundle ID.

**Agents waiting on you** are marked with a red dot and the question they asked — on the card, on the Agents tab, and in the menu bar. Supported for Claude Code and OpenCode. The signal is a tool call that has gone unanswered for at least ten seconds: a tool that is genuinely running writes its result promptly, so quiet time is what separates "working" from "blocked on you".

## Remote Control

Follow a running agent from your phone and answer it: send a message, approve or reject a permission prompt, tap one of the options it offered, send a bare terminal key, or clear the session. Claude Code, Codex, OpenCode, Vercel's fx, and Google's Antigravity sessions are supported, each with its transcript on the phone. Off by default; turn it on in Settings.

**Replies go to the agent's TTY.** The same terminal discovery the Agents tab uses to jump to a session is what delivers input to it, in order of preference:

1. `tmux send-keys` against the pane whose `pane_tty` matches, where the agent runs under tmux.
2. iTerm2, addressed by tty through AppleScript, which does not steal focus or disturb the window you are looking at.
3. Ghostty, addressed by tty through AppleScript. This focuses the selected surface.
4. Terminal.app, by selecting the tab with that tty and sending keystrokes through System Events.

The text and the submitting Return are sent as two events with a short gap. Sent together, a TUI like Claude Code reads the trailing carriage return as part of the paste and inserts a newline instead of submitting.

Because this is terminal input, a reply lands in the conversation already running rather than starting a new one, and works with any agent whose interface is a terminal, including ones with no remote API of their own. It also means an agent without a TTY cannot be replied to: Codex desktop, editor extensions, and anything not attached to a terminal appear in the list as **read-only**, grouped below the ones you can answer so the agent actually waiting on you is the one selected by default.

**Reach is a setting, not a side effect.** The host you pick decides which networks the server will answer, enforced per connection before authentication:

| Host | Answers requests from |
|:---|:---|
| Localhost | this Mac only |
| Tailscale (recommended) | your tailnet, plus this Mac |
| Local network | your LAN and tailnet, plus this Mac |
| Cloudflare Tunnel (public) | the tunnel process on this Mac |
| Custom | anywhere, since Toki cannot classify the host you named |

Tailscale is recommended because it is private by construction: your Mac and phone join a network only your devices are on, and nothing is reachable from the public internet. A phone connects by scanning a QR code and entering a six-digit code shown on the Mac, which rotates every two minutes; that exchange grants a session lasting between one hour and two days, and every paired device is listed in Settings with its own Revoke button.

[Remote Control](remote-control.md) covers the setup, the gates in full, and the gotchas.

## Daily usage heatmap

Thirty days of activity, filterable by provider, covering Claude Code, OpenCode, Pi, and Sarvam Code. Read from each tool's own session history, so it reflects work done before Toki was installed. Hover a day for its detail.

The scale runs through 64 interpolated shades. Adjacent shades are deliberately *not* separately identifiable — that is what a spectrum is for — so exact figures stay in the hover line and the accessibility label. Colour carries the shape; text carries the value.

Days Toki could not read are distinguished from days with no activity. The first is a failure and says so; the second says "No usage".

## Desktop widgets

Two macOS WidgetKit widgets, each in small and medium sizes, live on the desktop or in Notification Center:

- **Toki Usage** shows account quota, a badge counting agents awaiting input, and — when every tracked account is exhausted — a break suggestion.
- **Toki Quota Rings** draws concentric provider-colored rings for percentage-based accounts (Claude Code, Codex), with the Toki mark at the center.

Toki writes a compact, privacy-safe snapshot (provider labels and percentages only — never account names or emails) and asks WidgetKit to reload after usage or attention changes. A widget whose snapshot is older than five minutes falls back to an "Open Toki" prompt, so the readout is never silently stale. Properly signed release builds share the snapshot through the App Group; ad-hoc local builds route it through Toki's Application Support folder instead, which the extension reads with narrowly scoped read-only access.

## Quota rings

On by default. The same provider-colored rings render inside the Accounts panel, showing remaining percentage at a glance and revealing the provider and live percentage on hover. Hide them with the button on the panel or the toggle in Settings. The standalone macOS widget above is enabled independently through the system widget gallery.

## Provider outages

When a provider reports trouble on its own status page, the account card says so: a coloured dot on the account logo, and, once the card is open, a line naming what is down with a link to the page. A provider that is operational shows nothing.

Toki reads the public Statuspage summaries that Claude, OpenAI, GitHub, and Cursor publish, unauthenticated and at most once every five minutes, and only for providers you actually have, so a Claude-only install never calls OpenAI's page. Each provider is matched to its own components (Codex covers Codex API, Codex Web, and Codex in ChatGPT Desktop), so an unrelated outage elsewhere on the same page, Sora for instance, is never reported as yours. A provider the page does not break out falls back to that page's overall state. Every change lands in the Events tab.

## Live in the notch (experimental)

Off by default, notched Macs only. Puts the readout at the display notch instead of the menu bar, in one of three resting positions — hanging below, sideways beside it, or spread around both sides — expanding on hover. Clicking opens the popover anchored to the pill, so it appears on the side you actually clicked.

## Insights

A single card on the overview. On macOS 26+ with Apple Intelligence available it generates a natural-language summary with suggestions, marked by a purple sparkle. On older systems it shows the same deterministic recommendation with a lightbulb. Steer the prompt with `aiInstructions`, or the Settings page for custom instructions, which takes priority over the default tone and format. The whole card can be hidden from Settings, which also stops its background generation.

## Notifications and session mode

Native low-quota and session warnings with cooldowns and a DND mode. DND suppresses delivery but still records events, so you can audit what would have fired — the Events tab shows this.

Session mode records starting quota for visible accounts, then shows a banner with a live stopwatch and per-account burn, logging warnings when quota drops sharply or crosses your threshold. Its toggle sits next to refresh in the header.

## Permissions checklist

Toki needs a handful of unrelated permissions, and each one used to arrive as a side effect of
something else: the Keychain dialog when the menu was first opened, Automation the first time an
agent row was clicked, Local Network when Remote Control started. They are now a checklist —
during onboarding, and permanently under **Settings › Permissions** — listing what each one is
used for and what it costs to skip.

Nothing on the list is requested until you press its button. The statuses are read with checks
that never prompt, so the list can tell you where you stand before asking for anything. A
permission you refused earlier is marked as refused and sends you to System Settings, since macOS
will not ask a second time.

A **first run lists everything Toki will ever ask for**, including the permissions that only matter
once you use the feature behind them, and **Allow all** requests them in one pass — one dialog at a
time, with Accessibility last because answering that one means a trip to System Settings. Refusing
any of them only turns off what it was for. The list stays until you have worked through it or
put it away, so connecting an account does not sweep it off screen halfway through.

Afterwards the same list becomes a status board under Settings, and shows only what applies to
this Mac right now: Automation lists the terminals you actually have installed, Accessibility
appears while an editor whose windows Toki raises is running, Local Network while Remote Control
is on.

Local network is the one Toki cannot bring forward: macOS asks for it when the server first
answers a device, so the checklist explains when to expect it rather than offering a button that
could not do anything.

On a fresh install Toki no longer reads Claude Code's sign-in out of the Keychain until the
checklist's Keychain row is used, so opening the menu for the first time raises no dialog. A Mac
that already has accounts connected is past that point and keeps picking up new sign-ins
automatically.

## Launch at login

Backed by `SMAppService`, reflecting what System Settings → General → Login Items actually says rather than a separate stored preference. macOS sometimes needs a freshly-added login item approved in that pane first; when it does, the toggle shows a "Needs approval" note linking straight there.

## Updates and diagnostics

Toki checks the latest public GitHub release every five minutes while running; Settings has a "Check now" that bypasses the schedule. An update banner you aren't ready to act on can be snoozed for six hours.

Settings > Updates also has a channel picker. Stable (the default) only ever offers full releases. Beta additionally offers GitHub pre-releases — early builds of the next version, published for testing before they ship. When a beta version is finalized as a stable release, beta users are offered that release like everyone else, so staying on the Beta channel never strands you on an abandoned build.

A newer release shows an Update button that downloads the DMG, verifies bundle identity, version, and code signature, stages the app, and replaces the installed bundle after Toki exits, then relaunches. Set `TOKI_MOCK_UPDATE_VERSION=9.9.9` to preview the banner while developing.

Rotating diagnostics go to `~/.toki/logs/toki.log` — error categories and status codes only, never credentials, config, prompts, session titles, workspace names, or full paths. "Send debug report" creates a local attachment and opens the share picker; nothing is sent automatically.
