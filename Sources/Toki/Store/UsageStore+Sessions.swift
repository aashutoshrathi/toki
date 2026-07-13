import Foundation

extension UsageStore {
    func startSession() {
        // uniquingKeysWith (not uniqueKeysWithValues): config.json ids are validated
        // unique, but a synthetic snapshot (e.g. OpenCode's fixed auto-detected id) could
        // still collide with a hand-picked config id - that should never crash session start.
        let ratios = Dictionary(snapshots.compactMap { snapshot in
            snapshot.remainingRatio.map { (snapshot.id, $0) }
        }, uniquingKeysWith: { _, latest in latest })
        let primaries = Dictionary(snapshots.map { ($0.id, $0.primary) }, uniquingKeysWith: { _, latest in latest })
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

    func sessionBurnLines() -> [MetricLine] {
        guard let session else { return [] }
        let byID = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        return session.startingRemainingRatios.compactMap { accountID, startingRatio in
            guard let snapshot = byID[accountID], let current = snapshot.remainingRatio else { return nil }
            let burned = max(0, startingRatio - current)
            return MetricLine(label: snapshot.name, value: "\(percentText(burned)) burned")
        }
        .sorted { $0.label < $1.label }
    }

    private func sessionSummary(for session: SessionState) -> String {
        let elapsed = formatDuration(seconds: Date().timeIntervalSince(session.startedAt))
        let lines = sessionBurnLines()
        guard !lines.isEmpty else { return "Tracked for \(elapsed)." }
        let top = lines.prefix(2).map { "\($0.label): \($0.value)" }.joined(separator: ", ")
        return "Tracked for \(elapsed). \(top)."
    }
}
