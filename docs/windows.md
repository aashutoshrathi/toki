# Toki on Windows (preview)

Toki has a native Windows 11 x64 preview. It is not a released installer yet. Builds come from GitHub Actions.

The preview is for testers who run Claude Code and Codex on Windows. It is not full parity with the macOS app.

## What works

- Tray icon with a quota summary and a compact floating usage panel.
- Tray-first startup; the full dashboard opens only when you choose Dashboard.
- Dark native title bars on the dashboard and Settings.
- Dashboard with Claude Code and Codex quota.
- Claude Code 5 hour and 7 day remaining quota, with reset times.
- Codex quota through the local app-server.
- Refresh every 60 seconds.
- Low-quota warnings at 20 percent or less, with a 90 minute cooldown.
- Do Not Disturb to suppress notifications.
- Settings for the Claude directory, Codex home, Codex executable, notifications, and DND.
- Closing the dashboard hides it to the tray. Quit exits the app.
- Session timer and quota burn, with an in-memory Events view (latest 200 events).
- Recent Claude/Codex conversations from local session history.
- Optional read-only phone access to quotas and transcripts, with pairing and device revocation.

## Not in this preview

- Remote replies, terminal mirroring, and agent control.
- Live-process detection and waiting-for-input alerts. The session list shows recent history, not proof an agent is running.
- Multiple accounts.
- Widgets.
- WSL support.
- Signed installer or automatic updates.
- Notch mode, Apple Intelligence, and other macOS-only features.

## Requirements

- Windows 11 x64.
- Claude Code and/or Codex installed and signed in.
- No admin rights.
- No .NET or Python install. The package includes both runtimes.
- Remote access may need an inbound Windows Firewall rule for the bundled `python\python.exe`. Only enable the network scope you intend to use; organization policy may require IT approval.

## Get a build

There is no released Windows installer. Get a build from GitHub Actions:

1. Sign in to GitHub.
2. Open the **Actions** tab, then the **Windows preview** workflow.
3. Open the latest run for `release/v4.0.0`, or a run for your pull request.
4. Download the `toki-windows-preview-4.0.0-preview.4-win-x64` artifact.
5. Unzip the artifact, then unzip `Toki-windows-preview-4.0.0-preview.4-win-x64.zip`.
6. If an older Toki is running, choose **Quit Toki** from its tray menu first. Keep the new extracted files together, then run `Toki.exe`. The compact usage panel opens; the full dashboard stays closed.

The build is unsigned. Windows SmartScreen may show **Windows protected your PC**. Click **More info**, then **Run anyway**. Do not turn off SmartScreen or Defender. If your organization blocks unsigned apps, ask IT or build from source.

## Tray panel and dashboard

Left-click the Toki tray icon to open or dismiss the compact usage panel. If the icon is under the taskbar's hidden-icons arrow, move it into the notification area to keep it visible. Windows controls this placement.

The panel shows each provider's quota and reset times, with the 5-hour window before the weekly window even when Codex returns them in reverse order. Click outside it or press Escape to dismiss it; Toki keeps refreshing in the tray. Use **Dashboard** for the larger window, or **Settings** to change configuration. Right-click the tray icon for usage, dashboard, Settings, refresh, DND, and Quit. Starting Toki again opens the existing instance's compact panel.

The dashboard and Settings use dark native title bars on Windows 11, including when Windows uses its light theme. Windows high-contrast mode keeps the system title-bar colors.

## Privacy and launch at sign-in

Choose **Hide sensitive info** in the tray menu or Settings before screen sharing. It masks account descriptions, provider error details, conversation titles, Events details, Settings paths, the connection link and pairing code, and paired-device names on this PC. Quotas remain visible. The choice persists across restarts. Search is cleared and disabled while privacy is on. It does not change what an already-paired phone can read: use the phone's privacy toggle or stop sharing for that.

In Settings, enable **Launch at Windows sign-in (tray only)** to register this portable copy for your current Windows user. Sign-in launches the tray icon without opening the dashboard or compact panel; remote sharing stays off. Normal manual launches still open the compact panel. Windows **Settings > Apps > Startup** can disable this registration independently. Keep the extracted folder in a permanent location. After moving or replacing it, open the new copy and save Settings with launch at sign-in enabled to update the path. To remove the registration, uncheck it and save before deleting Toki.

