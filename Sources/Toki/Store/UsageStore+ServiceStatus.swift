import Foundation

extension UsageStore {
    /// Status pages change far more slowly than quota does, and they are shared infrastructure
    /// rather than a per-account API, so they are polled on their own longer clock instead of
    /// once per usage refresh.
    static let serviceStatusRefreshInterval: TimeInterval = 5 * 60

    /// Checks the status pages of the providers this install actually uses.
    ///
    /// Providers are taken from the accounts on screen plus whatever agents are running, so a
    /// Claude-only install never calls OpenAI's page, and no call is made at all for a provider
    /// that publishes no status page Toki reads.
    func refreshServiceStatus(for snapshots: [AccountSnapshot], force: Bool = false) {
        guard isNetworkAvailable, !isCheckingServiceStatus else { return }
        let now = Date()
        if !force, let last = serviceStatusCheckedAt,
           now.timeIntervalSince(last) < Self.serviceStatusRefreshInterval {
            return
        }
        let tracked = Set(snapshots.map(\.provider)).union(activeAgents.map(\.provider))
        let sources = ServiceStatusSource.sources(covering: tracked)
        guard !sources.isEmpty else { return }

        isCheckingServiceStatus = true
        serviceStatusCheckedAt = now
        Task {
            defer { isCheckingServiceStatus = false }
            let fetched = await ServiceStatusClient.fetch(sources: sources, checkedAt: now)
            // Every page failed: keep the last answer rather than reporting a provider as
            // healthy just because Toki could not ask.
            guard !fetched.isEmpty else { return }
            let previous = serviceStatuses
            serviceStatuses = fetched
            logDebug("Service status: \(disruptionSummary(for: fetched, tracked: tracked))")
            recordServiceStatusEvents(previous: previous, current: fetched, tracked: tracked, at: now)
        }
    }

    /// Service health for an account's provider, and only when it is worth showing - an
    /// operational provider says nothing the card does not already say.
    func disruptedServiceStatus(for provider: Provider) -> ServiceStatus? {
        guard let status = serviceStatuses[provider], status.level.isDisrupted else { return nil }
        return status
    }

    private func recordServiceStatusEvents(
        previous: [Provider: ServiceStatus],
        current: [Provider: ServiceStatus],
        tracked: Set<Provider>,
        at date: Date
    ) {
        for provider in tracked.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let status = current[provider] else { continue }
            let previousLevel = previous[provider]?.level
            let host = status.pageURL.host ?? status.pageURL.absoluteString

            if status.level.isDisrupted, previousLevel != status.level {
                appendEvent(
                    kind: .serviceStatus,
                    title: "\(provider.displayName) \(status.level.eventPhrase)",
                    detail: "\(status.detail) (\(host))",
                    deliveredNotification: false,
                    at: date
                )
            } else if !status.level.isDisrupted, let previousLevel, previousLevel.isDisrupted {
                appendEvent(
                    kind: .recovered,
                    title: "\(provider.displayName) is back up",
                    detail: "\(status.pageDescription) (\(host))",
                    deliveredNotification: false,
                    at: date
                )
            }
        }
    }

    private func disruptionSummary(for statuses: [Provider: ServiceStatus], tracked: Set<Provider>) -> String {
        let disrupted = tracked
            .compactMap { statuses[$0] }
            .filter { $0.level.isDisrupted }
            .sorted { $0.provider.rawValue < $1.provider.rawValue }
        guard !disrupted.isEmpty else { return "all clear" }
        return disrupted
            .map { "\($0.provider.displayName) \($0.level.label.lowercased())" }
            .joined(separator: ", ")
    }
}
