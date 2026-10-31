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

    var id: String { makeAccount?().id ?? provider.rawValue }
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
    static func scan(allowsKeychain: Bool = true, accounts: [AccountConfig]) async -> [DetectedProvider] {
        await Task.detached(priority: .utility) {
            var detected: [DetectedProvider] = []
            if let claude = detectClaudeCode(allowsKeychain: allowsKeychain) { detected.append(claude) }
            detected += await detectCodexAccounts(configured: accounts)
            if let openCode = detectOpenCode() { detected.append(openCode) }
            if let pi = detectPi() { detected.append(pi) }
            if let grok = detectGrok() { detected.append(grok) }
            if let gemini = detectGemini() { detected.append(gemini) }
            if let cursor = detectCursor() { detected.append(cursor) }
            if let antigravity = detectAntigravity() { detected.append(antigravity) }
            if let fx = detectFx() { detected.append(fx) }
            if let sarvam = detectSarvamCode() { detected.append(sarvam) }
            if let zed = detectZed() { detected.append(zed) }
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
    // Configured accounts are probed first so their logins win over a newly found home. A home
    // behind a probe that failed is held back for this scan: that login is unknown, so the home
    // could be a duplicate, and an auto-connected duplicate would stay in config.json.
    private static func detectCodexAccounts(configured accounts: [AccountConfig]) async -> [DetectedProvider] {
        let configured = accounts.filter { $0.provider == .codex }
        let discovered = codexHomeAccounts(homeDirectory: NSHomeDirectory()).filter { candidate in
            !configured.contains { CodexAppServerClient.sameHome($0, candidate) }
        }
        let candidates = configured + withFreeIDs(discovered, taken: Set(accounts.map(\.id)))
        let probes = await probeCodexHomes(candidates)
        let configuredIDs = Set(configured.map(\.id))
        return codexAccountsToOffer(candidates, probes: probes, configuredIDs: configuredIDs).map { offer in
            DetectedProvider(
                provider: .codex,
                title: offer.account.name,
                detail: offer.email ?? "Signed in through Codex",
                makeAccount: { offer.account }
            )
        }
    }

    static func codexAccountsToOffer(
        _ candidates: [AccountConfig],
        probes: [CodexProbe],
        configuredIDs: Set<String>
    ) -> [(account: AccountConfig, email: String?)] {
        var seenIdentities = Set<String>()
        var earlierProbeFailed = false
        var offers: [(account: AccountConfig, email: String?)] = []
        for (account, probe) in zip(candidates, probes) {
            guard case .signedIn(let email, let identity) = probe else {
                earlierProbeFailed = earlierProbeFailed || probe == .failed
                continue
            }
            if let identity, !seenIdentities.insert(identity).inserted {
                continue
            }
            if earlierProbeFailed, !configuredIDs.contains(account.id) {
                DiagnosticLogger.shared.record(
                    .info,
                    component: "usage",
                    code: "codex_home_held_back",
                    detail: "home=\((CodexAppServerClient.codexHomeDirectory(for: account) as NSString).lastPathComponent)"
                )
                continue
            }
            offers.append((account, email))
        }
        return offers
    }

    enum CodexProbe: Equatable, Sendable {
        case signedIn(email: String?, identity: String?)
        case signedOut
        case failed
    }

    private static func probeCodexHomes(_ accounts: [AccountConfig]) async -> [CodexProbe] {
        await withTaskGroup(of: (Int, CodexProbe).self) { group in
            for (index, account) in accounts.enumerated() {
                group.addTask {
                    guard FileManager.default.fileExists(atPath: CodexAppServerClient.codexHomeDirectory(for: account)) else {
                        return (index, .signedOut)
                    }
                    do {
                        let signIn = try await CodexAppServerClient.readAccount(account: account)
                        guard CodexAccountInfo.isSignedIn(signIn) else {
                            return (index, .signedOut)
                        }
                        return (index, .signedIn(
                            email: CodexAccountInfo.email(from: signIn),
                            identity: CodexAccountInfo.identity(from: signIn)
                        ))
                    } catch {
                        return (index, .failed)
                    }
                }
            }
            var results = [CodexProbe](repeating: .failed, count: accounts.count)
            for await (index, probe) in group {
                results[index] = probe
            }
            return results
        }
    }

    static func withFreeIDs(_ accounts: [AccountConfig], taken: Set<String>) -> [AccountConfig] {
        var taken = taken
        return accounts.map { account in
            var account = account
            let base = account.id
            var suffix = 2
            while taken.contains(account.id) {
                account.id = "\(base)-\(suffix)"
                suffix += 1
            }
            taken.insert(account.id)
            return account
        }
    }

    // A second Codex account is signed in with `CODEX_HOME=~/.codex-work codex login`, so
    // extra homes are the folders next to ~/.codex that hold Codex's auth.json or config.toml.
    // The default home is always offered: a Keychain sign-in leaves neither file behind.
    static func codexHomeAccounts(homeDirectory: String) -> [AccountConfig] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: homeDirectory)) ?? []
        let extraHomes = names.sorted().compactMap { name -> AccountConfig? in
            guard name.lowercased().hasPrefix(".codex"), name.lowercased() != ".codex" else { return nil }
            let suffix = String(name.dropFirst(".codex".count).drop { "-_.".contains($0) })
            let slug = suffix.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: "-")
            let home = (homeDirectory as NSString).appendingPathComponent(name)
            guard !slug.isEmpty,
                  ["auth.json", "config.toml"].contains(where: {
                      FileManager.default.fileExists(atPath: (home as NSString).appendingPathComponent($0))
                  }) else {
                return nil
            }
            var account = AccountConfig(id: "codex-\(slug)", name: "Codex (\(suffix))", provider: .codex)
            account.codexAuthPath = "~/\(name)/auth.json"
            return account
        }
        return [AccountConfig(id: "codex", name: "Codex", provider: .codex)] + extraHomes
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

    // Zed has no quota API, so this is agent-detection-only: the card exists once Zed is
    // installed and fills with whatever its agent panel is running.
    private static func detectZed() -> DetectedProvider? {
        guard ZedThreadStore.isInstalled() else { return nil }
        return DetectedProvider(
            provider: .zed,
            title: "Zed",
            detail: "Zed detected",
            makeAccount: {
                AccountConfig(id: "zed", name: "Zed", provider: .zed)
            }
        )
    }

    private static func detectSarvamCode() -> DetectedProvider? {
        guard SarvamCodeUsageClient.autoDetectedAccount() != nil else { return nil }
        return DetectedProvider(
            provider: .sarvamCode,
            title: "Sarvam Code",
            detail: "Auto-detected from local usage - no setup needed",
            makeAccount: nil
        )
    }
}
