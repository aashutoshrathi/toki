import AppKit
import Foundation
import SwiftUI
@preconcurrency import UserNotifications

@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshots: [AccountSnapshot] = []
    @Published var lastUpdated: Date?
    @Published var statusText = "Loading"
    @Published var configError: String?
    @Published var debugMode = false
    @Published var debugLog: [DebugLogEntry] = []
    @Published var preferences = AppPreferences()
    @Published var events: [TokiEvent] = []
    @Published var history: [UsageHistoryEntry] = []
    @Published var session: SessionState?
    @Published var recommendation = SmartRecommendation(
        title: "Loading",
        detail: "Checking account quota.",
        accountID: nil,
        switchTarget: nil,
        switchCommand: nil,
        severity: .neutral
    )
    @Published var statusEntries: [MenuBarStatusEntry] = menuBarPlaceholderEntries()

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
            syncPublishedState()
            applyScheduledResets()
            configError = nil
            snapshots = config?.accounts.map(AccountSnapshot.loading) ?? []
            updateDerivedState(for: snapshots)
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
            updateDerivedState(for: snapshots)
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

    func updatePreferences(_ next: AppPreferences) {
        preferences = next
        usageState.preferences = next
        StateLoader.save(usageState)
        updateDerivedState(for: snapshots)
    }

    func setDND(_ isEnabled: Bool) {
        var next = preferences
        next.dndEnabled = isEnabled
        updatePreferences(next)
        appendEvent(
            kind: .notification,
            title: isEnabled ? "DND enabled" : "DND disabled",
            detail: isEnabled ? "Notifications will be recorded but not delivered." : "Notifications can be delivered again.",
            deliveredNotification: false
        )
    }

    func startSession() {
        let ratios = Dictionary(uniqueKeysWithValues: snapshots.compactMap { snapshot in
            snapshot.remainingRatio.map { (snapshot.id, $0) }
        })
        let primaries = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0.primary) })
        let next = SessionState(startedAt: Date(), startingRemainingRatios: ratios, startingPrimaries: primaries)
        session = next
        usageState.session = next
        StateLoader.save(usageState)
        appendEvent(kind: .session, title: "Session started", detail: "Toki is tracking quota burn for this coding session.", deliveredNotification: false)
    }

    func endSession() {
        guard let session else { return }
        let summary = sessionSummary(for: session)
        self.session = nil
        usageState.session = nil
        StateLoader.save(usageState)
        appendEvent(kind: .session, title: "Session ended", detail: summary, deliveredNotification: false)
    }

    func clearEvents() {
        events = []
        usageState.events = []
        StateLoader.save(usageState)
    }

    func switchBestAccount() {
        let current = smartRecommendation(for: snapshots)
        guard let target = current.switchTarget else { return }
        appendEvent(
            kind: .switchAccount,
            title: "Smart switch",
            detail: "Switching to \(current.title.replacingOccurrences(of: "Switch to ", with: "")).",
            deliveredNotification: false
        )
        switchClaudeAccount(target: target, command: current.switchCommand)
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
                appendEvent(kind: .switchAccount, title: "Account switched", detail: "Claude Code switched to \(target).", deliveredNotification: false)
                reloadConfig()
            case .failure(let error):
                statusText = "Switch failed"
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

    func sessionBurnLines() -> [MetricLine] {
        guard let session else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        return session.startingRemainingRatios.compactMap { accountID, startingRatio in
            guard let snapshot = byID[accountID], let current = snapshot.remainingRatio else { return nil }
            let burned = max(0, startingRatio - current)
            return MetricLine(label: snapshot.name, value: "\(percentText(burned)) burned")
        }
        .sorted { $0.label < $1.label }
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

    private func syncPublishedState() {
        preferences = usageState.preferences
        events = usageState.events.sorted { $0.timestamp > $1.timestamp }
        history = usageState.history.sorted { $0.timestamp > $1.timestamp }
        session = usageState.session
    }

    private func updateDerivedState(for snapshots: [AccountSnapshot]) {
        recommendation = smartRecommendation(for: snapshots)
        statusEntries = menuBarEntries(for: snapshots, mode: preferences.menuBarMode)
        if statusEntries.isEmpty {
            statusEntries = menuBarPlaceholderEntries()
        }
        statusText = menuBarStatus(for: snapshots, mode: preferences.menuBarMode)
        syncPublishedState()
    }

    private func recordHistory(for snapshots: [AccountSnapshot], at date: Date) {
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

    private func evaluateEventsAndNotifications(for snapshots: [AccountSnapshot], previous: [AccountSnapshot], at date: Date) {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        for snapshot in snapshots where !snapshot.isError {
            guard let ratio = snapshot.remainingRatio else { continue }
            let previousRatio = previousByID[snapshot.id]?.remainingRatio
            if ratio <= preferences.lowQuotaThreshold,
               previousRatio == nil || (previousRatio ?? 1) > preferences.lowQuotaThreshold {
                notifyOrRecord(
                    key: "lowQuota:\(snapshot.id)",
                    kind: .lowQuota,
                    title: "\(snapshot.name) is low",
                    detail: "\(snapshot.name) has \(percentText(ratio)) quota remaining.",
                    at: date
                )
            } else if ratio >= preferences.lowQuotaThreshold + 0.20,
                      let previousRatio,
                      previousRatio <= preferences.lowQuotaThreshold {
                notifyOrRecord(
                    key: "recovered:\(snapshot.id)",
                    kind: .recovered,
                    title: "\(snapshot.name) recovered",
                    detail: "\(snapshot.name) is back to \(percentText(ratio)) remaining.",
                    at: date
                )
            }
        }

        guard let session else { return }
        for snapshot in snapshots where !snapshot.isError {
            guard let current = snapshot.remainingRatio,
                  let starting = session.startingRemainingRatios[snapshot.id] else { continue }
            let burned = starting - current
            if current <= preferences.sessionWarningThreshold || burned >= 0.30 {
                notifyOrRecord(
                    key: "session:\(snapshot.id)",
                    kind: .session,
                    title: "Session quota warning",
                    detail: "\(snapshot.name) has \(percentText(current)) left after burning \(percentText(max(0, burned))).",
                    at: date
                )
            }
        }
    }

    private func notifyOrRecord(key: String, kind: TokiEventKind, title: String, detail: String, at date: Date) {
        let cooldown = TimeInterval(max(preferences.notificationCooldownMinutes, 5) * 60)
        if let last = usageState.notificationLastSentAt[key],
           date.timeIntervalSince(last) < cooldown {
            appendEvent(kind: kind, title: title, detail: "Cooldown: \(detail)", deliveredNotification: false, at: date)
            return
        }

        usageState.notificationLastSentAt[key] = date
        let canDeliver = preferences.notificationsEnabled && !preferences.dndEnabled
        appendEvent(
            kind: kind,
            title: title,
            detail: canDeliver ? detail : "DND: \(detail)",
            deliveredNotification: canDeliver,
            at: date
        )
        guard canDeliver else { return }
        deliverNotification(title: title, detail: detail)
    }

    private func deliverNotification(title: String, detail: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = detail
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }

    private func appendEvent(
        kind: TokiEventKind,
        title: String,
        detail: String,
        deliveredNotification: Bool,
        at date: Date = Date()
    ) {
        usageState.events.append(TokiEvent(
            timestamp: date,
            kind: kind,
            title: title,
            detail: detail,
            deliveredNotification: deliveredNotification
        ))
        pruneState(now: date)
        StateLoader.save(usageState)
        syncPublishedState()
    }

    private func pruneState(now: Date) {
        let retention = TimeInterval(max(preferences.historyRetentionDays, 1) * 24 * 60 * 60)
        usageState.history = usageState.history
            .filter { now.timeIntervalSince($0.timestamp) <= retention }
            .suffix(720)
        usageState.events = Array(usageState.events.suffix(160))
    }

    private func sessionSummary(for session: SessionState) -> String {
        let elapsed = formatDuration(seconds: Date().timeIntervalSince(session.startedAt))
        let lines = sessionBurnLines()
        guard !lines.isEmpty else { return "Tracked for \(elapsed)." }
        let top = lines.prefix(2).map { "\($0.label): \($0.value)" }.joined(separator: ", ")
        return "Tracked for \(elapsed). \(top)."
    }
}
