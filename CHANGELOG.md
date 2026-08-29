# Changelog

## Unreleased

### Added

- **Pin exactly which providers the menu bar shows.** The old Claude and Codex modes were hardcoded to two providers out of the fifteen Toki tracks, so a Cursor-only or Gemini-only setup had nothing to choose. Pinned works for any connected provider, draws them in the order you pin them, and skips a pin whose account is not connected. If you pin nothing it falls back to Smart rather than leaving an empty status item.
- **A Logo only mode, for a menu bar that is already full.** Toki drops to its mark and nothing else, about a quarter of the width of the full readout, with every number still one click away in the panel. It is the same mark the panel header draws, so the two finally match.
- **A size setting for the menu bar readout.** Comfortable is what Toki has always drawn. Compact shrinks the glyphs and numbers and drops the percent sign. Stacked puts two providers on two half-height rows, roughly halving the width, in the style of apps like Stats; going vertical saves enough on its own that it keeps the percent sign. Size is independent of what the menu bar shows, so every mode can run at every size.
- **A beta build says which beta it is.** The version pill read the same on a prerelease as on the stable it came from, because the marketing version has to stay dotted-numeric and the suffix lives elsewhere. A prerelease now carries a badge beside the version naming it, so a bug report can say which build it came from.
- **The menu bar tells you when a pin will not fit.** Comfortable and Compact draw three providers, Stacked draws two, and the status item competes with every other icon on the bar. Once you reach the limit the remaining providers dim and say which size you are on and what it fits, instead of accepting a pin that then quietly never appears. Changing size with more pinned than the new one fits marks the extras rather than silently shortening the readout.

### Changed

- **Recent and weekly quotas share one compact account-card view.** Claude Code and Codex now show every applicable rolling window side by side, including reset countdowns when provided, while plans that expose only one window keep the single-window layout and Codex reset credits stay directly beneath it.
- **The menu bar mode list is current again.** Claude + Codex ran the identical code path to Smart, so it was two menu entries for one behaviour, and Accounts drew an anonymous grey dot and a count that told you less than any other mode. Both are gone. Existing settings carry over: Claude and Codex become pins for those providers, Claude + Codex and Accounts become Smart.
- **Settings are grouped into sections that say what they are.** Remote Control and Permissions were two unlabelled cards stacked directly on each other, reading as one long card; they now lead the panel with headers of their own. Show AI insight and Show quota rings move into a new Layout section under General. Remote Control is the tallest card in the panel and gets a roomier rhythm to match.
- **Remote Control wears a joystick.** The antenna glyph is now an arcade stick, in all three places the feature appears: its Settings card, the panel header button that opens it, and the menu bar indicator that shows the server is running.

### Fixed

- **What's New reads as prose instead of markup.** The changelog is authored as markdown and every entry leads with a bold summary, so the panel was showing the asterisks, backticks, and link brackets as literal text. Inline formatting now renders, contributor links included.
- **What's New and Quit Toki respond to the pointer.** They were system menu items, which keep the arrow cursor and the system highlight, so they were the only controls in the panel without the pointer and hover treatment everything else has.
- **The permissions card stops repeating its own name.** Its collapsed row leads with how many permissions are granted, and the note about a test notification clears once it stops describing something that just happened.
- **Separators inside a settings card line up with the ones between cards.** The dividers within the notch card were inset differently from the card separators above and below them, so they visibly overhung on the left and fell short on the right.

## 3.0.0 - 2026-08-27

### Added

- **Sarvam Code joins usage tracking.** Toki auto-detects the CLI and reads token activity from its local session history without loading transcript content. Its card, active-agent list, spend view, heatmap, and widgets use the official Sarvam mark; cost fields preserve their reported currency, fall back to USD when unspecified, and show `$0.00` when Sarvam has not logged a cost.
- **Sarvam Code sessions in Remote Control.** A running `sarvam-code` CLI now shows up on your phone like Claude, Codex, and OpenCode do: its transcript streams live, permission prompts surface as attention alerts, the model badge reads the session's current model, and the Model button opens its `/model` picker. Sarvam Code shares Codex's session format, so its sessions resolve from `~/.sarvam/sessions` (honoring `SARVAM_HOME`) through the same reader.
- **Token counts sit beside the money in the spend view.** Every Today, Week, Month, and All Time block in Analytics now shows the tokens behind the figure, and each cost-tracked card carries today's count next to its spend, so a quiet bill reads as either a quiet day or a cheaper model rather than being ambiguous.
- **Change an agent's model from your phone.** The companion app's composer has a Model button that opens the running CLI's own model picker (`/model`, or `/models` for OpenCode) and mirrors it live on your phone, so you choose with the same arrow, Tab, and Enter controls you already answer prompts with. It works for Claude, Codex, OpenCode, fx, and Antigravity, wherever Toki can read the terminal (tmux, iTerm, or Terminal).
- **Each agent shows the model it is running.** A small badge next to every agent's name in the companion app reads the current model from the provider's own session (best-effort for Antigravity), so you can tell at a glance what each one is on.
- **Slash commands from the companion open the CLI's own view.** Sending `/usage`, `/help`, or any slash command from the composer now mirrors the screen it draws and lets you drive it with the key footer, the same way the Model button does, instead of sending it as a plain reply that leaves the phone waiting on an answer that never comes. A message that reads as a file path with a directory in it, like `/Users/me/notes.txt`, is still sent as text.
- **Mirror any agent's terminal from your phone.** A new Screen button on the composer opens a live mirror of whatever the agent's terminal is showing, for every app Toki can read (tmux, iTerm, Terminal), without sending a command first. Whatever picker or prompt is on screen, you watch it and drive it with the arrow, Tab, Enter, and Esc footer, so the mirror is no longer limited to the model picker and slash commands.

