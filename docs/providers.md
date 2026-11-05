# Providers

## Claude Code

Credentials come from your Claude Code sign-in. A valid absolute or `~`-rooted
`CLAUDE_CONFIG_DIR` inherited by Toki selects that directory's credential file; it does not fall back
to a different account's default Keychain entry. Directory-specific Keychain lookup
is not supported. This directory is tracked independently of the default
`claude-swap` account list. Otherwise Toki searches, in order:

1. Keychain item `Claude Code-credentials` under `$USER`
2. the same item under the macOS account name, when that differs
3. the same item under any account (a service-only search, for an item filed under a name Toki can't derive)
4. `$CLAUDE_CONFIG_DIR/.credentials.json`
5. `~/.claude/.credentials.json`
6. `$XDG_CONFIG_HOME/claude/.credentials.json`
7. `~/.config/claude/.credentials.json`

`CLAUDE_CONFIG_DIR` and `XDG_CONFIG_HOME` are read from Toki's own environment first. A Finder-launched app inherits none of your shell environment, so if they aren't set there, Toki asks your login shell for them once and caches the answer. Shell-only values participate in file fallback after the default Keychain; they do not isolate account discovery. If your setup is stranger still, point Toki at it directly with `apiKeyCommand`, which can be any command that prints the credential JSON.

Whatever comes out of that file is sent to `api.anthropic.com` as a Bearer token, so it is checked before it is read. A candidate is skipped when the path isn't absolute (or `~`-rooted) or holds control characters, or when the file is a symlink, not a regular file, owned by another user, writable by group or other, empty, or larger than 256 KB. A file that is merely readable by others is still used, but the diagnostic log records it. `chmod 600` is what Claude Code writes and what Toki expects.

Multi-account setups are discovered through [`claude-swap`](https://github.com/realiti4/claude-swap). Switching an inactive account runs:

```sh
claude-swap --switch-to <slot>
```

then reloads discovery and refreshes usage. If `claude-swap` is not on your `PATH`, set `claudeSwapCommand` to its full path.

macOS asks for Keychain access the first time Toki reads these credentials. The prompt blocks until you answer it, so nothing connects until it is granted.

Toki rereads the selected source once on expiry or a usage authentication failure
during manual or automatic refresh. A replacement token is verified through Claude's
OAuth profile endpoint, with a 10-second inactivity timeout, before retrying usage once.
An expired Keychain token can fall back to a valid default credential file only when
the card's email and organization are known and match the replacement's profile.
Failed recovery keeps the original sign-in error and records the failure in diagnostics.
Reset redemption stays unavailable while usage depends on the fallback file.
Claude Code can renew its access token without a new login: try opening a session
or running `/status` in an existing one.
Refresh Toki afterward or wait for its next automatic poll. Use `/login` only if
Claude Code cannot restore access. Toki does not run `/status` itself.

Toki reads usage from the subscription sign-in that `/login` writes, which is the `claudeAiOauth` section of those credentials. Installing the CLI alone is not enough, and an API key (`ANTHROPIC_API_KEY`) or a Bedrock/Vertex setup produces no such section, so no usage is reported for those. When the card says **Not connected**, expand it: the message names each place Toki looked and what it found there.

## Codex

```json
{ "label": "Codex", "type": "codex" }
```

Toki asks the local Codex app-server for the signed-in account, usage, and rate limits. Codex resolves its own configured credential store, so file-based `auth.json`, macOS Keychain, and `auto` storage all work without Toki reading the access token. This is separate from OpenAI organization API usage.

If a signed-in account's usage request is rejected with a backend 401, both manual
and automatic refresh let Toki ask Codex to refresh its credentials noninteractively,
then retry usage once. Attempts are limited to once per minute per Codex home,
with a 30-second timeout. Normal polling intervals still apply; missing sign-in,
permission errors, rate limits, and network errors do not trigger credential recovery.
If recovery fails, open Codex to restore its sign-in, then refresh Toki.

### More than one Codex account

Sign each extra account in to its own Codex home next to `~/.codex`:

```sh
CODEX_HOME=~/.codex-work codex login
```

Toki finds every folder in your home directory whose name starts with `.codex` and holds an `auth.json` or `config.toml`, asks Codex which account is signed in there, and adds it as its own card (`Codex (work)` for the example above). All accounts are read at the same time. A folder signed in to the same account and workspace as one already listed, such as a backup copy of `~/.codex`, is skipped.

To stop tracking a folder, sign it out with `CODEX_HOME=~/.codex-old codex logout` (or rename it so its name does not start with `.codex`), then remove its account from `config.json`. If you only remove the account, the next scan adds it again.

For a home somewhere else, set `codexAuthPath` to the `auth.json` path inside it. Toki uses its containing directory as `CODEX_HOME` when launching app-server; the default is `~/.codex`.

The app-server is launched through a login shell, which sources `.zprofile` but not `.zshrc`. Since the version managers most CLIs are installed through (nvm, fnm, volta, bun, pnpm, mise, asdf) set `PATH` from `.zshrc`, their bin directories are appended explicitly, so a `codex` installed that way is found rather than reported as `command not found`.

When no `codex` is on `PATH` at all, Toki falls back to the copy bundled inside `Codex.app`, so the desktop app on its own is enough to read usage. A `PATH` install always takes precedence over the bundled copy, since the bundled CLI is version-locked to the app release and a Homebrew or npm install should keep winning. A broken `PATH` install is reported as such rather than silently bypassed.

When OpenAI has banked a rate-limit reset credit, the expanded card shows a **Reset now** button (with a count when more than one is banked). It stays disabled until the current window is at least 80% used, so a credit is not spent while quota remains.

## Pi

No configuration needed. Toki reads only the local JSONL session metadata it needs — assistant token counts, Pi's own cost estimates, working directories, timestamps, titles — never auth data or message content. Every underlying model provider is combined into one card.

Session root discovery, in order:

1. `PI_CODING_AGENT_SESSION_DIR`
2. `sessionDir` in `~/.pi/agent/settings.json` (or the settings file under `PI_CODING_AGENT_DIR`)
3. `${PI_CODING_AGENT_DIR}/sessions` (normally `~/.pi/agent/sessions`)

Override paths must be absolute, exactly `~`, or start with `~/`. Project-local `.pi/settings.json` values and per-invocation `--session-dir` are not globally discoverable, so sessions stored only that way are not tracked.

## Sarvam Code

No configuration needed. Toki auto-detects the `sarvam-code` CLI or its state under `$SARVAM_HOME` (normally `~/.sarvam`) and reads cumulative token counters from local session JSONL without loading transcript content. Input, cached input, output, reasoning, daily, weekly, monthly, and all-time usage are shown.

When a log contains cost data, Toki uses its currency; otherwise it assumes USD. Current Sarvam Code logs do not record cost, so the card shows `$0.00` while keeping the parser ready for future cost fields. Sarvam Code does not expose usable quota limits through its local app-server, so Toki does not invent a quota ring.

## OpenCode

Auto-detected from its local database and surfaced as an account. Also the second provider (with Claude Code) where Toki can tell that a session is parked waiting on you. With an OpenCode Go subscription, the card also shows the plan's 5-hour, weekly and monthly allowances, read through the local OpenCode CLI.

## fx

Vercel's `fx`. Auto-detected from its local usage ledger (`~/.fx/usage.jsonl`); no configuration. Toki aggregates today, this-week, and this-month token spend from that ledger, and reads the AI Gateway credit balance from `fx credits --json`. Session titles and activity come from `~/.fx/sessions/index.json`.

## Cursor

Detected when either the `cursor-agent` CLI or the Cursor desktop app is installed. When you are signed into Cursor, Toki reads your usage from `cursor.com` using the OAuth token in the desktop app's local state: spend this cycle against your plan's limit as a ring, token counts, and the billing-cycle reset. The desktop agent runs inside the app with no separate process, so the card also reads local AI-edit and chat activity to show **Active** and sort by recency, and falls back to that alone when signed out.

The ring's denominator is the spend cap the API reports, which for a team member is the team's shared cap. If your personal cap differs, set it (in dollars) with a configured account so the ring is yours:

```json
{ "label": "Cursor", "type": "cursor", "limit": 20 }
```

## Copilot, Gemini, Grok, Antigravity

Agent-detection only. Toki shows a local active-session count, and sign-in state for Gemini and Grok, but invents no quota, because none of GitHub, Google, or xAI expose a usage API Toki reads for these. Antigravity (Google's `agy`) is detected by its CLI; its agent rows read the conversation title and last activity from `~/.gemini/antigravity-cli` (its live history log and conversation summaries).

## Zed

Agent-detection only, and detected by the editor rather than by a CLI: the card appears once Zed is installed.

Zed runs its agents two different ways, and Toki finds both.

An **external agent** speaks the Agent Client Protocol and runs as a real process, which Zed downloads under `~/Library/Application Support/Zed/external_agents/`. Any process launched from there is a Zed session, whatever CLI is inside it — a `claude-code-acp`, a `codex-acp` or a registry agent all belong to the Zed thread that started them, because Zed is where that thread can be answered.

Zed's **built-in agent** runs inside the Zed process itself, so no process exists to find. Those sessions are read from Zed's own thread store instead: `sidebar_threads` in `~/Library/Application Support/Zed/db/0-<channel>/db.sqlite`, the same list its threads sidebar draws. Every installed release channel is read. A thread appears as a live session while it has been written to in the last 30 minutes and Zed is running — with no process there is no "still running" to read, so recency stands in for it. These rows carry no PID, so they have no **Quit** button; closing the thread is Zed's job.

Both kinds take their title and last activity from that same store — Zed hands an agent server the worktree as its working directory and tells it nothing else, so the project folder is what links a running server back to the thread you are looking at. Clicking a row raises Zed.

Toki reads only thread metadata: the agent name, title, timestamps and project folder. It does not read message content, which Zed stores compressed, and it opens the database read-only.

Zed sessions are watch-only in Remote Control. See [Remote Control](remote-control.md#read-only-sessions).