## Sessions and Events

Open Dashboard > Session & Events. **Start session** records the current fresh quota readings. The summary shows elapsed minutes and percentage points used. A quota reset or unavailable reading is not treated as burn. **End session** records a summary. Tracking and the latest 200 events stay in memory and reset when Toki exits. **Clear events** clears the event list.

Provider failures/recovery and low-quota warnings appear in Events. DND suppresses the notification but still records the warning. Events do not contain conversation titles, paths, prompts, or credentials.

**Recent sessions** reads up to 32 Claude/Codex conversation files, refreshed every 15 seconds. These are recent conversations, not a live-agent list. Scans are bounded to 6,000 filesystem entries and skip symlinks/junctions and files larger than 16 MiB. The view reports incomplete scans. Settings and `CLAUDE_CONFIG_DIR` / `CODEX_HOME` select the roots. A file still being written is read without locking the CLI out.

Search recent conversations by title or project path and filter by Claude Code or Codex. Words match together, regardless of case. Filters apply only to the recent files already discovered; they do not search full transcript contents or change the history shared with paired devices.

## Read-only Remote Control

1. Open Dashboard > **Remote viewing**. Sharing is off after every app start.
2. Choose **Local network** for a phone on the same trusted network, or **Tailscale** for devices on the same tailnet. **This computer** is for testing in a browser on this PC only.
3. Choose this PC's reachable IP address. If only `127.0.0.1` appears, no matching network adapter was found; connect to that network before starting. This address cannot be reached from a phone.
4. Optionally enable **Share recent conversation transcripts**. Paired devices can then read prompts, assistant messages and tool output from the recent-session list. Leave it off for quotas only.
5. Click **Start sharing**, then **Copy connect link**. Open that link on the phone and enter the six-digit code displayed separately in Toki. The code rotates every two minutes. This preview uses a copied link, not a QR code.
6. Read quota or select a recent conversation. Replies, uploads, terminal keys, account resets and opening host apps are blocked by the Windows server, not just hidden by the UI.
7. Select a paired device and click **Revoke selected device** to end its access. **Stop sharing**, changing transcript sharing, or quitting Toki ends all paired sessions. Restart sharing to get a new link and pair again.

Connections use port 8765. Local-network mode uses HTTP, so use it only on a trusted network; Tailscale carries the connection inside its encrypted network. Do not forward this port to the public internet. If the phone cannot connect, check Windows Firewall, the selected IP, and whether the phone and PC are on the selected network. Toki must remain running and the PC must remain awake. Pairing lasts 12 hours unless revoked or the server stops.

No remote setting silently enables sharing on the next launch. The bundled Python process exits when Toki closes its input pipe. The portable archive includes Python's license and uses a pinned, SHA256-verified runtime download during packaging.

This preview includes the shared 3.4.6 phone-view fixes: overlapping transcript refreshes do not duplicate messages, and Claude's synthetic records do not replace its model name. Rex and tmux terminal control remain macOS features.

## Credentials and paths

Toki reads the credentials that the CLIs already store. It never writes provider secrets, never refreshes tokens, and sends no telemetry.

**Claude Code.** Toki finds the local Claude Code credential file. It respects `CLAUDE_CONFIG_DIR`. Set a custom directory in Settings if the file is elsewhere.

**Codex.** Toki uses the local Codex auth through the app-server. It finds a native `codex.exe`, or the npm JavaScript entry run with `node`. It respects `CODEX_HOME`. Set a custom home or executable in Settings.

Toki does not use a shell to start Codex. It does not use WSL yet.

## Tester checklist

Sign in to Claude Code and Codex in a terminal before you start.

