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
        let accounts = config.accounts
        let previousByID = Dictionary(uniqueKeysWithValues: previousSnapshots.map { ($0.id, $0) })
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
            return AccountFetchResult(snapshots: snapshots, apiCallKeys: attemptedKeys)
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
        } catch {
            return AccountFetchResult(snapshots: [errorSnapshot(for: account, error: error)], apiCallKeys: attemptedKeys)
        }
    }

    private static func apiCacheKey(for account: AccountConfig) -> String? {
        switch account.provider {
        case .chatgpt, .claude, .manual:
            return nil
        case .claudeCode, .codex, .openai, .anthropic:
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
        case .codex, .openai, .anthropic:
            return defaultAPIRefreshInterval
        case .chatgpt, .claude, .manual:
            return 0
        }
    }

    private static func previousSnapshots(for account: AccountConfig, previousByID: [String: AccountSnapshot]) -> [AccountSnapshot]? {
        switch account.provider {
        case .claudeCode:
            let snapshots = previousByID.values
                .filter { $0.provider == .claudeCode && ($0.id == account.id || $0.id.hasPrefix("claude-")) }
                .filter { !isLoadingSnapshot($0) }
                .sorted { $0.id < $1.id }
            return snapshots.isEmpty ? nil : snapshots
        default:
            guard let snapshot = previousByID[account.id], !isLoadingSnapshot(snapshot) else {
                return nil
            }
            return [snapshot]
        }
    }

    private static func isLoadingSnapshot(_ snapshot: AccountSnapshot) -> Bool {
        snapshot.primary == "Refreshing" && snapshot.metrics.isEmpty && snapshot.remainingRatio == nil
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

    private static func isRateLimitDescription(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized.contains("http 429")
            || normalized.contains("status 429")
            || normalized.contains("429")
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
}
