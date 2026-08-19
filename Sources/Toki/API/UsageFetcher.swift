import Foundation

struct UsageFetchResponse {
    var snapshots: [AccountSnapshot]
    var apiCallKeys: Set<String>
    var fetchedAt: Date
}

struct AccountFetchResult {
    var snapshots: [AccountSnapshot]
    var apiCallKeys: [String]
}

enum UsageFetcher {
    private static let claudeRefreshInterval: TimeInterval = 7.5 * 60
    private static let defaultAPIRefreshInterval: TimeInterval = 5 * 60

    static func fetch(
        config: AppConfig,
        state: UsageState,
        previousSnapshots: [AccountSnapshot],
        minimumRefreshInterval: TimeInterval?
    ) async -> UsageFetchResponse {
        let accounts = accountsIncludingAutoDetected(config.accounts)
        // uniquingKeysWith (not uniqueKeysWithValues) so duplicate account ids never trap.
        let previousByID = Dictionary(previousSnapshots.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let fetchedAt = Date()
        return await withTaskGroup(of: (Int, AccountFetchResult).self) { group in
            for (index, account) in accounts.enumerated() {
                group.addTask {
                    await (
                        index,
                        snapshots(
                            for: account,
                            config: config,
                            state: state,
                            previousByID: previousByID,
                            lastCalledAt: state.apiLastCalledAt,
                            now: fetchedAt,
                            minimumRefreshInterval: minimumRefreshInterval
                        )
                    )
                }
            }

            var byIndex: [Int: AccountFetchResult] = [:]
            for await result in group {
                byIndex[result.0] = result.1
            }
            let orderedResults = accounts.indices.compactMap { byIndex[$0] }
            return UsageFetchResponse(
                snapshots: orderedResults.flatMap(\.snapshots),
                apiCallKeys: Set(orderedResults.flatMap(\.apiCallKeys)),
                fetchedAt: fetchedAt
            )
        }
    }

    // Appends synthetic local-only accounts when readable history exists. These are never
    // persisted and are suppressed by an explicitly configured account of the same type.
    private static func accountsIncludingAutoDetected(_ configured: [AccountConfig]) -> [AccountConfig] {
        var accounts = configured
        if !configured.contains(where: { $0.provider == .openCode }),
           let detected = OpenCodeUsageClient.autoDetectedAccount() {
            accounts.append(detected)
        }
        if !configured.contains(where: { $0.provider == .pi }),
           let detected = PiUsageClient.autoDetectedAccount() {
            accounts.append(detected)
        }
        if !configured.contains(where: { $0.provider == .cursor }),
           let detected = cursorAutoDetectedAccount() {
            accounts.append(detected)
        }
        if !configured.contains(where: { $0.provider == .antigravity }),
           let detected = antigravityAutoDetectedAccount() {
            accounts.append(detected)
        }
        if !configured.contains(where: { $0.provider == .fx }),
           let detected = FxUsageClient.autoDetectedAccount() {
            accounts.append(detected)
        }
        return accounts
    }

    private static func cursorAutoDetectedAccount() -> AccountConfig? {
        guard cursorIsInstalled() else { return nil }
        return AccountConfig(id: "cursor-auto", name: "Cursor", provider: .cursor)
    }

    static func cursorIsInstalled() -> Bool {
        if cliIsInstalled(named: "cursor-agent") { return true }
        return ["/Applications/Cursor.app", "~/Applications/Cursor.app"]
            .map { ($0 as NSString).expandingTildeInPath }
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    private static func antigravityAutoDetectedAccount() -> AccountConfig? {
        guard cliIsInstalled(named: "agy") else { return nil }
        return AccountConfig(id: "antigravity-auto", name: "Antigravity", provider: .antigravity)
    }

    static func cliIsInstalled(named name: String) -> Bool {
        ["~/.local/bin/", "/usr/local/bin/", "/opt/homebrew/bin/"]
            .map { ($0 + name as NSString).expandingTildeInPath }
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func snapshots(
        for account: AccountConfig,
        config: AppConfig,
        state: UsageState,
        previousByID: [String: AccountSnapshot],
        lastCalledAt: [String: Date],
        now: Date,
        minimumRefreshInterval: TimeInterval?
    ) async -> AccountFetchResult {
        let cacheKey = apiCacheKey(for: account)
        if let cacheKey,
           let previous = previousSnapshots(for: account, previousByID: previousByID),
           !isDue(
                account: account,
                cacheKey: cacheKey,
                lastCalledAt: lastCalledAt,
                now: now,
                minimumRefreshInterval: minimumRefreshInterval
           ) {
            return AccountFetchResult(snapshots: previous, apiCallKeys: [])
        }

        let attemptedKeys = cacheKey.map { [$0] } ?? []
        do {
            let snapshots: [AccountSnapshot]
            switch account.provider {
            case .claudeCode:
                snapshots = try await ClaudeCodeUsageClient(account: account, labels: config.accountLabels ?? []).snapshots()
            case .chatgpt, .claude, .manual:
                snapshots = [consumerSnapshot(for: account, state: state)]
            case .copilot, .grok, .gemini, .antigravity:
                snapshots = [agentOnlySnapshot(for: account)]
            case .cursor:
                snapshots = [await CursorUsageClient(account: account).snapshot()]
            case .fx:
                snapshots = [try await FxUsageClient(account: account).snapshot()]
            case .openCode:
                snapshots = [try await OpenCodeUsageClient(account: account).snapshot()]
            case .pi:
                snapshots = [try await PiUsageClient(account: account).snapshot()]
            case .openai:
                snapshots = [try await OpenAIUsageClient(account: account).snapshot()]
            case .codex:
                snapshots = [try await CodexUsageClient(account: account).snapshot()]
            case .anthropic:
                snapshots = [try await AnthropicUsageClient(account: account).snapshot()]
            }
            if containsRateLimit(snapshots),
               let previous = previousSnapshots(for: account, previousByID: previousByID) {
                return AccountFetchResult(snapshots: previous, apiCallKeys: attemptedKeys)
            }
            if suppressesAPICallTimestamp(snapshots) {
                return AccountFetchResult(snapshots: snapshots, apiCallKeys: [])
            }
            return AccountFetchResult(snapshots: snapshots, apiCallKeys: attemptedKeys)
        } catch is ClaudeSignInExpiredError {
            return AccountFetchResult(snapshots: [expiredSnapshot(for: account)], apiCallKeys: [])
        } catch let error as HTTPStatusError where error.statusCode == 429 {
            if let previous = previousSnapshots(for: account, previousByID: previousByID) {
                return AccountFetchResult(snapshots: previous, apiCallKeys: attemptedKeys)
            }
            return AccountFetchResult(snapshots: [errorSnapshot(for: account, error: error)], apiCallKeys: attemptedKeys)
        } catch where isRateLimit(error) {
            if let previous = previousSnapshots(for: account, previousByID: previousByID) {
                return AccountFetchResult(snapshots: previous, apiCallKeys: attemptedKeys)
            }
            return AccountFetchResult(snapshots: [errorSnapshot(for: account, error: error)], apiCallKeys: attemptedKeys)
        } catch where isConnectivityFailure(error) {
            // A network transition is not an account failure. Preserve the last successful
            // snapshot and leave the API timestamp untouched so reconnect can retry at once.
            if let previous = previousSnapshots(for: account, previousByID: previousByID) {
                return AccountFetchResult(snapshots: previous, apiCallKeys: [])
            }
            return AccountFetchResult(snapshots: [errorSnapshot(for: account, error: error)], apiCallKeys: [])
        } catch {
            DiagnosticLogger.shared.record(
                .error,
                component: "usage",
                code: "provider_fetch_failed",
                detail: "provider=\(account.provider.rawValue) \(diagnosticErrorDetail(error))"
            )
            return AccountFetchResult(snapshots: [errorSnapshot(for: account, error: error)], apiCallKeys: attemptedKeys)
        }
    }

    private static func apiCacheKey(for account: AccountConfig) -> String? {
        switch account.provider {
        case .chatgpt, .claude, .copilot, .openCode, .grok, .gemini, .pi, .antigravity, .manual:
            return nil
        case .claudeCode, .codex, .openai, .anthropic, .fx, .cursor:
            return "\(account.provider.rawValue):\(account.id)"
        }
    }

    private static func isDue(
        account: AccountConfig,
        cacheKey: String,
        lastCalledAt: [String: Date],
        now: Date,
        minimumRefreshInterval: TimeInterval?
    ) -> Bool {
        guard let lastCalledAt = lastCalledAt[cacheKey] else { return true }
        return now.timeIntervalSince(lastCalledAt) >= (minimumRefreshInterval ?? refreshInterval(for: account.provider))
    }

    private static func refreshInterval(for provider: Provider) -> TimeInterval {
        switch provider {
        case .claudeCode:
            return claudeRefreshInterval
        case .codex, .openai, .anthropic, .fx, .cursor:
            return defaultAPIRefreshInterval
        case .chatgpt, .claude, .copilot, .openCode, .grok, .gemini, .pi, .antigravity, .manual:
            return 0
        }
    }

    private static func previousSnapshots(for account: AccountConfig, previousByID: [String: AccountSnapshot]) -> [AccountSnapshot]? {
        switch account.provider {
        case .claudeCode:
            let snapshots = previousByID.values
                .filter { $0.provider == .claudeCode && ($0.id == account.id || $0.id.hasPrefix("claude-")) }
                .filter { !$0.isLoadingPlaceholder }
                .sorted { $0.id < $1.id }
            return snapshots.isEmpty ? nil : snapshots
        default:
            guard let snapshot = previousByID[account.id], !snapshot.isLoadingPlaceholder else {
                return nil
            }
            return [snapshot]
        }
    }

    private static func containsRateLimit(_ snapshots: [AccountSnapshot]) -> Bool {
        snapshots.contains { snapshot in
            isRateLimitDescription(snapshot.subtitle)
                || snapshot.metrics.contains { isRateLimitDescription($0.value) }
        }
    }

    private static func isRateLimit(_ error: Error) -> Bool {
        if let httpError = error as? HTTPStatusError {
            return httpError.statusCode == 429
        }
        return isRateLimitDescription(error.localizedDescription)
    }

    static func suppressesAPICallTimestamp(_ snapshots: [AccountSnapshot]) -> Bool {
        !snapshots.isEmpty && snapshots.allSatisfy(\.isSignInExpired)
    }

    static func isRateLimitDescription(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized.contains("http 429")
            || normalized.contains("status 429")
            || normalized.contains("rate_limit_error")
            || normalized.contains("rate limited")
    }

    private static func expiredSnapshot(for account: AccountConfig) -> AccountSnapshot {
        let expiry = ClaudeSignInExpiredError(accountLabel: account.name, isActiveAccount: true)
        return AccountSnapshot(
            id: account.id,
            name: account.name,
            provider: account.provider,
            primary: "Signed out",
            subtitle: expiry.localizedDescription,
            remainingRatio: nil,
            metrics: [MetricLine(label: "Sign-in", value: expiry.localizedDescription)],
            isError: true,
            isSignInExpired: true
        )
    }

    private static func errorSnapshot(for account: AccountConfig, error: Error) -> AccountSnapshot {
        AccountSnapshot(
            id: account.id,
            name: account.name,
            provider: account.provider,
            primary: "Unavailable",
            subtitle: error.localizedDescription,
            remainingRatio: nil,
            metrics: account.notes.map { [MetricLine(label: "Note", value: $0)] } ?? [],
            isError: true
        )
    }

    private static func consumerSnapshot(for account: AccountConfig, state: UsageState) -> AccountSnapshot {
        let label = account.limitLabel ?? "messages"
        let used = state.accounts[account.id]?.used ?? account.used ?? usageFromRemaining(account)
        let limit = account.limit ?? ((account.remaining ?? 0) + used)
        let remaining = account.remaining ?? max(limit - used, 0)
        let ratio = limit > 0 ? max(min(remaining / limit, 1), 0) : nil

        var metrics = [
            MetricLine(label: "Used", value: "\(formatCompact(used)) \(label)"),
            MetricLine(label: "Limit", value: "\(formatCompact(limit)) \(label)")
        ]
        if let resetsAt = account.resetsAt {
            metrics.append(MetricLine(label: "Resets", value: resetsAt))
        }
        if let nextReset = nextResetDate(for: account, state: state.accounts[account.id]) {
            metrics.append(MetricLine(label: "Next reset", value: relativeDate(nextReset)))
        }
        if let notes = account.notes {
            metrics.append(MetricLine(label: "Note", value: notes))
        }

        return AccountSnapshot(
            id: account.id,
            name: account.name,
            provider: account.provider,
            primary: "\(formatCompact(remaining)) \(label) left",
            subtitle: ratio.map { "\(Int(($0 * 100).rounded()))% remaining" } ?? "Consumer usage ledger",
            remainingRatio: ratio,
            metrics: metrics,
            canAdjust: true
        )
    }

    private static func agentOnlySnapshot(for account: AccountConfig) -> AccountSnapshot {
        AccountSnapshot(
            id: account.id,
            name: account.name,
            provider: account.provider,
            primary: "No usage API available",
            subtitle: "No usage API",
            remainingRatio: nil,
            metrics: [],
            isError: false,
            isAgentDetectionOnly: true
        )
    }
}