- **Launch.** Run `Toki.exe`. The tray icon and compact panel appear without flashing the full dashboard.
- **Login.** Both providers show data for the account you signed in with.
- **Quotas.** 5 hour and 7 day remaining values match what the CLIs report. Reset times look correct.
- **Refresh.** Click refresh. The last checked time updates.
- **Offline.** Disconnect the network, then refresh. Toki shows a clear error and does not show old quota as current.
- **Expired login.** Sign out in the CLI, then refresh. Toki shows a clear auth error.
- **Panel.** Left-click the tray icon to toggle the panel. Click outside or press Escape to dismiss it. Reopen it and confirm the same quota remains. No extra taskbar button appears for the panel.
- **Dashboard.** Choose Dashboard in the panel or tray menu. Close its window and confirm Toki stays running. Start Toki again and confirm only the compact panel opens.
- **Dark title bars.** Check the dashboard and Settings with Windows in light mode. Their title bars should match Toki's dark UI; native minimize/maximize/close buttons should still work.
- **Privacy.** Turn on Hide sensitive info in the tray. Account details, titles, paths and pairing details should be hidden; quotas stay visible. Restart and check it remains on. Reveal details to restore search.
- **Sign-in startup.** Enable it in Settings, then sign out/in. Only the tray icon should appear, and sharing should stay off. Disable and repeat; Toki should not start. Check Windows Startup apps if registration is overridden.
- **Conversation filters.** Search a title or project and switch providers; only matching recent conversations should remain. Clear the search and select All providers to restore the list.
- **Session tracking.** Start tracking, refresh quotas, then end it. Check the elapsed time, quota changes and Events summary. DND should still leave low-quota events.
- **Recent conversations.** Use Claude/Codex, wait 15 seconds, and confirm the conversation appears. Closed conversations can remain listed; this is expected.
- **Remote viewing.** Pair a phone, verify quotas, then stop and enable transcript sharing. Re-pair and confirm the selected conversation's transcript. There must be no working send/upload controls.
- **Revoke and stop.** Revoke the phone and confirm its next request fails. Stop sharing and confirm the link stops working. Restart Toki and confirm sharing is off.
- **Quit.** Quit from the tray and check that Toki and its Python companion exit.
- **Scaling.** Try 100, 125, 150, and 200 percent display scaling. Text and layout stay readable. Open the panel on each monitor and confirm it stays within that display above or beside the taskbar.
- **Notifications.** Enable notifications and wait for a low quota. Turn on DND and check that notifications stop.
- **Feedback.** Report the Windows version, the steps, and the exact error text. Do not send tokens, credentials, or transcripts.

## Build and test locally

Run the core tests (currently 91 tests):

```powershell
dotnet run --project Windows/Toki.Core.Tests -c Release
```

Build the portable package:

```powershell
pwsh ./scripts/package-windows.ps1 -OutputDirectory artifacts/windows -Version 4.0.0-preview.4 -Runtime win-x64
```

The script writes `artifacts/windows/Toki-windows-preview-4.0.0-preview.4-win-x64.zip` and `Toki-windows-preview-4.0.0-preview.4-win-x64.zip.sha256`.

Packaging downloads the pinned Python runtime from python.org and verifies its SHA256. The tester needs no separate .NET or Python install. Running the UI directly from source does not include Python; use the packaged build for Remote Control. Trimming and ReadyToRun are off, so the same publish works from macOS with the .NET 10 SDK and `EnableWindowsTargeting`.

ARM64 is optional and untested:

```powershell
pwsh ./scripts/package-windows.ps1 -OutputDirectory artifacts/windows -Version 4.0.0-preview.4 -Runtime win-arm64
```

## Continuous integration

`.github/workflows/windows.yml` runs on pull requests to `main` and `release/**`, on pushes to `main` and `release/**` (including `release/v4.0.0`), and on manual dispatch. It runs the core tests, publishes the self-contained `win-x64` package, starts the packaged `Toki.exe` with `--smoke-test`, runs real HTTP pairing/transcript/revocation tests against the bundled Python runtime, and uploads UI smoke images with the zip and its SHA256 file.

The artifact is versioned as `toki-windows-preview-4.0.0-preview.4-win-x64`. It is a preview build, not a stable release or a public installer.

The smoke test checks tray-first startup, compact-panel placement, dashboard close-to-tray, outside-click dismissal, and supported native dark-frame attributes before exiting with code 0. It uses fixture quotas and loopback HTTP only, with no provider credentials or provider requests. It does not validate real provider calls. Real validation needs a signed-in tester on Windows.

## Verify a download

Compare the zip hash with the `.sha256` file:

```powershell
Get-FileHash .\Toki-windows-preview-4.0.0-preview.4-win-x64.zip -Algorithm SHA256
```

## Limits

This is a preview. Do not expect macOS parity. Report bugs with the checklist details above.
