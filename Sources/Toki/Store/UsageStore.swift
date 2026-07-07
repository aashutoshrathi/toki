import AppKit
import Foundation
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshots: [AccountSnapshot] = []
    @Published var lastUpdated: Date?
    @Published var statusText = "Loading"
    @Published var configError: String?
    @Published var debugMode = false
    @Published var debugLog: [DebugLogEntry] = []

    private var config: AppConfig?
    private var usageState = UsageState()
    private var timer: Timer?
    private var isRefreshing = false

    init() {
        reloadConfig()
    }

    var refreshInterval: TimeInterval {
        TimeInterval(max(config?.refreshMinutes ?? 5, 1) * 60)
    }

    func reloadConfig() {
        do {
            config = try ConfigLoader.load()
            usageState = StateLoader.load()
            applyScheduledResets()
            configError = nil
            snapshots = config?.accounts.map(AccountSnapshot.loading) ?? []
            scheduleRefresh()
            refresh(keepsExistingSnapshots: true, minimumRefreshInterval: 60)
        } catch {
            config = nil
            configError = error.localizedDescription
            statusText = "Config needed"
            snapshots = [
                AccountSnapshot(
                    id: "config-error",
                    name: "Config needed",
                    provider: .manual,
                    primary: "No config",
                    subtitle: ConfigLoader.path,
                    remainingRatio: nil,
                    progressRatio: nil,
                    metrics: [MetricLine(label: "Open README", value: "README.md")],
                    isError: true
                )
            ]
        }
    }

    func refresh(keepsExistingSnapshots: Bool = true, minimumRefreshInterval: TimeInterval? = nil) {
        guard let config, !isRefreshing else {
            if isRefreshing { logDebug("Refresh skipped - already in progress") }
            return
        }
        isRefreshing = true
        statusText = "Refreshing"
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
                logDebug("  [\(snapshot.id)] \(snapshot.name): \(snapshot.subtitle)")
            }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                snapshots = sorted
            }
            lastUpdated = Date()
            statusText = menuBarStatus(for: sorted)
        }
    }

    func adjustUsage(accountID: String, delta: Double) {
        guard let account = config?.accounts.first(where: { $0.id == accountID }), account.provider.isConsumerTracked else {
            return
        }
        let current = usageState.accounts[accountID]?.used ?? account.used ?? usageFromRemaining(account)
        let next = max(current + delta, 0)
        usageState.accounts[accountID] = AccountUsageState(
            used: next,
            lastResetAt: usageState.accounts[accountID]?.lastResetAt ?? resetAnchorDate(for: account)
        )
        StateLoader.save(usageState)
        refresh()
    }

    func resetUsage(accountID: String) {
        guard let account = config?.accounts.first(where: { $0.id == accountID }), account.provider.isConsumerTracked else {
            return
        }
        usageState.accounts[accountID] = AccountUsageState(used: 0, lastResetAt: Date())
        StateLoader.save(usageState)
        refresh()
    }

    func renameAccount(snapshot: AccountSnapshot, alias: String) {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var config else { return }

        if snapshot.provider.isClaudeAccount,
           let email = emailAddress(in: snapshot) {
            var labels = config.accountLabels ?? []
            if let index = labels.firstIndex(where: { $0.email.caseInsensitiveCompare(email) == .orderedSame }) {
                labels[index].nickname = trimmed
            } else {
                labels.append(AccountLabelConfig(
                    email: email,
                    organizationUuid: nil,
                    organizationName: organizationName(in: snapshot),
                    nickname: trimmed,
                    emoji: nil,
                    color: nil
                ))
            }
            config.accountLabels = labels
        } else if let index = config.accounts.firstIndex(where: { $0.id == snapshot.id }) {
            config.accounts[index].name = trimmed
        } else {
            return
        }

        do {
            try ConfigLoader.save(config)
            self.config = config
            snapshots = snapshots.map { current in
                guard current.id == snapshot.id else { return current }
                var updated = current
                updated.name = trimmed
                return updated
            }
        } catch {
            configError = "Could not save alias: \(error.localizedDescription)"
        }
    }

    func switchClaudeAccount(target: String, command: String?) {
        statusText = "Switching"
        let currentSnapshots = snapshots
        Task {
            let result = await Task.detached {
                Result {
                    try ClaudeSwapRunner.switchTo(target: target, command: command)
                }
            }.value

            switch result {
            case .success:
                reloadConfig()
            case .failure(let error):
                statusText = "Switch failed"
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

    private func scheduleRefresh() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(keepsExistingSnapshots: true) }
        }
    }

    private func applyScheduledResets() {
        guard let config else { return }
        var changed = false
        for account in config.accounts where account.provider.isConsumerTracked {
            guard let resetEveryHours = account.resetEveryHours, resetEveryHours > 0 else { continue }
            let currentState = usageState.accounts[account.id]
            let anchor = currentState?.lastResetAt ?? resetAnchorDate(for: account) ?? Date()
            let elapsed = Date().timeIntervalSince(anchor)
            let window = resetEveryHours * 3600
            if elapsed >= window {
                let windowsElapsed = floor(elapsed / window)
                let nextAnchor = anchor.addingTimeInterval(windowsElapsed * window)
                usageState.accounts[account.id] = AccountUsageState(used: 0, lastResetAt: nextAnchor)
                changed = true
            }
        }
        if changed {
            StateLoader.save(usageState)
        }
    }

    func logDebug(_ message: String) {
        guard debugMode else { return }
        debugLog.append(DebugLogEntry(timestamp: Date(), message: message))
        if debugLog.count > 100 {
            debugLog.removeFirst(debugLog.count - 100)
        }
    }

    func toggleDebug() {
        debugMode.toggle()
        if debugMode {
            debugLogHandler = { [weak self] in self?.logDebug($0) }
            logDebug("Debug mode enabled")
        } else {
            debugLogHandler = nil
        }
    }
}
