import Foundation
@preconcurrency import UserNotifications

extension UsageStore {
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

    func clearEvents() {
        eventGeneration += 1
        events = []
        usageState.events = []
        usageState.eventLastRecordedAt = [:]
        StateLoader.save(usageState)
    }

    func evaluateEventsAndNotifications(for snapshots: [AccountSnapshot], previous: [AccountSnapshot], at date: Date) {
        // uniquingKeysWith: a synthetic snapshot id (e.g. OpenCode's fixed auto-detected
        // id) could collide with a hand-picked config id - that should never crash
        // notification evaluation.
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
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
        if let last = usageState.eventLastRecordedAt[key],
           date.timeIntervalSince(last) < cooldown {
            return
        }

        let canAttemptDelivery = preferences.notificationsEnabled && !preferences.dndEnabled
        usageState.eventLastRecordedAt[key] = date
        guard canAttemptDelivery else {
            appendEvent(
                kind: kind,
                title: title,
                detail: preferences.dndEnabled ? "DND: \(detail)" : "Notifications disabled: \(detail)",
                deliveredNotification: false,
                at: date
            )
            return
        }

        let generation = eventGeneration
        deliverNotification(title: title, detail: detail) { delivered, failureDetail in
            guard generation == self.eventGeneration else { return }
            self.appendEvent(
                kind: kind,
                title: title,
                detail: delivered ? detail : "Not delivered: \(failureDetail ?? detail)",
                deliveredNotification: delivered,
                at: date
            )
        }
    }

    private func deliverNotification(
        title: String,
        detail: String,
        completion: @escaping @MainActor (Bool, String?) -> Void
    ) {
        resolveNotificationAuthorization { granted, error in
            if let error {
                Task { @MainActor in completion(false, error) }
                return
            }
            guard granted else {
                Task { @MainActor in completion(false, "notification permission denied") }
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = detail
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                Task { @MainActor in completion(error == nil, error?.localizedDescription) }
            }
        }
    }

    private func resolveNotificationAuthorization(completion: @escaping @Sendable (Bool, String?) -> Void) {
        if notificationAuthorization == true {
            completion(true, nil)
            return
        }
        // Only cache a granted result. A denied/undetermined state is re-checked so
        // enabling notifications in System Settings takes effect without a restart.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if error == nil && granted {
                Task { @MainActor in self?.notificationAuthorization = true }
            }
            completion(error == nil && granted, error?.localizedDescription)
        }
    }

    func appendEvent(
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

    func pruneState(now: Date) {
        let retention = TimeInterval(max(preferences.historyRetentionDays, 1) * 24 * 60 * 60)
        usageState.history = Array(usageState.history
            .filter { now.timeIntervalSince($0.timestamp) <= retention }
            .suffix(720))
        usageState.events = Array(usageState.events.suffix(160))
    }
}
