# Toki

<p align="center">
  <img src="Sources/Toki/Resources/toki-logo.svg" alt="Toki logo" width="112" height="112">
</p>

<p align="center">
  <strong>A tiny macOS menu bar companion for AI coding agents and usage.</strong>
</p>

<p align="center">
  <img alt="Version 2.7.0" src="https://img.shields.io/badge/version-2.7.0-2f80ed">
  <img alt="Downloads" src="https://img.shields.io/github/downloads/aashutoshrathi/toki/total">
  <img alt="Stars" src="https://img.shields.io/github/stars/aashutoshrathi/toki">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111111">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-f05138">
  <a href="https://github.com/aashutoshrathi/toki"><img alt="Contribute on GitHub" src="https://img.shields.io/badge/contribute-GitHub-24292e?logo=github"></a>
</p>

<p align="center">
  <code>/toki</code> keeps your active AI coding accounts, current-session quota, and weekly quota one click away, and lets you answer a waiting agent from your phone.
</p>

| Menu bar | Widget |
|:---:|:---:|
| ![Toki menu bar popover preview](https://files.aashutosh.dev/toki-preview.png) | ![Toki macOS widgets preview](https://files.aashutosh.dev/toki-widgets.png) |


## Why Toki

Toki is built for people who jump between Claude Code, Codex, Cursor, Copilot, Gemini, Grok, OpenCode, Pi, Sarvam Code, Vercel's fx, and Google's Antigravity during the day and want a fast, local view of usage and active agents.

It works especially well with [`claude-swap`](https://github.com/realiti4/claude-swap): Toki discovers the same Claude Code account registry, shows active and inactive accounts, and lets you switch accounts without reimplementing credential-management logic.

Toki stays local. Credentials are read from your Mac, your configured commands, or provider auth files. The app does not run a cloud service.

When an agent is waiting on you and you are not at your desk, Remote Control lets your phone answer it over your own tailnet, typing into the terminal the agent is already running in.

## Install

### Homebrew

```sh
brew tap aashutoshrathi/tap
brew trust --cask aashutoshrathi/tap/toki
brew install --cask toki
```

The cask installs the latest release DMG. Toki is ad-hoc signed and not notarized, so macOS quarantines it. Clear the quarantine with:

```sh
xattr -dr com.apple.quarantine /Applications/Toki.app
```

The `-r` (recursive) is important: it also clears the bundled widget extension. Right-clicking Toki and choosing **Open** unblocks the app itself but leaves the nested extension quarantined, so macOS refuses to load it and the widgets stay blank — the recursive `xattr` is what makes the widgets work.

### Direct download

Grab the latest `Toki_<version>_universal.dmg` from the [releases page](https://github.com/aashutoshrathi/toki/releases/latest), open it, and drag Toki to Applications. Updates install in-app once running.


### From source

```sh
swift run Toki                # run in place
scripts/install-app.sh        # build a bundle and install to ~/Applications
```

## What it does

**Quota and spend.** Live rate-limit tracking for Claude Code (multi-account via `claude-swap`, with one-click switching) and Codex, a spend ring for Cursor read from your account, and local token and spend tracking for OpenCode, Pi, Sarvam Code, and Vercel's fx. Every spend figure carries the token count behind it, across today, this week, this month, and all time, and whichever provider you are actively running sorts to the top. Reported currencies are preserved; costs without a currency are treated as USD.

**Active agents.** Discovery across Codex, Claude Code, Cursor, Copilot CLI, Gemini CLI, Grok CLI, OpenCode, Pi, Sarvam Code, Vercel's fx, Google's Antigravity, and ChatGPT-hosted Codex, with best-effort navigation to the terminal tab or app hosting each one.

**Agents waiting on you.** A session parked on a permission prompt or a question is called out with a red dot and the question itself — on the card, the tab, and the menu bar — so you don't discover it twenty minutes later.

**Remote Control from your phone, over Tailscale.** Follow a running agent's transcript from another room and answer it: send a message, approve or reject a permission prompt, pick an option, switch the model it is running, mirror its terminal to watch and drive whatever is on screen, or clear the session. Each agent carries a badge naming the model it is on. Replies are delivered to the agent's own TTY — `tmux send-keys` where there is a pane, iTerm2 by tty otherwise, Terminal as a fallback — so they land in the session already running rather than starting a new one, and the agent cannot tell the difference. Tailscale is the recommended route and keeps this off the public internet entirely; the host setting decides which networks the server will answer at all. Off by default. See [Remote Control](docs/remote-control.md).

**Daily usage heatmap.** Thirty days, filterable by provider, read from each tool's own session history — so it covers work done before Toki was installed.

**Insights and notifications.** An on-device Apple Intelligence summary on macOS 26+ (deterministic recommendation elsewhere), low-quota and session warnings with cooldowns and DND, and a session mode for tracking burn during a focused run. The insight card can be hidden from Settings.

**Desktop widgets.** Small and medium macOS WidgetKit widgets put account quota, agents awaiting input, and break suggestions on your desktop or in Notification Center — plus a separate quota-rings widget for percentage-based accounts. They refresh from Toki's live data while it runs.

**Quota rings.** Provider-colored rings that show remaining percentage at a glance, in the Accounts panel and as the standalone macOS widget, with provider details on hover. On by default; hide them from the panel or Settings.

**Experimental notch mode.** Off by default, notched Macs only — moves the readout into the display notch, expanding on hover.

## Documentation

| | |
|---|---|
| [Configuration](docs/configuration.md) | Config file, accounts, labels, refresh cadence, state |
| [Providers](docs/providers.md) | Claude Code, Codex, Cursor, Pi, Sarvam Code, OpenCode, fx, and the detection-only ones |
| [Features](docs/features.md) | Agents, Remote Control, heatmap, widgets, quota rings, notch mode, insights, notifications, updates |
| [Remote Control](docs/remote-control.md) | Answering agents from your phone over Tailscale: setup, the three gates, paired devices, gotchas |
| [Development](docs/development.md) | Building, concurrency checking, conventions, troubleshooting |
| [Release signing](docs/release-signing.md) | Apple secrets for signing and notarizing release builds |

## Privacy

Toki stays local. Credentials are read from your Mac's Keychain or the provider auth files already on it; there is no cloud service and no telemetry. Session history is read for token counts, costs, timestamps, and titles — never message content. Diagnostics contain error categories and status codes only.

Remote Control is the one feature that reads message content, because showing you a transcript is the point of it. It is off by default. When it is on, the transcript travels from your Mac straight to your phone and nowhere else: there is no relay and no account. If you use the hosted companion interface, that host serves the page only and never receives your agent data — and serving the page from your own Mac instead removes it from the picture entirely, which is why that is the recommended setting.

Backwards-compatible fallbacks for the old TokenBar config paths are still honoured.

## License

Toki is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

Toki is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with Toki. If not, see <https://www.gnu.org/licenses/>.
