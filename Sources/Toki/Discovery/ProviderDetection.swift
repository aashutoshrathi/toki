import Foundation

// A CLI/tool Toki found signed in or installed on this machine, offered on the
// onboarding screen as a one-click "Connect" instead of hand-written config.json.
struct DetectedProvider: Identifiable, Sendable {
    let provider: Provider
    let title: String
    let detail: String
    // nil when there is nothing to write into config.json (e.g. OpenCode, which is
    // auto-tracked by UsageFetcher without a config entry).
    let makeAccount: (@Sendable () -> AccountConfig)?

    var id: String { provider.rawValue }
    var isConnectable: Bool { makeAccount != nil }
}

// Probes the machine for AI coding tools Toki already knows how to read credentials
// for, so onboarding can offer them as one-click connects instead of asking the user
// to hand-write config.json. Read-only: never touches config.json itself.
enum ProviderDetection {
    // Shells out to provider tools and touches the filesystem, so this runs off the main
    // actor (mirrors ActiveAgent.scan()) to avoid blocking the UI while onboarding loads.
    // `allowsKeychain` is what the setup checklist gates: reading Claude Code's sign-in raises the
    // system Keychain dialog, and a scan runs every time the popover opens, so on a fresh install
    // that dialog would arrive unasked-for. Codex resolves its own credential store inside the
    // Codex process, so it does not require Toki to read a Keychain secret directly.
    static func scan(allowsKeychain: Bool = true) async -> [DetectedProvider] {
        await Task.detached(priority: .utility) {
            var detected: [DetectedProvider] = []
            if let claude = detectClaudeCode(allowsKeychain: allowsKeychain) { detected.append(claude) }
            if let codex = await detectCodex() { detected.append(codex) }
            if let openCode = detectOpenCode() { detected.append(openCode) }
            if let pi = detectPi() { detected.append(pi) }
            if let grok = detectGrok() { detected.append(grok) }
            if let gemini = detectGemini() { detected.append(gemini) }
            if let cursor = detectCursor() { detected.append(cursor) }
            if let antigravity = detectAntigravity() { detected.append(antigravity) }
            if let fx = detectFx() { detected.append(fx) }
            return detected
        }.value
    }

    private static func detectClaudeCode(allowsKeychain: Bool) -> DetectedProvider? {
        guard let bundle = try? ClaudeCodeCredentialReader.readSignedInCredentials(allowsKeychain: allowsKeychain) else {
            return nil
        }
        let email = ClaudeCodeCredentialReader.emailIdentifier(from: bundle.credentials)
        return DetectedProvider(
            provider: .claudeCode,
            title: "Claude Code",
            detail: email ?? "Signed in via \(bundle.source)",
            makeAccount: {
                var account = AccountConfig(id: "claude-code", name: "Claude Code", provider: .claudeCode)
                account.claudeSwapCommand = "claude-swap"
                return account
            }
        )
    }

    // account/read is the one source of truth across Codex's file, keyring, and auto stores.
    // Toki never needs to read or duplicate the underlying access token.
    private static func detectCodex() async -> DetectedProvider? {
        let probeAccount = AccountConfig(id: "codex-probe", name: "Codex", provider: .codex)
        guard let account = try? await CodexAppServerClient.readAccount(account: probeAccount),
              CodexAccountInfo.isSignedIn(account) else {
            return nil
        }
        return DetectedProvider(
            provider: .codex,
            title: "Codex",
            detail: CodexAccountInfo.email(from: account) ?? "Signed in through Codex",
            makeAccount: {
                AccountConfig(id: "codex", name: "Codex", provider: .codex)
            }
        )
    }

    private static func detectOpenCode() -> DetectedProvider? {
        guard OpenCodeUsageClient.autoDetectedAccount() != nil else { return nil }
        return DetectedProvider(
            provider: .openCode,
            title: "OpenCode",
            detail: "Auto-detected from its local database - no setup needed",
            makeAccount: nil
        )
    }

    private static func detectPi() -> DetectedProvider? {
        guard PiUsageClient.autoDetectedAccount() != nil else { return nil }
        return DetectedProvider(
            provider: .pi,
            title: "Pi",
            detail: "Auto-detected from local session history - no setup needed",
            makeAccount: nil
        )
    }

    // Unlike Claude Code/Codex, there's no quota API to poll here - the grok CLI's own
    // subcommands have no account/usage/billing lookup. Still worth a config.json entry
    // (unlike OpenCode, which is auto-tracked without one) so it gets a real card instead
    // of only surfacing via agent detection in the Agents tab; UsageFetcher renders it as
    // an agent-detection-only snapshot (see agentOnlySnapshot).
    private static func detectGrok() -> DetectedProvider? {
        guard let credentials = try? GrokCredentialReader.readCredentials() else { return nil }
        return DetectedProvider(
            provider: .grok,
            title: "Grok",
            detail: credentials.email.map { "Signed in as \($0)" } ?? "Signed in",
            makeAccount: {
                AccountConfig(id: "grok", name: "Grok", provider: .grok)
            }
        )
    }

    // Same story as Grok: gemini-cli has no quota API for personal accounts either
    // (checked its shipped source directly), so this is agent-detection-only too.
    private static func detectGemini() -> DetectedProvider? {
        guard let credentials = try? GeminiCredentialReader.readCredentials() else { return nil }
        return DetectedProvider(
            provider: .gemini,
            title: "Gemini",
            detail: credentials.email.map { "Signed in as \($0)" } ?? "Signed in via Google OAuth",
            makeAccount: {
                AccountConfig(id: "gemini", name: "Gemini", provider: .gemini)
            }
        )
    }

    // Cursor has no quota API, so like Grok/Gemini this is agent-detection-only: detected by
    // the presence of the cursor-agent CLI, rendered as an agent-only card that fills with live
    // sessions in the Agents tab.
    private static func detectCursor() -> DetectedProvider? {
        guard UsageFetcher.cursorIsInstalled() else { return nil }
        return DetectedProvider(
            provider: .cursor,
            title: "Cursor",
            detail: "Cursor detected",
            makeAccount: {
                AccountConfig(id: "cursor", name: "Cursor", provider: .cursor)
            }
        )
    }

    private static func detectAntigravity() -> DetectedProvider? {
        guard UsageFetcher.cliIsInstalled(named: "agy") else { return nil }
        return DetectedProvider(
            provider: .antigravity,
            title: "Antigravity",
            detail: "agy CLI detected",
            makeAccount: {
                AccountConfig(id: "antigravity", name: "Antigravity", provider: .antigravity)
            }
        )
    }

    private static func detectFx() -> DetectedProvider? {
        guard FxUsageClient.autoDetectedAccount() != nil else { return nil }
        return DetectedProvider(
            provider: .fx,
            title: "fx",
            detail: "Auto-detected from local usage - no setup needed",
            makeAccount: nil
        )
    }
}
