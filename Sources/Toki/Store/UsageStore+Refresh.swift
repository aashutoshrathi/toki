import SwiftUI

extension UsageStore {
    func refresh(keepsExistingSnapshots: Bool = true, minimumRefreshInterval: TimeInterval? = nil) {
        guard let config, !isRefreshing else {
            if isRefreshing { logDebug("Refresh skipped - already in progress") }
            return
        }
        isRefreshing = true
        logDebug("Refresh started")
        if !keepsExistingSnapshots || snapshots.isEmpty {
            snapshots = config.accounts.map(AccountSnapshot.loading)
        }
        let currentState = usageState
        let previousSnapshots = snapshots

        Task {
            defer { isRefreshing = false }
            let response = await UsageFetcher.fetch(
                config: config,
                state: currentState,
                previousSnapshots: previousSnapshots,
                minimumRefreshInterval: minimumRefreshInterval
            )
            for key in response.apiCallKeys {
                usageState.apiLastCalledAt[key] = response.fetchedAt
            }
            if !response.apiCallKeys.isEmpty {
                StateLoader.save(usageState)
            }
            let sorted = sortedByAvailability(response.snapshots)
            let errorCount = sorted.filter(\.isError).count
            logDebug("Refresh complete: \(sorted.count) accounts (\(errorCount) errors)")
            for snapshot in sorted where snapshot.isError {
                logDebug("  \(snapshot.provider.displayName): unavailable")
            }
            recordHistory(for: sorted, at: response.fetchedAt)
            evaluateEventsAndNotifications(for: sorted, previous: previousSnapshots, at: response.fetchedAt)
            pruneState(now: response.fetchedAt)
            StateLoader.save(usageState)
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                snapshots = sorted
            }
            lastUpdated = Date()
            updateDerivedState(for: sorted)
        }
    }

    func updateDerivedState(for snapshots: [AccountSnapshot]) {
        recommendation = smartRecommendation(for: snapshots)
        statusEntries = menuBarEntries(for: snapshots, mode: preferences.menuBarMode)
        if statusEntries.isEmpty {
            statusEntries = menuBarPlaceholderEntries()
        }
        syncPublishedState()
        refreshAIInsight(for: snapshots)
        StatusCacheStore.write(snapshots: snapshots, recommendation: recommendation, menuBarEntries: statusEntries)
    }

    func recordHistory(for snapshots: [AccountSnapshot], at date: Date) {
        let candidates = snapshots.filter { !$0.isError && $0.remainingRatio != nil }
        for snapshot in candidates {
            let last = usageState.history
                .filter { $0.accountID == snapshot.id }
                .max { $0.timestamp < $1.timestamp }
            let shouldAppend = last == nil
                || date.timeIntervalSince(last?.timestamp ?? .distantPast) >= 15 * 60
                || abs((last?.remainingRatio ?? 0) - (snapshot.remainingRatio ?? 0)) >= 0.02
            guard shouldAppend else { continue }
            usageState.history.append(UsageHistoryEntry(
                timestamp: date,
                accountID: snapshot.id,
                accountName: snapshot.name,
                provider: snapshot.provider,
                remainingRatio: snapshot.remainingRatio,
                primary: snapshot.primary
            ))
        }
    }

    func switchBestAccount() {
        let current = recommendation
        guard let target = current.switchTarget else { return }
        appendEvent(
            kind: .switchAccount,
            title: "Smart switch",
            detail: "Switching to \(recommendedAccountName(from: current)).",
            deliveredNotification: false
        )
        switchClaudeAccount(target: target, command: current.switchCommand)
    }

    private func recommendedAccountName(from recommendation: SmartRecommendation) -> String {
        if let accountID = recommendation.accountID,
           let snapshot = snapshots.first(where: { $0.id == accountID }) {
            return snapshot.name
        }
        return recommendation.title
            .replacingOccurrences(of: "Switch to ", with: "")
            .replacingOccurrences(of: "Use ", with: "")
            .replacingOccurrences(of: " now", with: "")
    }

    func switchClaudeAccount(target: String, command: String?) {
        let currentSnapshots = snapshots
        Task {
            let result = await Task.detached {
                Result {
                    try ClaudeSwapRunner.switchTo(target: target, command: command)
                }
            }.value

            switch result {
            case .success:
                appendEvent(kind: .switchAccount, title: "Account switched", detail: "Claude Code switched to \(target).", deliveredNotification: false)
                reloadConfig()
            case .failure(let error):
                DiagnosticLogger.shared.record(.error, component: "account_switch", code: "switch_failed", detail: diagnosticErrorDetail(error))
                appendEvent(kind: .switchAccount, title: "Switch failed", detail: error.localizedDescription, deliveredNotification: false)
                snapshots = currentSnapshots.map { snapshot in
                    guard snapshot.switchTarget == target else { return snapshot }
                    var failed = snapshot
                    failed.isError = true
                    failed.metrics = [MetricLine(label: "Switch", value: error.localizedDescription)] + snapshot.metrics
                    return failed
                }
            }
        }
    }
}
