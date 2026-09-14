import SwiftUI

@MainActor
final class AnalyticsPresentationState: ObservableObject {
    @Published var selectedRange: SpendAnalyticsPanel.TimeRange = .day
    @Published var provider: Provider?
    @Published var pinnedDayID: String?
    @Published var scrollAnchor: String?
    @Published var activityExpanded = true
    @Published var spendExpanded = false
    @Published var quotaExpanded = true
    @Published private(set) var results: [Provider: LocalSpendRead] = [:]

    nonisolated static let localProviders: Set<Provider> = [.pi, .openCode, .fx, .sarvamCode]
    private var refreshID: Date?
    private var generation = 0

    var isLoading: Bool { results.values.contains { if case .loading = $0 { return true }; return false } }
    var successfulProviders: [Provider] {
        results.compactMap { provider, result in
            if case .loaded = result { return provider }
            return nil
        }.sorted { $0.displayName < $1.displayName }
    }
    var failures: [(provider: Provider, message: String)] {
        results.compactMap { provider, result in
            if case .failed(let message) = result { return (provider, message) }
            return nil
        }.sorted { $0.provider.displayName < $1.provider.displayName }
    }
    var rows: [SpendAnalyticsPanel.LocalSpendRow] {
        let loaded = results.values.flatMap { result -> [SpendAnalyticsPanel.LocalSpendRow] in
            if case .loaded(let rows) = result { return rows }
            return []
        }
        return Self.merge(loaded)
    }

    // Results belong to the app session, so closing a tab neither discards successful reads
    // nor turns a still-running file scan into a second scan on reopening.
    func load(
        providers: [Provider],
        refreshID newRefreshID: Date?,
        force: Bool = false,
        reader: @escaping @Sendable (Provider) -> LocalSpendRead = LocalSpendRead.read
    ) async {
        let requested = Set(providers).intersection(Self.localProviders)
        guard force || Set(results.keys) != requested || refreshID != newRefreshID else { return }
        generation += 1
        let request = generation
        refreshID = newRefreshID
        results = Dictionary(uniqueKeysWithValues: requested.map { ($0, .loading) })
        await read(requested.sorted { $0.rawValue < $1.rawValue }, generation: request, reader: reader)
    }

    func retryFailures(reader: @escaping @Sendable (Provider) -> LocalSpendRead = LocalSpendRead.read) async {
        guard !isLoading else { return }
        let providers = failures.map(\.provider)
        guard !providers.isEmpty else { return }
        generation += 1
        let request = generation
        for provider in providers { results[provider] = .loading }
        await read(providers, generation: request, reader: reader)
    }

    private func read(
        _ providers: [Provider],
        generation request: Int,
        reader: @escaping @Sendable (Provider) -> LocalSpendRead
    ) async {
        for provider in providers {
            // Aggregators synchronously read SQLite/JSONL files. Detaching only this boundary
            // keeps scrolling responsive without transferring provider stores across actors.
            let result = await Task.detached(priority: .utility) { reader(provider) }.value
            guard request == generation else { return }
            results[provider] = result
        }
    }

    nonisolated static func merge(_ rows: [SpendAnalyticsPanel.LocalSpendRow]) -> [SpendAnalyticsPanel.LocalSpendRow] {
        var totals: [String: SpendAnalyticsPanel.LocalSpendRow] = [:]
        for row in rows {
            var total = totals[row.currencyCode] ?? .init(currencyCode: row.currencyCode)
            total.today += row.today
            total.week += row.week
            total.month += row.month
            total.allTime += row.allTime
            total.todayTokens += row.todayTokens
            total.weekTokens += row.weekTokens
            total.monthTokens += row.monthTokens
            total.allTimeTokens += row.allTimeTokens
            totals[row.currencyCode] = total
        }
        return totals.values.sorted { $0.currencyCode < $1.currencyCode }
    }
}

enum LocalSpendRead: Equatable, Sendable {
    case loading
    case loaded([SpendAnalyticsPanel.LocalSpendRow])
    case failed(String)

    static func read(_ provider: Provider) -> LocalSpendRead {
        do {
            switch provider {
            case .pi:
                return .loaded(SpendAnalyticsPanel.spendRows(pi: try PiUsageClient.aggregate(), openCode: nil, fx: nil, sarvam: nil))
            case .openCode:
                return .loaded(SpendAnalyticsPanel.spendRows(pi: nil, openCode: try OpenCodeUsageClient.aggregate(), fx: nil, sarvam: nil))
            case .fx:
                return .loaded(SpendAnalyticsPanel.spendRows(pi: nil, openCode: nil, fx: try FxUsageClient.aggregate(), sarvam: nil))
            case .sarvamCode:
                return .loaded(SpendAnalyticsPanel.spendRows(pi: nil, openCode: nil, fx: nil, sarvam: try SarvamCodeUsageClient.aggregate()))
            default:
                return .failed("Local spend aggregation is not available for this provider.")
            }
        } catch {
            return .failed("Couldn’t read local session history: \(error.localizedDescription)")
        }
    }
}

@MainActor
final class EventPresentationState: ObservableObject {
    @Published var filter: TokiEventKind?
    @Published var expandedIDs: Set<UUID> = []
    @Published var scrollAnchor: String?

    nonisolated static let kinds: [TokiEventKind] = [
        .lowQuota, .recovered, .switchAccount, .session, .notification, .refresh, .reset, .serviceStatus
    ]

    nonisolated static func label(for kind: TokiEventKind) -> String {
        switch kind {
        case .lowQuota: return "Low quota"
        case .recovered: return "Quota recovered"
        case .switchAccount: return "Account switches"
        case .session: return "Sessions"
        case .notification: return "Notifications"
        case .refresh: return "Refreshes"
        case .reset: return "Quota resets"
        case .serviceStatus: return "Service status"
        }
    }

    nonisolated static func sections(
        _ events: [TokiEvent], filter: TokiEventKind?, calendar: Calendar = .current
    ) -> [(day: Date, events: [TokiEvent])] {
        let matching = events.filter { filter == nil || $0.kind == filter }
        return Dictionary(grouping: matching) { calendar.startOfDay(for: $0.timestamp) }
            .map { (day: $0.key, events: $0.value.sorted { $0.timestamp > $1.timestamp }) }
            .sorted { $0.day > $1.day }
    }

    nonisolated static func dateLabel(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
    }
}
