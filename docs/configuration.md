# Configuration

Toki connects providers automatically. Every time the popover opens it scans for Claude Code (Keychain), Codex (`~/.codex/auth.json`), OpenCode (its local database), Pi (local JSONL session history), Grok CLI (`~/.grok/auth.json`), and Gemini CLI (`~/.gemini/oauth_creds.json`). There is no Connect button and no JSON to hand-write; signing into a new provider later is picked up on the next open.

Editing the config yourself is only needed for scripting, multi-account setups, or fields the scan cannot infer — API keys, budgets, manual ledgers.

```text
~/.toki/config.json
```

```sh
mkdir -p ~/.toki
cp examples/config.example.json ~/.toki/config.json
```

## A minimal config

```json
{
  "refreshMinutes": 5,
  "accountLabels": [
    {
      "email": "work@example.com",
      "organizationUuid": "00000000-0000-0000-0000-000000000000",
      "nickname": "Work",
      "color": "#4F8EF7"
    }
  ],
  "accounts": [
    { "label": "Claude", "type": "claudeCode", "claudeSwapCommand": "claude-swap" },
    { "label": "Codex", "type": "codex", "codexAuthPath": "~/.codex/auth.json" }
  ]
}
```

## Fields

**`accounts`** — each needs a `label` (display name) and a `type` (provider). `id` is optional and derived from the label. Configs using the old `name`/`provider` keys are migrated on launch, keeping a `.bak` of the original.

**`accountLabels`** — presentation overrides only. Matched against discovered Claude accounts by email and, when given, organization UUID or name. They never affect credentials or switching.

**`refreshMinutes`** — defaults to `5`. API-backed providers refresh stale-while-revalidate: the last known usage stays visible while a new value is fetched. Automatic refreshes pace Claude Code at 7.5 minutes to avoid early `429`s; Codex uses the 5-minute cadence. Opening the popover or pressing reload can refresh sooner, but never faster than one provider call per minute. On a `429`, the last good snapshot stays on screen.

**`aiInstructions`** — customises the on-device LLM prompt behind the insight card on macOS 26+. Absent, Toki uses a default prompt built from the current recommendation and account snapshots.

## State

Preferences, notification cooldowns, event history, usage history, and session state live in:

```text
~/.toki/usage-state.json
```

If this file is ever unreadable, Toki copies it to `usage-state.json.unreadable` before falling back to defaults, so a decode failure cannot silently destroy accumulated history.
