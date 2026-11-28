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
        // The reconcile and response construction live outside the task group: Swift 6.3.3
        // crashed type-checking them inside the closure's return-type inference, so the group
        // only reduces to the fetched results and the rest runs after it resolves.
        let orderedResults: [AccountFetchResult] = await withTaskGroup(of: (Int, AccountFetchResult).self) { group in
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
            return accounts.indices.compactMap { index in
                byIndex[index].map { withLocalActivity($0, account: accounts[index]) }
            }
        }

        let reconciled = reconcileCodexSnapshots(orderedResults.flatMap { $0.snapshots })
        return UsageFetchResponse(
            snapshots: reconcileSharedWeeklyQuota(reconciled),
            apiCallKeys: Set(orderedResults.flatMap { $0.apiCallKeys }),
            fetchedAt: fetchedAt
        )
    }

    static func reconcileSharedWeeklyQuota(_ snapshots: [AccountSnapshot]) -> [AccountSnapshot] {
        let cursorAccounts = snapshots.filter { $0.provider == .cursor }
        return snapshots.map { snapshot in
            guard snapshot.provider == .grok, let grok = snapshot.weeklySubscriptionQuota else { return snapshot }
            var result = snapshot
            if let reset = grok.window.resetAt,
               let cursor = cursorAccounts.first(where: {
                   guard let quota = $0.weeklySubscriptionQuota else { return false }
                   return quota.window.resetAt == reset && quota.email.caseInsensitiveCompare(grok.email) == .orderedSame
               }) {
                result.sharedWithCursorID = cursor.id
                result.primaryWindow = nil
                result.remainingRatio = nil
            } else {
                // Cached snapshots are already reconciled. Restore the CLI reading when a
                // matching Cursor account is no longer available.
                result.sharedWithCursorID = nil
                result.primaryWindow = grok.window
                result.remainingRatio = grok.ratio
            }
            return result
        }
    }

    static func reconcileCodexSnapshots(_ snapshots: [AccountSnapshot]) -> [AccountSnapshot] {
        // Two Codex homes that resolve to the same login are a config error, not a second
        // account, so reset redemption must not act on either. Built without tuple keypaths
        // (Dictionary(grouping:by:) over a tuple array) because Swift 6.3.3 crashed on them.
        var idsByIdentity: [String: [String]] = [:]
        for snapshot in snapshots where snapshot.provider == .codex {
            guard let identity = snapshot.codexIdentity, !identity.isEmpty else { continue }
            idsByIdentity[identity, default: []].append(snapshot.id)
        }
        var duplicateIDs = Set<String>()
        for ids in idsByIdentity.values where ids.count > 1 {
            duplicateIDs.formUnion(ids)
        }
        guard !duplicateIDs.isEmpty else { return snapshots }

        return snapshots.map { snapshot in
            guard duplicateIDs.contains(snapshot.id) else { return snapshot }
            let otherNames = snapshots
                .filter { $0.provider == .codex && $0.codexIdentity == snapshot.codexIdentity && $0.id != snapshot.id }
                .map(\.name)
                .joined(separator: ", ")
            var blocked = snapshot
            blocked.isError = true
            blocked.subtitle = "Codex account configuration error: this login is also configured as \(otherNames)."
            blocked.resetCreditsAvailable = 0
            blocked.resetCreditExpiry = nil
            return blocked
        }
    }

    private static func withLocalActivity(_ result: AccountFetchResult, account: AccountConfig) -> AccountFetchResult {
        let activity: Date?
        switch account.provider {
        case .claudeCode:
            activity = LocalAgentActivity.claudeCode()
        case .codex:
            activity = LocalAgentActivity.codex(codexHome: CodexAppServerClient.codexHomeDirectory(for: account))
        default:
            return result
        }
        guard let activity else { return result }
        var updated = result
        updated.snapshots = result.snapshots.map { snapshot in
            var snapshot = snapshot
            snapshot.lastActivity = [snapshot.lastActivity, activity].compactMap { $0 }.max()
            return snapshot
        }
        return updated
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
        if !configured.contains(where: { $0.provider == .sarvamCode }),
           let detected = SarvamCodeUsageClient.autoDetectedAccount() {
            accounts.append(detected)
        }
        if !configured.contains(where: { $0.provider == .zed }),
           let detected = zedAutoDetectedAccount() {
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

    private static func zedAutoDetectedAccount() -> AccountConfig? {
        guard ZedThreadStore.isInstalled() else { return nil }
        return AccountConfig(id: "zed-auto", name: "Zed", provider: .zed)
    }

    private static func antigravityAutoDetectedAccount() -> AccountConfig? {
        guard cliIsInstalled(named: "agy") else { return nil }
        return AccountConfig(id: "antigravity-auto", name: "Antigravity", provider: .antigravity)
    }

    static func cliIsInstalled(named name: String) -> Bool {
        installedCLI(named: name) != nil
    }

    static func installedCLI(named name: String) -> URL? {
        agentCommandSearchPath.split(separator: ":")
            .map { URL(fileURLWithPath: $0.replacingOccurrences(of: "$HOME", with: NSHomeDirectory()), isDirectory: true)
                .appendingPathComponent(name) }
            .first { CodexBinaryResolver.isRegularExecutable($0.path) }
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
        let cursorLogin = account.provider == .cursor ? CursorAuth.read() : nil
        if let cacheKey,
           let previous = previousSnapshots(for: account, previousByID: previousByID, cursorLogin: cursorLogin),
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
            case .copilot, .zed:
                snapshots = [agentOnlySnapshot(for: account)]
            case .grok, .antigravity:
                do {
                    let quota = try await CLIJSONProcess.run { cancellation in
                        switch account.provider {
                        case .grok: try GrokUsageClient.snapshot(for: account, cancellation: cancellation)
                        default: try AntigravityUsageClient.snapshot(for: account, cancellation: cancellation)
                        }
                    }
                    snapshots = [quota]
                } catch where !Task.isCancelled {
                    recordFetchFailure(account, code: "quota_unavailable", detail: diagnosticErrorDetail(error))
                    snapshots = [agentOnlySnapshot(for: account, detail: error.localizedDescription)]
                }
            case .cursor:
                snapshots = [try await CursorUsageClient(account: account)
                    .snapshot(previous: previousByID[account.id], login: cursorLogin)]
            case .fx:
                snapshots = [try await FxUsageClient(account: account).snapshot()]
            case .openCode:
                snapshots = [try await OpenCodeUsageClient(account: account).snapshot()]
            case .pi:
                snapshots = [try await PiUsageClient(account: account).snapshot()]
            case .sarvamCode:
                snapshots = [try await SarvamCodeUsageClient(account: account).snapshot()]
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
            recordFetchFailure(account, code: "sign_in_expired", detail: "")
            return AccountFetchResult(snapshots: [expiredSnapshot(for: account)], apiCallKeys: [])
        } catch let error as HTTPStatusError where error.statusCode == 429 {
            recordFetchFailure(account, code: "rate_limited", detail: diagnosticErrorDetail(error))
            if let previous = previousSnapshots(for: account, previousByID: previousByID) {
                return AccountFetchResult(snapshots: previous, apiCallKeys: attemptedKeys)
            }
            return AccountFetchResult(snapshots: [errorSnapshot(for: account, error: error)], apiCallKeys: attemptedKeys)
        } catch where isRateLimit(error) {
            recordFetchFailure(account, code: "rate_limited", detail: diagnosticErrorDetail(error))
            if let previous = previousSnapshots(for: account, previousByID: previousByID) {
                return AccountFetchResult(snapshots: previous, apiCallKeys: attemptedKeys)
            }
            return AccountFetchResult(snapshots: [errorSnapshot(for: account, error: error)], apiCallKeys: attemptedKeys)
        } catch where isConnectivityFailure(error) {
            recordFetchFailure(account, code: "offline", detail: diagnosticErrorDetail(error))
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

    private static func recordFetchFailure(_ account: AccountConfig, code: String, detail: String) {
        DiagnosticLogger.shared.record(
            .warning,
            component: "usage",
            code: "provider_fetch_\(code)",
            detail: "provider=\(account.provider.rawValue) \(detail)"
        )
    }

    private static func apiCacheKey(for account: AccountConfig) -> String? {
        switch account.provider {
        case .chatgpt, .claude, .copilot, .openCode, .pi, .sarvamCode, .zed, .manual:
            return nil
        case .claudeCode, .codex, .openai, .anthropic, .fx, .cursor, .grok, .antigravity:
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
        case .codex, .openai, .anthropic, .fx, .cursor, .grok, .antigravity:
            return defaultAPIRefreshInterval
        case .chatgpt, .claude, .copilot, .openCode, .pi, .sarvamCode, .zed, .manual:
            return 0
        }
    }

    private static func previousSnapshots(for account: AccountConfig, previousByID: [String: AccountSnapshot],
                                          cursorLogin: CursorAuth.Login? = nil) -> [AccountSnapshot]? {
        switch account.provider {
        case .claudeCode:
            let snapshots = previousByID.values
                .filter { $0.provider == .claudeCode && ($0.id == account.id || $0.id.hasPrefix("claude-")) }
                .filter { !$0.isLoadingPlaceholder }
                .sorted { $0.id < $1.id }
            return snapshots.isEmpty ? nil : snapshots
        case .cursor:
            guard let cursorLogin, let snapshot = CursorUsageClient.verifiedPrevious(previousByID[account.id], login: cursorLogin) else {
                return nil
            }
            return [snapshot]
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
            primary: "Sign-in expired",
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

    private static func agentOnlySnapshot(for account: AccountConfig, detail: String = "No usage API") -> AccountSnapshot {
        return AccountSnapshot(
            id: account.id,
            name: account.name,
            provider: account.provider,
            primary: "No usage API available",
            subtitle: detail,
            remainingRatio: nil,
            metrics: [],
            isError: false,
            isAgentDetectionOnly: true
        )
    }
}
