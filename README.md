# TokenBar

TokenBar is a native macOS menu bar app for watching Claude Code usage across the Claude accounts available on your machine.

It is built for people who use [`claude-swap`](https://github.com/realiti4/claude-swap) to move between Claude Code accounts and want a small, local status view instead of checking each account by hand.

## Features

- Discovers Claude Code accounts from `~/.claude-swap-backup/sequence.json`.
- Reads the active Claude Code credential from macOS Keychain service `Claude Code-credentials`.
- Reads saved inactive account credentials from macOS Keychain service `claude-swap`.
- Shows 5-hour and 7-day Claude Code utilization, reset timing, and spend data when Anthropic returns it.
- Shows safe account metadata such as email, account slot, organization, and active status.
- Adds a Switch button for inactive accounts and delegates switching to `claude-swap --switch-to`.
- Supports optional nicknames, emoji, and colors for easier account scanning.
- Can also track manual consumer budgets or organization usage for OpenAI and Anthropic API keys, though Claude Code is the primary workflow.

TokenBar stays local. Credentials are read from your Mac or the commands you configure; the app does not add its own cloud service.

## Requirements

- macOS 14 or newer.
- Swift 6 toolchain.
- Claude Code installed and authenticated.
- `claude-swap` installed and configured if you want multi-account discovery and switching.

macOS may ask for Keychain access the first time TokenBar reads Claude Code or `claude-swap` credentials.

## Quick Start

Build and run from source:

```sh
swift run TokenBar
```

The app appears only in the macOS menu bar.

To install it as an app bundle:

```sh
scripts/install-app.sh
open ~/Applications/TokenBar.app
```

To rebuild the bundle without installing:

```sh
scripts/build-app.sh
open .build/TokenBar.app
```

## Configuration

The default config path is:

```sh
~/.tokenbar/config.json
```

For Claude Code account discovery, TokenBar only needs one account entry:

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
    },
    {
      "email": "personal@example.com",
      "nickname": "Personal",
      "emoji": "🏠",
      "color": "#F59E0B"
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

You can start from the example file:

```sh
mkdir -p ~/.tokenbar
cp examples/config.example.json ~/.tokenbar/config.json
```

`accountLabels` are optional UI overrides. TokenBar matches them to discovered accounts by email plus organization UUID/name when provided, falling back to email-only. They do not affect Claude credentials or switching behavior.

### Environment Overrides

Use these if you want separate configs or state files:

```sh
TOKENBAR_CONFIG=/path/to/config.json swift run TokenBar
TOKENBAR_STATE=/path/to/usage-state.json swift run TokenBar
```

## Switching Accounts

Install and configure `claude-swap` first. TokenBar discovers the same account registry and adds a Switch button to inactive accounts.

When clicked, TokenBar runs:

```sh
claude-swap --switch-to <slot>
```

After the command succeeds, TokenBar reloads the account registry and refreshes usage. The actual credential rewrite stays owned by `claude-swap`, which keeps TokenBar small and avoids duplicating swap logic.

If `claude-swap` is not on your `PATH`, set `claudeSwapCommand` in the account config to the full executable path.

## Troubleshooting

- `Config needed`: create `~/.tokenbar/config.json` or set `TOKENBAR_CONFIG`.
- `No credentials found`: confirm Claude Code and `claude-swap` are authenticated and that Keychain access was allowed.
- `Claude Code usage unavailable`: Anthropic did not return usage data for that account. Try refreshing later or check the account in Claude Code.
- Switch fails: run `claude-swap --switch-to <slot>` in Terminal to see the underlying error.

## Development

Build:

```sh
swift build
```

Run:

```sh
swift run TokenBar
```

Build a release app bundle:

```sh
scripts/build-app.sh
```

The release bundle is written to `.build/TokenBar.app`.

## Notes

The Claude Code OAuth usage endpoint reports utilization buckets such as `five_hour` and `seven_day`; it does not expose a simple public "tokens left" consumer API. TokenBar displays the usage and reset data returned by the endpoint for each discovered account.
