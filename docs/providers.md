# Providers

## Claude Code

Credentials come from the Keychain, and multi-account setups are discovered through [`claude-swap`](https://github.com/realiti4/claude-swap). Switching an inactive account runs:

```sh
claude-swap --switch-to <slot>
```

then reloads discovery and refreshes usage. If `claude-swap` is not on your `PATH`, set `claudeSwapCommand` to its full path.

macOS asks for Keychain access the first time Toki reads these credentials. The prompt blocks until you answer it, so nothing connects until it is granted.

## Codex

```json
{ "label": "Codex", "type": "codex", "codexAuthPath": "~/.codex/auth.json" }
```

Toki reads the auth file and asks the local Codex app-server for usage and rate limits. This is separate from OpenAI organization API usage.

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
