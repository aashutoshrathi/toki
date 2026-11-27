# Toki on Windows (preview)

Toki has a native Windows 11 x64 preview. It is not a released installer yet. Builds come from GitHub Actions.

The preview is for testers who run Claude Code and Codex on Windows. It is not full parity with the macOS app.

## What works

- Tray icon with a quota summary.
- Dashboard with Claude Code and Codex quota.
- Claude Code 5 hour and 7 day remaining quota, with reset times.
- Codex quota through the local app-server.
- Refresh every 60 seconds.
- Low-quota warnings at 20 percent or less, with a 90 minute cooldown.
- Do Not Disturb to suppress notifications.
- Settings for the Claude directory, Codex home, Codex executable, notifications, and DND.
- Closing the dashboard hides it to the tray. Quit exits the app.

## Not in this preview

- Remote Control.
- Agent and session list.
- Multiple accounts.
- Widgets.
- WSL support.
- Signed installer or automatic updates.
- Notch mode, Apple Intelligence, and other macOS-only features.

## Requirements

- Windows 11 x64.
- Claude Code and/or Codex installed and signed in.
- No admin rights.
- No .NET install. The package is self-contained.

## Get a build

There is no released Windows installer. Get a build from GitHub Actions:

1. Sign in to GitHub.
2. Open the **Actions** tab, then the **Windows preview** workflow.
3. Open the latest run for `release/v4.0.0`, or a run for your pull request.
4. Download the `toki-windows-preview-4.0.0-preview.1-win-x64` artifact.
5. Unzip the artifact, then unzip `Toki-windows-preview-4.0.0-preview.1-win-x64.zip`.
6. Run `Toki.exe`.

The build is unsigned. Windows SmartScreen may show **Windows protected your PC**. Click **More info**, then **Run anyway**. Do not turn off SmartScreen or Defender. If your organization blocks unsigned apps, ask IT or build from source.

## Credentials and paths

Toki reads the credentials that the CLIs already store. It never writes provider secrets, never refreshes tokens, and sends no telemetry.

**Claude Code.** Toki finds the local Claude Code credential file. It respects `CLAUDE_CONFIG_DIR`. Set a custom directory in Settings if the file is elsewhere.

**Codex.** Toki uses the local Codex auth through the app-server. It finds a native `codex.exe`, or the npm JavaScript entry run with `node`. It respects `CODEX_HOME`. Set a custom home or executable in Settings.

Toki does not use a shell to start Codex. It does not use WSL yet.

## Tester checklist

Sign in to Claude Code and Codex in a terminal before you start.

- **Launch.** Run `Toki.exe`. The tray icon appears.
- **Login.** Both providers show data for the account you signed in with.
- **Quotas.** 5 hour and 7 day remaining values match what the CLIs report. Reset times look correct.
- **Refresh.** Click refresh. The last checked time updates.
- **Offline.** Disconnect the network, then refresh. Toki shows a clear error and does not show old quota as current.
- **Expired login.** Sign out in the CLI, then refresh. Toki shows a clear auth error.
- **Tray.** Close the dashboard. It hides to the tray. Reopen it from the tray. Quit from the tray and check that the process exits.
- **Scaling.** Try 100, 125, 150, and 200 percent display scaling. Text and layout stay readable.
- **Notifications.** Enable notifications and wait for a low quota. Turn on DND and check that notifications stop.
- **Feedback.** Report the Windows version, the steps, and the exact error text. Do not send tokens, credentials, or transcripts.

## Build and test locally

Run the core tests:

```powershell
dotnet run --project Windows/Toki.Core.Tests -c Release
```

Build the portable package:

```powershell
pwsh ./scripts/package-windows.ps1 -OutputDirectory artifacts/windows -Version 4.0.0-preview.1 -Runtime win-x64
```

The script writes `artifacts/windows/Toki-windows-preview-4.0.0-preview.1-win-x64.zip` and `Toki-windows-preview-4.0.0-preview.1-win-x64.zip.sha256`.

The publish is self-contained, so the tester machine needs no .NET install. Trimming and ReadyToRun are off, so the same publish works from macOS with the .NET 10 SDK and `EnableWindowsTargeting`.

ARM64 is optional and untested:

```powershell
pwsh ./scripts/package-windows.ps1 -OutputDirectory artifacts/windows -Version 4.0.0-preview.1 -Runtime win-arm64
```

## Continuous integration

`.github/workflows/windows.yml` runs on pull requests to `main` and `release/**`, on pushes to `main` and `release/**` (including `release/v4.0.0`), and on manual dispatch. It runs the core tests, publishes the self-contained `win-x64` package, starts the packaged `Toki.exe` with `--smoke-test`, and uploads the zip with its SHA256 file.

The artifact is versioned as `toki-windows-preview-4.0.0-preview.1-win-x64`. It is a preview build, not a stable release or a public installer.

The smoke test checks that the app starts and exits with code 0. It uses no credentials and no network. It does not validate real provider calls. Real validation needs a signed-in tester on Windows.

## Verify a download

Compare the zip hash with the `.sha256` file:

```powershell
Get-FileHash .\Toki-windows-preview-4.0.0-preview.1-win-x64.zip -Algorithm SHA256
```

## Limits

This is a preview. Do not expect macOS parity. Report bugs with the checklist details above.
