# Command line

Toki symlinks itself to `/usr/local/bin/toki` on launch, so the CLI is on your `PATH` with no setup.

## `toki status`

```sh
toki status                    # one line per account, e.g. "Work: 82% left"
toki status pi                 # filter to a provider (pi, codex, claude, ...) or account name
toki status --compact          # single line matching the menu bar icon, for prompts
toki status --json             # full snapshot as JSON
toki status --watch            # redraw every 5s (--watch=N for other intervals)
toki status codex --exit-code  # exit 2 when the matching quota is exhausted
toki status --help             # full option list
```

`status` reads a cache the running app writes after every refresh (`~/.toki/status.json`, override with `TOKI_STATUS_CACHE`). It never launches the app or makes a network or Keychain call, so it is safe to run on every shell prompt render. If Toki has not run yet, or the cache is over 15 minutes old, it says so on stderr.

## `toki usage`

Daily activity for the last N days, drawn as a heatmap in the terminal.

```sh
toki usage                     # last 30 days, all providers
toki usage --days=7            # shorter window
toki usage claude              # filter to one provider
toki usage --json              # machine-readable
```

Colour is used when the output is a TTY and `NO_COLOR` is unset. Like the in-app heatmap, this reads each tool's own session history, so it covers days before Toki was installed.

## `toki pi`

Pi spend broken down by today / this week / this month / all time (`--json` too). Independent of the status cache — it computes directly from local Pi session history, so it works even if the app has never run.

## Environment overrides

```sh
TOKI_CONFIG=/path/to/config.json swift run Toki
TOKI_STATE=/path/to/usage-state.json swift run Toki
TOKI_STATUS_CACHE=/path/to/status.json swift run Toki
```

Legacy TokenBar paths and variables are still recognised: `TOKENBAR_CONFIG`, `TOKENBAR_STATE`, `~/.tokenbar/config.json`, `~/.tokenbar/usage-state.json`.