### Fixed

- **Antigravity clarifying questions are answerable from your phone, options and all.** When an Antigravity (`agy`) session asks a question (`ask_question`), the phone shows every question with its options, single- or multi-select, instead of a blank panel; before, its attention parser only recognized approval-gated commands, so a pending question left the agent stuck. You make your picks and hit Submit, and Toki drives Antigravity's own picker with the exact keystrokes it expects (a single-select number selects and advances, a multi-select toggles and Enter submits), so multi-question and multi-select prompts answer correctly.
- **Antigravity permission prompts reach Remote Control.** A pending approval in an Antigravity (`agy`) session now surfaces on your phone the way Claude, Codex, and OpenCode prompts already do. Its attention was being read through OpenCode's path, which expects a session id rather than a transcript, so the prompt never appeared.
- **The mirrored picker shows its colors, so OpenCode's model list is usable.** The companion mirrors a CLI's own picker by capturing its terminal, but it was dropping color, and OpenCode marks the selected row only with a highlight color, not a text cursor, so the phone showed a list with no visible selection to move. The mirror now keeps and renders terminal color, so the highlighted row reads clearly (as do OpenCode's two-step model and variant dialogs); Claude and Codex pickers, which already drew a text cursor, just gain their real colors.
- **Codex approval prompts show the real command.** A pending Codex approval on your phone now reads the actual command text, including unified-exec calls that carry it in `input` rather than `arguments`, instead of a blank summary. A running `wait` poll is also no longer mistaken for a pending approval, so the prompt only appears when Codex genuinely needs an answer.
- **Codex signs in through its own credential store.** A Codex account backed by the macOS Keychain (`cli_auth_credentials_store` set to `keyring` or `auto`) is now detected and refreshed without an `~/.codex/auth.json` on disk. Toki lets the Codex app-server resolve whichever store is configured instead of preflighting the auth file, so a valid Keychain-only login is no longer rejected, and the access token stays inside Codex. File-backed profiles still work through `codexAuthPath`/`CODEX_HOME`.
- **Auto-detected providers can be renamed.** Pi, OpenCode, fx, Sarvam Code, Cursor, and Antigravity are detected rather than configured, so there was no saved entry for a new name to land in and the card quietly reverted whatever you typed. The first rename now writes that entry, keeping the account's existing history and usage.
- **The provider you are using ranks above the ones you are not.** Cost-tracked providers have no quota percentage to sort by, so they fell back to the fixed order Toki detects them in, and a running Sarvam Code sat below an idle Pi no matter what you did. A live session now breaks that tie, without letting it outrank quota headroom or lift an errored card up the list.
- **OpenCode's token count no longer reads far too low.** It counted only input and output while Pi and fx also include cache reads and writes, and all three add into the same total, so OpenCode came in roughly 28x under: 9.6M tokens against 275.2M actual on a real database. Databases predating the cache columns still aggregate instead of blanking the panel.
- **Token totals follow the currency each provider bills in.** They were pinned to the USD row, so an install billing in something else (Sarvam Code in INR, say) grew a phantom USD row reading `$0.00` for every period beside the real one. Each provider's tokens now land on its own currency row, and the four blocks in a row keep a matching height when only some periods have usage.
- **Session Costs stays inside its panel.** The donut's legend wrapped onto several lines once eight or more sessions were running and overlapped both the chart and the list under it. That list already names every session with its logo, cost, and token count, so the legend is gone and the list scrolls within a fixed height rather than pushing the spend blocks and quota chart out of view. Sessions are ordered costliest first.

### Thanks

[@thepushkarp](https://github.com/thepushkarp) contributed Sarvam Code usage tracking and the Codex Keychain sign-in fix.

## 2.7.0 - 2026-08-20

### Added

- **Antigravity and fx join the roster.** Toki detects Google's Antigravity (`agy`) and Vercel's `fx`, each as a card on the main page and a live row in the Agents tab while a session runs. Antigravity has no usage API, so its card reads "No usage API available" like Cursor and Grok; fx gets a real usage card with today, this-week, and this-month token spend read from its local ledger, plus the AI Gateway credit balance.
- **Antigravity and fx agent rows show the conversation's name.** Both resolve the session title and last activity from each tool's local index (fx's session index, Antigravity's live history log), so their rows read the chat title rather than the folder and sort by recency alongside every other agent.
- **Cards sort by recent activity.** The account cards now order by the most recent activity of their sessions, so whatever you touched last floats to the top.
- **No-usage-API cards open to their sessions.** Providers with no usage API (Grok, Cursor when signed out, and the like) read "No usage API" collapsed and expand straight to their linked sessions, skipping the empty Usage tab. The expanded usage headline is also toned down to match the rest of its row.
- **The companion's typing indicator counts up.** While an agent works on your reply, the typing dots now show elapsed time, so a long task reads differently from a stalled one.
- **The companion's usage list skips no-usage-API accounts.** Providers with nothing to report (Grok, Cursor when signed out, and the like) no longer clutter the phone's usage dropdown.
- **The companion composer follows ChatGPT/Claude.** Attach and send now live inside one rounded input that grows upward as you type, over a glass footer, instead of buttons flanking a boxed field.
- **The menu bar shows when Remote Control is on.** A small broadcast glyph sits in the status item while the companion server is accepting connections, and clears when you stop it.
- **The pairing code counts down to its rotation.** The verification code on the connect sheet now shows a live shrinking bar and seconds until it rotates, like an authenticator app, instead of a static "rotates every 2 minutes" note.
- **The companion app sees Antigravity and fx sessions.** Both now surface on the phone with their own logos and their conversation transcripts (fx's session events, Antigravity's brain log), and their terminals accept typed replies and keypresses like Claude, Codex, and OpenCode sessions do.
- **Cursor is detected from its desktop app, not just the CLI.** The Cursor card now appears when Cursor.app is installed, so desktop-only users see it without the `cursor-agent` CLI on their PATH.
- **Cursor shows real usage with a spend ring.** When you are signed into Cursor, the card reads your usage from cursor.com: spend this cycle against your plan's limit as a health ring, plus token counts and the cycle reset, alongside your plan tier. Since the desktop agent has no separate process, the card also reads local AI-edit and chat activity to show Active and sort by recency, and falls back to that when signed out.
- **Permissions are a checklist, not a series of surprises.** Every macOS permission Toki needs is one list, in onboarding and permanently under **Settings › Permissions**, each explained and read with a check that never prompts. Nothing is requested until you press its button.
- **Allow all.** First run can request every permission at once, one dialog at a time with Accessibility last; refusing one only disables what it was for. The list includes starting Toki at login, and a refused permission offers System Settings instead of an **Allow** button macOS would ignore.
- **Quota on your phone.** The companion app shows the account with least left, expanding to the full list on tap, from the same reading the Mac renders; a reading the Mac stopped refreshing says so.
- **Tool calls in the companion app show progress.** Calls appear in flight, then succeeded or failed, with how long they took and a line saying what the call is doing. Output stays on the Mac.
- **Tappable links in the companion app.** Every message linkifies bare URLs (agent replies, approval prompts, your messages, tool targets); only `http`/`https` are linked, a URL inside code is left as text, and trailing punctuation stays out of the link.
- **Multi-question, multi-select prompts.** The phone now answers OpenCode's `question` tool and Claude's AskUserQuestion, showing each question with its options and turning your picks into the exact keypresses the picker needs. Before, a multi-select was mistaken for a plain approval and could not be answered at all.
- **Send an image from your phone.** A reply can carry a picture from your library, camera, or clipboard; Toki saves it on your Mac and references its path so an image-reading agent picks it up. Image files only, and to your Mac only.
- **The browser tab names the Mac and the chat** (`<Mac name> - <chat title>`), so tabs across Macs and conversations are distinguishable from the tab strip alone. It follows the privacy toggle.
- **Leaving a paired session asks first**, so the companion app's Home button no longer drops pairing on an accidental tap. The connect screen's Home, with no session to lose, still goes straight back.

### Changed

- A fresh install no longer raises the Keychain dialog just from opening the menu; reading Claude Code's sign-in now waits for the checklist's Keychain row. A file-based sign-in is still found either way.
- Toki turns on Tailscale HTTPS itself, running `tailscale serve` once per start rather than reporting it as off and waiting for a click. A handler already serving :443 is left alone.

### Fixed

- The companion app keeps its session when you close the browser; it now lasts as long as the Mac says, and a 403 no longer ends a session by itself.
- `tailscale serve` detection now distinguishes `localhost`, IPv6, and shared serves from genuinely not serving, and an unreadable status from an empty one.
- Auto-serve no longer gates on the Mac's `.ts.net` name, so it runs on Macs whose Tailscale ships no usable CLI, takes the name from serve's own config, and says when it declines.
- The permissions checklist reports what it actually checked: Automation behind a closed terminal, Keychain, and test notifications no longer claim a success macOS never confirmed, and each offers a retry.
- Codex quota works with only the Codex app installed, falling back to the `codex` CLI inside `Codex.app` when none is on `PATH`. A `PATH` install still wins, and a broken one is named instead of quietly skipped.
- An agent's transcript and name follow the live conversation across `/clear`, chat switches, and rollovers; sessions are now assigned per project folder so no two agents share a file.
- The companion server stops trusting a snapshot forever: past 90 seconds it treats the pipe as quiet and discovers agents itself.
- The Enable-HTTPS button appears for a hand-typed host too, not only when `tailscale status` yields a DNS name, and hands over the command to run where no `tailscale` exists.
- A `tailscale serve` refusal names its fix (not the tailnet operator, no HTTPS certificates, signed out) with a copy button instead of raw stderr.
- Enabling HTTPS shares the timeout and force-kill handling of every other `tailscale` call, and each Claude agent's session is resolved once per scan instead of four times.

## 2.6.1 - 2026-08-08

### Fixed

- **A Claude Code account no longer reads "Not connected" just because Claude Code has not run for a while.** Toki sent whatever access token was sitting in the Keychain without ever looking at the `expiresAt` beside it. Claude Code renews that token lazily, when it next runs, so overnight the stored token goes stale and every Toki refresh replayed it and collected an HTTP 401. Toki now checks the expiry first and skips the request entirely when the token is past it, showing "Signed out" with what to do about it rather than a raw `authentication_error` payload.
- **Toki recovers on its own the moment the token is renewed.** An expired token records no API call, so the usual refresh interval never gates the retry: the next tick, or opening Toki, re-reads the Keychain and picks up a token Claude Code has just renewed. That re-read is local and costs nothing until the sign-in is usable again.
- A stored `claude-swap` account that is not the active one says so plainly. Nothing renews the copy Toki reads for an inactive account, so it expires within hours of being stored and stays that way; the card now points at `claude-swap` instead of reporting a failure with no remedy.
- Repeatedly replaying a dead token no longer gets the usage endpoint to rate-limit the account, which used to hide the real state behind a stale reading once the 401s turned into 429s.
- An error whose request ID happens to contain "429" is no longer misread as a rate limit. The check matched that substring anywhere in the response body, so an unrelated failure could be quietly papered over with the previous snapshot instead of surfaced.

## 2.6.0 - 2026-08-08

### Security

- **The Remote Control host setting now decides who can reach the server, not just what the Connect link says.** The companion server listened on every network interface regardless of the host you picked, so choosing **Localhost** or **Tailscale** still left its port open to whatever Wi-Fi the Mac had joined; only the link token stood in the way. Each host mode now carries an access policy the server enforces on every connection: **Localhost** and **Cloudflare Tunnel** answer this Mac only, **Tailscale** answers your tailnet, **Local network** answers your LAN and tailnet. Changing the host restarts the server so a narrowed setting takes effect immediately, which also ends any paired sessions.
- The companion server answers only to the addresses Toki hands out, so a hostname someone else controls cannot be pointed at your Mac and treated as same-origin by a browser. A **Custom** host is trusted once you name it.
- Replies and pairing attempts are rejected unless they come from the companion app itself or a non-browser client, closing the cross-origin POST that CORS preflight does not cover.
- Session tokens travel in an `Authorization` header instead of the URL, keeping them out of your phone's history and out of the request logs of anything between the phone and the Mac (Cloudflare's, on the tunnel path). The companion app also clears the token from the address bar once it has been stored.
- **A proxy cannot smuggle the public internet past the host setting.** `tailscale serve` relays from this Mac, so its requests arrive looking local. Tailscale **Funnel**, or any other reverse proxy pointed at the port, looks identical. Toki now applies the host setting to the address the proxy says it is relaying for, so a public request is refused under **Tailscale** or **Localhost** instead of admitted for having arrived over loopback. **Cloudflare Tunnel** is the one exception, because relaying the internet to your Mac is what that option is for. Only a proxy on this Mac is believed; a direct caller cannot claim an address with a header.
- A single reply is capped well below the request-body limit, so one call can no longer push a quarter-megabyte of keystrokes into a terminal. Sessions and the failed-pairing table are capped too, and a malformed `pid` or `offset` no longer drops the connection mid-poll.

### Added

- **Paired devices, with per-device revoke.** Settings now lists every phone currently holding a Remote Control session, showing the name its browser reports, the random ID Toki assigned it at pairing, where it connected from, and when it was last seen. **Revoke** ends that one session immediately and leaves your other devices alone; previously the only way to cut off a device was stopping the server on all of them. The list travels over Toki's private pipe to its server, never over HTTP, so a paired phone cannot enumerate your other devices or revoke them. Where a request came through `tailscale serve` or `cloudflared` the address reads "via proxy" rather than claiming an address Toki cannot actually know.
- A guide covering Remote Control setup, the three gates a phone passes to connect, what each host option exposes, and the gotchas worth knowing. An info button beside the Remote Control heading in Settings opens it.

### Changed

- **Toki now recommends the options with no third party in them.** Serving the companion app from your own Mac ("Same as host") is the recommended App choice rather than the hosted `rc.toki.aashutosh.dev` interface, which is now labelled "Toki RC (hosted)". The hosted page never receives your agent data, but it is still code loaded from a web server and handed your connection token, and serving it from your Mac removes that exposure instead of mitigating it.
- **Cloudflare Tunnel is presented as the last resort it is.** It is labelled "public", offered last in the Host list instead of first, and Toki warns while it is selected. A quick tunnel puts your Mac behind an address anyone on the internet can reach; Tailscale keeps it off the public internet entirely and is recommended everywhere the choice comes up.

### Fixed

- The Remote Control server no longer stalls on startup behind a reverse DNS lookup. Python's HTTP server resolves the address it just bound before serving anything, which on a network whose DNS does not answer (a captive portal, a hotel) left Toki with a server that had launched and gone quiet, showing no Connect link and no error. Nothing used the resolved name.
- Changing the Remote Control host while the server is running restarts it reliably. The replacement used to race the outgoing process for the port and could exit immediately, leaving Remote Control off. The custom host field is now fixed while the server runs, matching the session lifetime, since the running server is told which host to answer to when it launches.
- A multi-line reply sent from the companion app reaches agents running in iTerm2 and Terminal. The newline broke the AppleScript that delivers it, so the message was silently lost; agents in tmux were unaffected.

## 2.5.4 - 2026-08-07

### Added

- **Remote Control (#64): follow and reply to your agents from your phone.** Toki can run a local Remote Control server and pair a browser over Tailscale (recommended), your local network, or this Mac, using a six-digit code that rotates every two minutes and a scoped session you can limit from 1 hour up to 2 days. The web app lists the same active agents as the menu bar, streams their transcripts with GitHub-style Markdown tables, and lets you reply, send terminal keys, and approve or reject prompts; non-terminal sessions such as Codex desktop are clearly read-only. It installs as a phone app (PWA) with an offline-capable shell and Add to Home Screen, and you can start a session by scanning the Connect QR or entering a host and token by hand. Agent data stays between your browser and your Mac; the hosted interface only serves the UI. A teal status icon in the header opens the Remote Control settings while the server is running.
- **Connect from anywhere over Tailscale.** An info button beside the Host picker walks through the one-time setup (MagicDNS, HTTPS certificates, and `tailscale serve`), with the links and a copyable command you need. A live reachability indicator tells you whether your phone can actually reach this Mac, or that `tailscale serve` still needs to start, instead of handing you a QR that silently fails. An "Enable HTTPS access" button starts `tailscale serve` for you and re-checks reachability, warning you first if Tailscale already serves another app on 443. When your Tailscale name can't be read automatically you can type it in, so the Connect link and QR use your real `.ts.net` host; the name is remembered on this device.
- New **Cloudflare Tunnel** host option (when `cloudflared` is installed) gives you a public HTTPS address with no Tailscale, account, or DNS setup.
- The companion app can notify you when an agent needs your input or approval, with a one-tap prompt to turn alerts on. (Notifications fire while the app is open or backgrounded.)
- The companion app has an eye toggle in the header that masks agent names in the picker, handy for screen recordings.
- The companion app's agent picker now shows the folder each agent is working in, under its title, with your home folder written as `~`. Several agents often carry the same title (or none worth reading), and the folder is what tells them apart. The eye toggle masks the folder along with the name.
- A **Clear** button beside Send in the companion app sends `/clear` to the agent, so you can drop a finished conversation and free up its context from your phone. Clearing can't be undone and the button sits next to Send, so the first tap arms it and a second tap within five seconds does it.
- An Edit menu, so text fields across the app support the standard Cut, Copy, Paste, and Select All shortcuts. The menu-bar app previously shipped none, so Cmd+V did nothing.

### Changed

- Remote Control settings lead with a single **Reach** choice, "On my network" or "From anywhere", with the detailed host and app options tucked under Advanced.
- The companion app interface got a visual refresh built on a cohesive color system: layered surfaces with hairline borders, chat-style message bubbles, a brand-teal "private by design" note, a subtle background grain, and refined buttons, inputs, and code blocks for a cleaner, more legible read on the phone.
- The companion chat now feels immediate: your message appears the instant you send it (with a subtle typing indicator while the agent replies) instead of waiting for the next poll, and sending refreshes the transcript right away. Answering a question or approving a prompt dismisses it at once, and a message that fails to send can be resent with a tap.
- The companion app renders an agent's question and its choices more clearly, with a labeled header and numbered options.
- Debug mode (now seven taps on the version badge) mirrors the diagnostic log live in the in-app debug panel, so agent, usage, and Remote Control events are visible without exporting a report.
- The companion app's agent picker now lists every agent you can reply to before the read-only ones, which are grouped at the bottom under a single "Read-only" heading. A busy read-only session (Codex desktop and the like) used to sort to the top on recency and get selected by default, putting a session you can only watch in front of the one waiting on you.

### Fixed

- A Claude or Codex account that won't connect now tells you what to do about it. "No Claude Code OAuth access token found" named nothing you could act on and was truncated to "No Claude Code OAuth access token fo…" in the card, so the fix was guesswork; the message now says which places Toki looked, what it found in each, and that the sign-in it needs comes from running `/login` in Claude Code (installing the CLI alone doesn't produce one, and an API key or Bedrock/Vertex setup produces none at all). Codex does the same, naming the auth file path it couldn't find instead of just "Codex auth file not found". Credential values are never included, only the names of the fields that were present.
- Toki now finds a Claude Code sign-in that isn't where it usually lives. It reads the Keychain item under your username, under the macOS account name when those differ, and then under any account at all (for an item filed under a name Toki can't work out), before falling back to `.credentials.json` in `$CLAUDE_CONFIG_DIR`, `~/.claude`, `$XDG_CONFIG_HOME/claude`, and `~/.config/claude`. Those two variables are usually set in a shell profile that a Finder-launched app never sees, so Toki asks your login shell for them once and remembers the answer.
- The credential file Toki now searches for is checked before it is trusted, because what comes out of it is sent to Anthropic as your access token. Toki skips a candidate whose path isn't absolute or contains control characters, and refuses a file that is a symlink, isn't a regular file, is owned by another user, is writable by anyone but you, or is far too big to be a credentials file. One that is merely readable by others still works but is noted in the diagnostic log.
- An agent CLI installed through a version manager (nvm, fnm, volta, bun, pnpm, mise, asdf) is no longer missed. Toki runs these through a login shell, which reads `.zprofile` but not `.zshrc`, and that is where those tools put themselves on `PATH`; their bin directories are now searched too, so Codex stops reporting `command not found: codex` on a machine where your own shell runs it fine.
- Hardened the Remote Control companion server as defense in depth: its web app is now served with a strict Content-Security-Policy (plus `X-Content-Type-Options`, `Referrer-Policy`, and frame-denial headers), and request bodies are capped, so the surface that can inject terminal input stays locked down even if a rendering bug ever slipped through.
- Sending a message to a terminal agent no longer occasionally inserts a newline instead of submitting: the message text and the Enter that submits it are now delivered as separate keypresses, which agents like Claude Code need to treat the Enter as "send".
- Scanning Toki's Connect QR from inside the companion app works again. A scanned link is now saved before the reload that applies it, so it survives on an installed home-screen app, where a reload comes back at the app's start address and the freshly scanned link used to be lost; this also affected entering a host and token by hand. Separately, the scanner only accepted a code pointing at the exact page you were already on, so a direct Tailscale link (`https://<your-machine>.ts.net/?token=…`) scanned on the hosted Toki RC interface, or a Toki RC link scanned on the Mac's own page, was refused even though both name the same Mac. Either link now connects. A local-network link still can't be used from the hosted interface (an HTTPS page cannot call a plain-HTTP address), but it now says which address it couldn't reach instead of calling the code invalid.
- Remote Control now shows each agent's own transcript when several agents run in the same folder, instead of occasionally attributing one agent's conversation (and your reply) to another.
- The companion app no longer shows a stale conversation after an agent starts a new session. It tracked its place in a transcript by byte offset and only noticed a switch when the new transcript was shorter than that offset, so a session that overtook it between two polls left the old messages on screen and skipped the start of the new one. The server now names the transcript an offset belongs to, and the app starts over whenever that name changes.
- The installed companion app (Add to Home Screen) reopens to your saved connection instead of an "invalid link" screen after it has been closed.
- The companion app can no longer strand you on the verify screen. A link pointing at a Tailscale address your phone can't currently reach left the app asking for a six-digit code with no way back, and because the link is remembered on the device and repeated in the address bar, reloading or reopening the app only restored it. A home button is now always on screen (in the header once connected, on the connect screen otherwise) and starts you over on the landing page, where you can scan a fresh QR or type a different host.
- The companion app layout no longer drifts on iPad and other large screens: the shell is pinned to the viewport height with the transcript scrolling inside it, so the header and reply bar stay put while the composer no longer creeps up the page.
- Remote Control "From anywhere" now always shows the Connect QR when Tailscale is up, pointing the phone straight at this Mac's Tailscale address with the session token in the URL (`https://<your-machine>.ts.net/?token=…`). When the MagicDNS name can't be read it falls back to the tailnet IP so the QR and its verification code still work, and settings now explain why the name was unreadable (command not found, not signed in, or MagicDNS off) instead of failing over quietly. Detection also looks in more locations for the `tailscale` CLI and searches a real PATH, so the name is found on more setups.
- Remote Control settings no longer keep telling you MagicDNS is off after you've dealt with it. The "Turn on MagicDNS, or enter the host by hand" warning stayed on screen even once a valid `.ts.net` name had been typed into the box right below it, and Toki was already using that name for the Connect link; it now clears as soon as the name is usable. The warning was also the fallback for every way of failing to read a Tailscale name, so an unreadable or unexpected `tailscale status` was reported as "MagicDNS is off" whether or not it actually was. Each case now says what really happened, and the underlying reason is recorded in the diagnostic log.
- Tailscale lookups can no longer wedge the app: each `tailscale` command now times out (and the timeout or failure is logged), so a misbehaving Tailscale binary can't leave the popover stuck.
- Running Toki from source with `swift run` can now start the Remote Control server and serve its web UI; both the companion script and its assets are located whether they sit in a packaged app or SwiftPM's flattened resource bundle.
- The "Advanced" row in Remote Control settings now expands when you click anywhere on it, not only the disclosure triangle.

