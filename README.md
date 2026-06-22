# TokenBar

A native macOS menu bar app for Claude Code usage across all locally available Claude accounts.

TokenBar follows the same account model as [`realiti4/claude-swap`](https://github.com/realiti4/claude-swap):

- Reads `~/.claude-swap-backup/sequence.json` to discover managed accounts.
- Reads the active Claude Code credential from macOS Keychain service `Claude Code-credentials`.
- Reads saved inactive account credentials from macOS Keychain service `claude-swap`.
- Calls Anthropic's Claude Code OAuth usage endpoint and shows each account's 5-hour and 7-day utilization, reset time, and spend when available.
- Shows safe account metadata such as email, account slot, organization, and active status.
- Shows a Switch button for inactive accounts and delegates the actual swap to `claude-swap --switch-to`.

## Build

```sh
swift build
```

## Run From Source

```sh
swift run TokenBar
```

The app appears only in the macOS menu bar.

## Build App Bundle

```sh
scripts/build-app.sh
open .build/TokenBar.app
```

## Install

```sh
scripts/install-app.sh
open ~/Applications/TokenBar.app
```

## Configure

TokenBar only needs one Claude Code config entry. It expands that into all discovered Claude accounts.

```json
{
  "refreshMinutes": 15,
  "accountLabels": [
    {
      "email": "work@example.com",
      "organizationUuid": "00000000-0000-0000-0000-000000000000",
      "nickname": "Work",
      "emoji": "💼",
      "color": "#4F8EF7"
    }
  ],
  "accounts": [
    {
      "id": "claude-code",
      "name": "Claude",
      "provider": "claudeCode"
    }
  ]
}
```

The live config path is:

```sh
~/.tokenbar/config.json
```

macOS may ask for Keychain access the first time TokenBar reads Claude Code or claude-swap credentials.

`accountLabels` are optional UI overrides. TokenBar matches them to discovered accounts by email plus organization UUID/name when provided, falling back to email-only. They do not affect Claude credentials or switching behavior.

## Switching Accounts

Install and configure `claude-swap` first. TokenBar discovers the same account registry and adds a **Switch** button to inactive accounts.

When clicked, TokenBar runs:

```sh
claude-swap --switch-to <slot>
```

After the command succeeds, TokenBar reloads the account registry and refreshes usage. The actual credential rewrite stays owned by `claude-swap`, which keeps TokenBar small and avoids duplicating swap logic.

## Notes

The Claude Code OAuth usage endpoint reports utilization buckets such as `five_hour` and `seven_day`; it does not expose a simple public "tokens left" consumer API. TokenBar displays the exact usage and reset data the endpoint returns, per discovered account.
