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
    // Shells out to `security` and touches the filesystem, so this runs off the main
    // actor (mirrors ActiveAgent.scan()) to avoid blocking the UI while onboarding loads.
    static func scan() async -> [DetectedProvider] {
        await Task.detached(priority: .utility) {
            var detected: [DetectedProvider] = []
            if let claude = detectClaudeCode() { detected.append(claude) }
            if let codex = detectCodex() { detected.append(codex) }
            if let openCode = detectOpenCode() { detected.append(openCode) }
            if let grok = detectGrok() { detected.append(grok) }
            return detected
        }.value
    }

    private static func detectClaudeCode() -> DetectedProvider? {
        guard let bundle = try? ClaudeCodeCredentialReader.readMacOSKeychainCredentials() else { return nil }
        let email = ClaudeCodeCredentialReader.emailIdentifier(from: bundle.credentials)
        return DetectedProvider(
            provider: .claudeCode,
            title: "Claude Code",
            detail: email ?? "Signed in via Keychain",
            makeAccount: {
                var account = AccountConfig(id: "claude-code", name: "Claude Code", provider: .claudeCode)
                account.claudeSwapCommand = "claude-swap"
                return account
            }
        )
    }

    // Requires readCredentials() to actually succeed (file exists, parses, and contains a
    // non-empty OAuth access token) rather than just checking the auth file exists - a file
    // that's present but stale/malformed shouldn't be offered as a one-click connect.
    private static func detectCodex() -> DetectedProvider? {
        let probeAccount = AccountConfig(id: "codex-probe", name: "Codex", provider: .codex)
        guard let credentials = try? CodexCredentialReader.readCredentials(account: probeAccount) else { return nil }
        return DetectedProvider(
            provider: .codex,
            title: "Codex",
            detail: credentials.email ?? "Signed in",
            makeAccount: {
                var account = AccountConfig(id: "codex", name: "Codex", provider: .codex)
                account.codexAuthPath = "~/.codex/auth.json"
                return account
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
}