## 2.5.3 - 2026-07-28

### Changed

- On macOS 26, the usage and quota-rings widgets now render on the system's Liquid Glass material, bringing them in line with the app's redesigned popover. Older macOS keeps the existing look.

### Fixed

- The header controls (refresh, privacy, Settings, and More) now respond to a click anywhere on the button, not just on the icon. The glass square was larger than its tappable area, so clicks near the edges did nothing.
- On multiple displays, the popover now stays below the menu bar item that was clicked instead of rejecting the display change and falling back to stale coordinates from another screen.
- When Toki has Accessibility access, clicking an agent running in a VS Code integrated terminal now tries to raise the specific workspace window that hosts it, so on a multi-display setup you are more likely to land on the right window and screen. Without that permission it falls back to bringing VS Code forward as before.

## 2.5.2 - 2026-07-27

### Fixed

- The reset-credit badge (redeem a banked Codex reset) is clickable again on the collapsed account card. The card's tap-to-expand gesture was swallowing taps meant for the buttons inside it.

## 2.5.1 - 2026-07-27

### Added

- Cursor support (#33): auto-detected as a card when the `cursor-agent` CLI is installed, with live `cursor-agent` sessions appearing in the Active Agents panel (showing the conversation title and last-active time) and a proper Cursor logo.

### Changed

- The popover now follows macOS' native Liquid Glass hierarchy instead of applying glass to every card (#34). The system popover provides one continuous material, a compact glass header anchors app actions, navigation stays with the content below the insight, and account and quota data use borderless rows, dividers, and subtle interaction states. The same content-first treatment applies to widgets.
- What's New and Quit now live in a standard More menu, leaving refresh, privacy, and Settings as the persistent header actions.
- Settings section headings use the system's title-style capitalization rather than forced uppercase.

### Fixed

- The header now keeps its version/debug affordance, uses aligned glass squircle controls and a layered glass Toki mark, while quota rings stay pinned and loading states no longer shift nearby content.
- Quota rings now draw one ring per account instead of collapsing accounts that share a provider, so two Claude (or two Codex) accounts each get their own ring and side card. Each is given a distinct color (the account's label color, or a shaded provider color), and multiple accounts of a provider show their alias to tell them apart. The same fix applies to the quota-rings widget and the usage widget.
- The quota rings now scale to the available height so they read clearly next to the account cards.
- With multiple Claude Code accounts, a running session was shown on every Claude card. It is now attributed to the active account only (the one `claude-swap` has switched to), so inactive accounts no longer double-count it.
- Beta builds now carry their full release version (e.g. `2.5.1-beta.3`), so the in-app updater on the beta channel correctly offers the next beta and graduates to the stable release. Previously every build of a version reported the same base version, so betas never saw each other.

## 2.5.0 - 2026-07-26

### Added

- **Desktop widgets.** Two new widgets you can add from the macOS widget gallery, in small and medium sizes. One shows your account quota, how many agents are waiting on you, and a nudge to take a break once everything's used up; the other draws your remaining quota as colorful rings.
- **Quota rings in the app.** Provider-colored rings show how much of each provider you have left at a glance, with the provider name and percentage on hover. On by default — hide them with the button on the panel or the toggle in Settings.
- **"What's New" on the update banner.** When an update is ready, a button takes you straight to the release notes on GitHub before you install.
- **Hide the AI insight card.** A Settings toggle hides the insight card at the top of the panel; its prompt instructions now sit in the same card, only showing when the insight is on.

### Changed

- Toki keeps showing your last known usage when you lose internet, and refreshes on its own the moment you're back online. The refresh button now shows an offline icon instead of spinning for nothing.
- The header is simpler: the session-tracking button is gone, and Save buttons across the app use a floppy-disk icon.
- Settings is now a consistent set of cards: every row shares the same icon, title, and right-aligned control, so it reads as one tidy stack. The update channel is tinted apart as a developer setting, and "Check for updates" is its own card.

### Fixed

- Redeeming a Codex reset now updates your quota and clears the reset badge instantly, then confirms it with the server.
- Widgets no longer go blank in the gap between refreshes, and unsigned builds no longer trigger repeated macOS prompts asking to access other apps' data.

### Removed

- The `toki status`, `toki usage`, and `toki pi` terminal commands. Toki is a menu bar and widget app now.

## 2.4.4 - 2026-07-26

### Added

- Update channels. Settings > Updates now has a Stable/Beta picker: Beta offers GitHub pre-releases (tags like `v2.5.0-beta.1`) so upcoming builds can be tested before they ship, while Stable keeps ignoring them. Once the stable version is published, beta testers are offered it automatically and graduate back onto the production build.

### Fixed

- Update version comparison is now semver-aware. The old numeric string compare ranked `2.5.0-beta.1` above `2.5.0`, which would have kept re-offering a beta over its own final release.

## 2.4.3 - 2026-07-25

### Fixed

- Switching between tabs with different content heights could resize the entire popover and make AppKit re-anchor it at the left edge when the menu bar auto-hides. The popover now keeps a stable frame while it is open.

## 2.4.2 - 2026-07-25

### Added

- An eye button in the header masks account emails and org info across the cards, so you can share a screenshot or demo without leaking PII. It resets on relaunch.

### Changed

- Release builds now strip symbol tables from the binary before signing, cutting the shipped app bundle from 5.3MB to 2.3MB.

### Fixed

- Clicking an active agent running inside tmux did nothing. tmux runs panes under a detached server, so the walk up from the agent to its terminal dead-ended; Toki now hops through tmux to the attached client and focuses the terminal hosting it.
- Clicking an agent hosted in VS Code's integrated terminal did nothing: the walk resolved a "Code Helper" process whose activation policy is .prohibited. Toki now raises the real app instead, and picks the right one when VS Code and VS Code Insiders are both open.
- An agent's "in" token count showed only uncached input, reading as a few hundred tokens against a six-figure context. It now includes cache reads and writes, matching how the session cost is already computed.
- Agents in auto-accept mode showed a false "Allow Bash?" prompt: a tool running without asking looks the same on disk as one awaiting permission. Toki now reads the session's permission mode and only flags a prompt in a mode that would actually ask.
- Several agents in one project folder all showed the same title and token usage, because Toki could only find the folder's newest session. Each agent now prefers the session file created closest to when it launched, and any titles that still match get a terminal-tty marker so the rows stay distinct.
- With the menu bar set to auto-hide, opening Toki could drop the popover in the top-left corner: the status item reports an unsettled far-left position mid-reveal. Toki now rejects that jump and anchors near the icon instead.

### Codex

- A banked rate-limit reset now shows as a badge on the collapsed Codex card, and the badge is itself the redeem control: clicking it confirms first, stating how much of the window is still left, so a reset is never spent by accident. The old rule that greyed the control out until the window was 80% spent is gone. The soonest window reset also appears in the card's subtitle.

## 2.4.1 - 2026-07-22

### Added

- `Toki usage` charts daily agent activity in the terminal for Claude Code, OpenCode and Pi. Reads session files directly, so it works with the app closed. Supports `--days=N`, a provider filter, and `--json`.
- The update banner can be snoozed for six hours instead of only skipped for good.

### Changed

- The daily usage heatmap resolves into 64 shades instead of 4, interpolated through the same measured anchor colours. The legend is now a continuous bar.
- Hovering a day with no activity says "No usage" rather than showing a bare date.
- Both refresh buttons show a spinner and disable while a refresh runs.
- The README keeps what you need to decide whether to install Toki; the reference material moves to `docs/`.
- Comments that restated the code are gone. What survives explains why something is the way it is.

### Fixed

- Token and cost figures were inflated by ~78%. Claude Code writes one session line per content block, each repeating the same cumulative usage, and every line was counted. Messages are now counted once.
- Clicks on the notch panel landed in empty space: the hit-test rect was flipped to bottom-left, but `NSHostingView` is already top-left.
- The agent scan re-walked each agent's process tree every tick, bypassing the cache meant to prevent it.
- Quota chart x-axis labels collided and truncated; they now scale to the selected range. Its legend showed the internal account key rather than the account name.
- Compact figures gained a billions step, so a heavy month reads "1B" instead of "1,023M".
- A day whose history could not be read looked identical to a day with no work. The two are now distinct, and the failure says which provider it was.
- Empty heatmap cells were dark enough in dark mode to read as activity, making a busy day look idle.
- Diagnostics logged the type of an error and threw away its message, so a repeat of the state-decode incident would have been just as hard to diagnose. Decode failures now name the field that broke.
- A partial scan failure drew a normal-looking heatmap with one provider silently missing. The notice now appears above the grid, not only when every provider fails.
- `Toki usage` documented a non-zero exit for unreadable history and always returned 0, so a cron job could ingest incomplete data indefinitely.
- `Shell.output` returned whatever a failed subprocess had already written. A sqlite3 query dying mid-stream looked like a complete, shorter result.
- A missing Keychain item told you to allow a prompt that never appears; it now says to sign in to Claude Code.
- A login shell profile that prints to stdout no longer breaks every account read through the shell. Whatever `~/.zprofile` or `~/.zshenv` emitted landed ahead of the command's own output: the Keychain credential read came back as "banner text" followed by the JSON and failed parsing - Claude reported "The data couldn't be read because it isn't in the correct format" - and the same stray line was surfaced as the Codex error, hiding the real failure. The shell now prints a sentinel after the profiles have run, and everything before it is discarded, stderr included.
- A credential payload that still is not valid JSON now says so instead of escaping as the raw Cocoa parse error, which named neither the data nor a remedy.
- Diagnostic entries for system errors now record domain and code (`domain=NSCocoaErrorDomain code=3840`) alongside the message, so a debug report can tell a JSON parse failure from a Keychain refusal even when the message is generic.

## 2.4.0 - 2026-07-21

### Added

- Agents waiting on you are flagged with a red dot and the question they asked, on the card, the Agents tab and the menu bar. Claude Code and OpenCode.
- Daily usage heatmap in Spend Analytics: 30 days, filterable by provider, covering Claude Code, OpenCode and Pi. Read from each tool's own session history, so it includes work done before Toki was installed.
- Per-session dollar cost for Claude Code, priced from recorded token counts. Cache tokens are priced at their own rates, and an unrecognized model shows tokens without a cost rather than a guess.
- Experimental "live in the notch" mode, off by default and notched Macs only, with three resting positions and hover expansion.

### Changed

- claude-swap accounts read as "Claude - user@example.com" instead of the registry's internal `claude-1-…` key. Account ids are unchanged, so aliases and cached state stay attached.
- Default history retention raised from 14 to 30 days so the heatmap can fill its window.

### Fixed

- Adding a preference wiped saved history. `AppPreferences` used the synthesized decoder, which rejects any file missing a key, so the loader discarded the state and overwrote it. Preferences now decode field by field, and an unreadable file is kept as `.unreadable`.
- Menu bar text was invisible in full screen: the view followed the app's light/dark setting rather than the menu bar's own.
- Agent cards were not reliably clickable. Rows re-ordered under the pointer, and terminal lookup could raise the wrong build when two iTerms were running.
- The popover jumped while open whenever the status item resized. Width changes are now deferred until it closes.
- Update checks stopped after finding one update, so releases behind it went unnoticed.
- Keychain reads shared a 15-second timeout meant for non-interactive commands, so a missed access prompt looked like an account that would not connect.
- A failed account shows the real error on its card instead of the word "Unavailable".


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
