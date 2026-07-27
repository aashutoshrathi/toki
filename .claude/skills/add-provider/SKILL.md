---
name: add-provider
description: Add support for a new AI coding agent/provider to Toki (e.g. Cursor, Devin, a new CLI). Use when the task is "add <tool> support", "detect <tool>", "show <tool> usage/agents", or wiring a new entry into the Provider enum. Covers agent-only providers (detected by their running CLI, no usage API) and, as an advanced case, providers with a real quota API.
---

# Adding a provider to Toki

Toki knows two kinds of provider:

- **Agent-only** (Copilot, Grok, Gemini, Cursor): no usage/quota API. Detected by scanning running processes, shown as a card that reads "No usage API available" plus live sessions in the Agents tab. Most new providers are this kind, so start here.
- **Usage-API** (Claude Code, Codex, OpenCode, Pi): has a readable quota/credential source, so it gets a dedicated client and a real percentage/spend card.

The fastest reference is the **Cursor** implementation. Read commits `6345d66` (detection) and `1743942` (auto-detected card); it is the exact template for an agent-only provider.

## Step 0a: get the logo

Ask the user for the provider's logo as a **local SVG file path or a URL** before writing UI code. Then:

- If a URL, download it. Prefer a clean single-color or flat SVG that reads at 16-22px.
- Save it as `Sources/Toki/Resources/<provider>-logo.svg`. `scripts/build-app.sh` copies `*-logo.svg` into the widget bundle automatically, so one file covers app and widget.
- If the user has no logo, fall back to an SF Symbol (like `.copilot` does) and note that a real logo can be dropped in later.

## Step 0b: find the real process name

Detection matches the process's **executable name** (and, for `node`/`bun` launchers, the script entrypoint). Run the tool's CLI and look at what it actually is:

```sh
ps -axo pid=,command= | grep -i <tool>
```

Gotchas:

- A launcher shell script that `exec`s a bundled `node` may keep its own name via `exec -a "$0"` (Cursor's `cursor-agent` does this, so argv[0] stays `cursor-agent`).
- If it instead runs as `node /path/.../index.js`, match on the **entrypoint path** (see the `@openai/codex` and `@github/copilot` cases in `providerForProcess`).
- The GUI/Desktop app's in-editor AI is **not** a separate process, so it cannot be seen via `ps` (same as VS Code/Copilot). Desktop support needs reading the app's local session files, a much bigger effort like the Claude Code/OpenCode readers. Scope it separately and ship the CLI first.

## Agent-only provider: checklist

Adding the enum case makes the compiler flag every exhaustive `switch` you still need to touch, so lean on that.

1. **`Sources/Toki/Models/Provider.swift`**
   - Add the `case` to `enum Provider`.
   - Add it to `displayName`.
   - Add it to the `false` group in `isConsumerTracked`.

2. **`Sources/Toki/Agents/ActiveAgent.swift`, `providerForProcess(executable:entrypoint:)`**
   - Add a match. Exact executable: `if executable == "<cli>" { return .<case> }`. If it runs via node, also handle `executable == "node" && entrypoint?.contains("/<pkg>/") == true`. Keep it narrow so unrelated processes do not match.

3. **`Sources/Toki/API/UsageFetcher.swift`**, three agent-only switches:
   - `snapshots(...)`: add the case alongside `.copilot, .grok, .gemini, .cursor`, returning `agentOnlySnapshot(for:)`.
   - `apiCacheKey(for:)`: add to the `nil` group.
   - `refreshInterval(for:)`: add to the `0` group.
   - Optional but recommended, auto-detect as a card: if the provider should appear whenever its CLI is installed (like Cursor), add a clause to `accountsIncludingAutoDetected` plus a small `<provider>AutoDetectedAccount()` that checks the binary exists (mirror `cursorAutoDetectedAccount`). Without this, the provider only appears as an agent row while a session runs, not as a standing card.

4. **`Sources/Toki/Discovery/ProviderDetection.swift`** (optional, onboarding "Connect")
   - Add `detect<Provider>()` returning a `DetectedProvider` (with a `makeAccount` that writes an `AccountConfig`) and call it in `scan()`.

5. **Logo, `Sources/Toki/Views/ProviderLogo.swift`**
   - Add a `case` in the `switch`. Either an SF Symbol (like `.copilot`) or `SVGLogoMark(asset: "<provider>-logo", size: size) { <fallback symbol> }` using the asset from Step 0a.
   - Widget glyph, `Sources/TokiWidgets/TokiWidgets.swift`: add the provider to `ProviderGlyph.assetName` (and, if using a symbol, `symbolName` / `fallbackColor`) and to the string-keyed `providerColor(_:)`.

6. **Test, `Tests/TokiTests/PiUsageClientTests.swift`, `testProcessClassificationIsNarrow`**
   - Add a positive case (the real command string, including the node/exec-a form you found in Step 0b) to `matches`, and a near-miss (e.g. `node /tmp/<tool>-helper.js`) to `nonMatches`.

## Verify

```sh
swift build            # both Toki + TokiWidgets must compile
swift test             # all tests green
scripts/install-app.sh # build the .app to ~/Applications
```

Then, to see live agent detection without the real CLI, spawn a stand-in with the expected argv[0] and open the Agents tab:

```sh
exec -a /path/to/<cli> sleep 600 &
```

## Usage-API provider (advanced)

Only if the tool exposes a readable quota/credential source:

- Add a `<Provider>UsageClient` under `Sources/Toki/API/` returning an `AccountSnapshot` with `remainingRatio` / `primaryWindow` (model it on `CodexUsageClient` or `ClaudeCodeUsageClient`).
- Wire it into the `snapshots(...)` switch in `UsageFetcher.swift` (its own arm, not `agentOnlySnapshot`), and give it a real `apiCacheKey` + `refreshInterval`.
- Add a credential reader plus `detect<Provider>()` in `ProviderDetection.swift` if it can be auto-connected.
- If it has multiple rate-limit windows, populate `primaryWindow`/`secondaryWindow` (see `CodexModels.swift`).

## Notes

- Follow the repo convention: no explanatory code comments. Put rationale in the commit/PR.
- Do not use em-dashes in any commit, PR, or doc text for this repo.
- CHANGELOG.md: add a line under the unreleased section.
- Multi-account: the quota-rings panel keys colors/dedupe by account id, not provider, so two accounts of one provider each get a ring. Nothing extra is needed for a new provider there.
