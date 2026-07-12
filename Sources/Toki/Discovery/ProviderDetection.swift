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

    private static func detectCodex() -> DetectedProvider? {
        let path = expandedPath("~/.codex/auth.json")
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var detail = "Signed in"
        let probeAccount = AccountConfig(id: "codex-probe", name: "Codex", provider: .codex)
        if let credentials = try? CodexCredentialReader.readCredentials(account: probeAccount),
           let email = credentials.email {
            detail = email
        }
        return DetectedProvider(
            provider: .codex,
            title: "Codex",
            detail: detail,
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
}
