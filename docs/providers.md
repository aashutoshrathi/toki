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
{ "label": "Codex", "type": "codex", "codexAuthPath": "~/.codex/auth.json" }
```

Toki reads the auth file and asks the local Codex app-server for usage and rate limits. This is separate from OpenAI organization API usage.

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

## Copilot, Gemini, Grok

Agent-detection only. Toki shows a local active-session count, and sign-in state for Gemini and Grok, but invents no quota — none of GitHub, Google, or xAI expose a usage API for these.
