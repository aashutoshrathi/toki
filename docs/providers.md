# Providers

## Claude Code

Credentials come from your Claude Code sign-in. Toki searches, in order:

1. Keychain item `Claude Code-credentials` under `$USER`
2. the same item under the macOS account name, when that differs
3. the same item under any account (a service-only search, for an item filed under a name Toki can't derive)
4. `$CLAUDE_CONFIG_DIR/.credentials.json`
5. `~/.claude/.credentials.json`
6. `$XDG_CONFIG_HOME/claude/.credentials.json`
7. `~/.config/claude/.credentials.json`

`CLAUDE_CONFIG_DIR` and `XDG_CONFIG_HOME` are read from Toki's own environment first. A Finder-launched app inherits none of your shell environment, so if they aren't set there, Toki asks your login shell for them once and caches the answer. If your setup is stranger still, point Toki at it directly with `apiKeyCommand`, which can be any command that prints the credential JSON.

Whatever comes out of that file is sent to `api.anthropic.com` as a Bearer token, so it is checked before it is read. A candidate is skipped when the path isn't absolute (or `~`-rooted) or holds control characters, or when the file is a symlink, not a regular file, owned by another user, writable by group or other, empty, or larger than 256 KB. A file that is merely readable by others is still used, but the diagnostic log records it. `chmod 600` is what Claude Code writes and what Toki expects.

Multi-account setups are discovered through [`claude-swap`](https://github.com/realiti4/claude-swap). Switching an inactive account runs:

```sh
claude-swap --switch-to <slot>
```

then reloads discovery and refreshes usage. If `claude-swap` is not on your `PATH`, set `claudeSwapCommand` to its full path.

macOS asks for Keychain access the first time Toki reads these credentials. The prompt blocks until you answer it, so nothing connects until it is granted.

Toki reads usage from the subscription sign-in that `/login` writes, which is the `claudeAiOauth` section of those credentials. Installing the CLI alone is not enough, and an API key (`ANTHROPIC_API_KEY`) or a Bedrock/Vertex setup produces no such section, so no usage is reported for those. When the card says **Not connected**, expand it: the message names each place Toki looked and what it found there.

## Codex

```json
{ "label": "Codex", "type": "codex" }
```

Toki asks the local Codex app-server for the signed-in account, usage, and rate limits. Codex resolves its own configured credential store, so file-based `auth.json`, macOS Keychain, and `auto` storage all work without Toki reading the access token. This is separate from OpenAI organization API usage.

For a multi-account setup, `codexAuthPath` can point at the `auth.json` inside another Codex home. Toki uses its containing directory as `CODEX_HOME` when launching app-server; the default is `~/.codex`.

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

## OpenCode

Auto-detected from its local database and surfaced as an account. Also the second provider (with Claude Code) where Toki can tell that a session is parked waiting on you.

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
