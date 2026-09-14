import Charts
import SwiftUI

struct SpendAnalyticsPanel: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var presentation: AnalyticsPresentationState

    enum TimeRange: String, CaseIterable, Identifiable {
        case day = "24h"
        case week = "7d"
        case month = "30d"
        case all = "All history"
        var id: String { rawValue }
        var days: Int? {
            switch self {
            case .day: return 1
            case .week: return 7
            case .month: return 30
            case .all: return nil
            }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                summarySection.id("summary")
                DisclosureGroup("Activity", isExpanded: $presentation.activityExpanded) {
                    UsageHeatmap(store: store, presentation: presentation)
                        .padding(.top, 8)
                }
                .id("activity")
                DisclosureGroup("Spend details", isExpanded: $presentation.spendExpanded) {
                    spendSection.padding(.top, 8)
                }
                .id("spend")
                DisclosureGroup("Quota history", isExpanded: $presentation.quotaExpanded) {
                    quotaSection.padding(.top, 8)
                }
                .id("quota")
            }
            .font(.system(size: 13))
            .scrollTargetLayout()
            .padding(2)
        }
        .scrollPosition(id: $presentation.scrollAnchor, anchor: .top)
        .frame(maxHeight: .infinity)
        .task(id: localLoadID) {
            await presentation.load(providers: localProviders, refreshID: store.lastUpdated)
        }
    }

    private var localProviders: [Provider] {
        Array(Set(store.snapshots.map(\.provider)))
            .filter { AnalyticsPresentationState.localProviders.contains($0) }
            .sorted { $0.displayName < $1.displayName }
    }

    private var localLoadID: String {
        localProviders.map(\.rawValue).joined(separator: ",") + String(describing: store.lastUpdated)
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text("Local session spend today")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if !localProviders.isEmpty {
                    Button {
                        Task { await presentation.load(providers: localProviders, refreshID: store.lastUpdated, force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(presentation.isLoading)
                    .help("Reload local spend")
                    .accessibilityLabel("Reload local spend")
                }
            }
            if presentation.isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading local session history…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(presentation.rows, id: \.currencyCode) { row in
                HStack(alignment: .firstTextBaseline) {
                    Text(formatMoney(Money(amount: row.today, currencyCode: row.currencyCode)))
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    Text(row.currencyCode)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(formatCompact(row.todayTokens)) tokens")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            if !presentation.successfulProviders.isEmpty {
                Text("Includes \(presentation.successfulProviders.map(\.displayName).joined(separator: ", ")). Local history only; provider billing summaries are separate.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if localProviders.isEmpty {
                Text("No supported local spend history connected. Provider billing and quota readings appear below when available.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if !presentation.failures.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(presentation.rows.isEmpty ? "Local spend unavailable" : "Partial coverage")
                        .font(.system(size: 13, weight: .medium))
                    ForEach(presentation.failures, id: \.provider) { failure in
                        Text("\(failure.provider.displayName): \(failure.message)")
                            .font(.system(size: 11))
                            .textSelection(.enabled)
                    }
                    Button("Retry failed reads") {
                        Task { await presentation.retryFailures() }
                    }
                    .controlSize(.small)
                    .disabled(presentation.isLoading)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .contentSurface()
    }

    private var spendSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(presentation.rows, id: \.currencyCode) { row in
                VStack(alignment: .leading, spacing: 8) {
                    Text(row.currencyCode)
                        .font(.system(size: 13, weight: .semibold))
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        spendBlock(label: "Today", money: Money(amount: row.today, currencyCode: row.currencyCode), tokens: row.todayTokens)
                        spendBlock(label: "This week", money: Money(amount: row.week, currencyCode: row.currencyCode), tokens: row.weekTokens)
                        spendBlock(label: "This month", money: Money(amount: row.month, currencyCode: row.currencyCode), tokens: row.monthTokens)
                        spendBlock(label: "All time", money: Money(amount: row.allTime, currencyCode: row.currencyCode), tokens: row.allTimeTokens)
                    }
                }
            }
            if !presentation.rows.isEmpty {
                Text("Week and month totals follow the current calendar in your time zone.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            let costProviders = store.snapshots.filter { !$0.isError && $0.remainingRatio == nil && $0.menuBarValue != nil }
            if !costProviders.isEmpty {
                Text("Provider readings")
                    .font(.system(size: 13, weight: .semibold))
                ForEach(costProviders) { snap in
                    HStack(spacing: 8) {
                        ProviderLogo(provider: snap.provider, size: 16)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(snap.name).font(.system(size: 13, weight: .medium))
                            Text(snap.menuBarValuePeriod ?? "Provider-reported period")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(snap.menuBarValue ?? "")
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                    }
                    .padding(10)
                    .contentSurface()
                }
            }
            let groups = Self.sessionCostGroups(store.activeAgents)
            if !groups.isEmpty {
                Text("Active session costs")
                    .font(.system(size: 13, weight: .semibold))
                Text("Current sessions, shown separately from historical totals.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                ForEach(groups, id: \.currencyCode) { group in
                    sessionCostList(agents: group.agents, currencyCode: group.currencyCode)
                }
            }
            if presentation.rows.isEmpty && costProviders.isEmpty && groups.isEmpty && !presentation.isLoading {
                emptyState(icon: "dollarsign.circle", text: presentation.failures.isEmpty ? "No spend data yet" : "Retry local history reads above")
            }
        }
    }

    private func spendBlock(label: String, money: Money, tokens: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(formatMoney(money))
                .font(.system(size: 13, weight: .regular, design: .monospaced))
            Text("\(formatCompact(tokens)) tokens")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .contentSurface()
    }

    private func sessionCostList(agents: [ActiveAgent], currencyCode: String) -> some View {
        let maxCost = agents.compactMap(\.sessionUsage?.cost).max() ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            Text(currencyCode).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            ForEach(agents) { agent in
                let identity = SessionIdentityPresentation(agent: agent, among: store.activeAgents)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        ProviderLogo(provider: agent.provider, size: 16)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(identity.title).font(.system(size: 13, weight: .medium))
                            if let context = identity.context {
                                Text(context).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Text(identity.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Text(agent.sessionUsage?.displayCost ?? "")
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                    }
                    ProgressView(value: Self.relativeSessionCost(agent, maximum: maxCost))
                        .tint(.accentColor)
                        .accessibilityHidden(true)
                    if let usage = agent.sessionUsage {
                        Text(usage.displayTokens).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .contentSurface()
            }
        }
    }

    nonisolated static func sessionCostGroups(_ agents: [ActiveAgent]) -> [(currencyCode: String, agents: [ActiveAgent])] {
        let billed = agents.filter { $0.sessionUsage?.cost != nil }
        return Dictionary(grouping: billed) { $0.sessionUsage?.currencyCode ?? "USD" }
            .map { currency, values in
                (currencyCode: currency, agents: values.sorted {
                    let lhs = $0.sessionUsage?.cost ?? 0
                    let rhs = $1.sessionUsage?.cost ?? 0
                    return lhs == rhs ? $0.id < $1.id : lhs > rhs
                })
            }
            .sorted { $0.currencyCode < $1.currencyCode }
    }

    nonisolated static func relativeSessionCost(_ agent: ActiveAgent, maximum: Double) -> Double {
        guard maximum > 0, maximum.isFinite, let cost = agent.sessionUsage?.cost, cost.isFinite else { return 0 }
        return min(1, max(0, cost / maximum))
    }

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Quota remaining")
                    .font(.system(size: 13, weight: .semibold))
                Picker("Quota history range", selection: $presentation.selectedRange) {
                    ForEach(TimeRange.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            // Quota-based account cards
            let quotaProviders = store.snapshots.filter { !$0.isError && $0.remainingRatio != nil }
            if !quotaProviders.isEmpty {
                ForEach(quotaProviders) { snap in
                    HStack(spacing: 8) {
                        ProviderLogo(provider: snap.provider, size: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(snap.name)
                                .font(.system(size: 13, weight: .medium))
                            Text(snap.provider.displayName)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let ratio = snap.remainingRatio {
                            Text(ratio, format: PercentFormat())
                                .font(.system(size: 13, weight: .regular, design: .monospaced))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentSurface()
                }
            }

            // Quota history chart
            let points = chartData
            if points.isEmpty {
                if quotaProviders.isEmpty {
                    emptyState(icon: "chart.line.flattrend.xyaxis", text: "No quota data yet")
                } else {
                    emptyState(icon: "chart.line.flattrend.xyaxis", text: "Not enough history yet")
                }
            } else {
                Chart {
                    ForEach(points) { point in
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Remaining", point.remainingRatio)
                        )
                        // Keyed on the display name, not the account id. The id is the registry's
                        // internal key ("claude-1-user@example.com"), and Charts puts the series
                        // value straight into the legend - so the legend was showing the raw key.
                        .foregroundStyle(by: .value("Account", point.accountName))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
                .chartYAxis {
                    AxisMarks(values: [0, 0.25, 0.5, 0.75, 1]) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: PercentFormat())
                    }
                }
                .chartXAxis {
                    // Explicit marks and a range-appropriate format. The default produced labels
                    // like "Jul 20 at 10 PM" - long enough that they collided and truncated to
                    // "Jul 21 at 1…", which reads as a broken label rather than a time.
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        if let date = value.as(Date.self) {
                            AxisValueLabel {
                                Text(date, format: axisDateFormat)
                                    .font(.system(size: 11))
                            }
                        }
                    }
                }
                .chartYScale(domain: 0...1)
                .chartLegend(position: .bottom, spacing: 8)
                .frame(height: 180)
            }
        }
    }

    /// Time labels scaled to the window being shown: a day of history wants clock times, a
    /// month wants dates. Showing both at every range is what made the labels too wide to fit.
    private var axisDateFormat: Date.FormatStyle {
        switch presentation.selectedRange {
        case .day:
            return .dateTime.hour()
        case .week:
            return .dateTime.weekday(.abbreviated).day()
        case .month, .all:
            return .dateTime.month(.abbreviated).day()
        }
    }

    private var chartData: [QuotaPoint] {
        let cutoff = presentation.selectedRange.days.flatMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) }
        let aliasMap = Dictionary(store.snapshots.map { ($0.id, $0.name) }, uniquingKeysWith: { _, last in last })
        // When a provider has exactly one active account, remap all its history entries to
        // that account's ID. This prevents old auto-detected IDs (e.g. "claude-code") and
        // configured IDs (e.g. "claude-1-user@gmail.com") from appearing as separate lines.
        let activeByProvider = Dictionary(grouping: store.snapshots.filter { !$0.isError }, by: \.provider)
        let remapTable: [String: String] = store.history.reduce(into: [:]) { table, entry in
            guard table[entry.accountID] == nil,
                  let active = activeByProvider[entry.provider],
                  active.count == 1, let sole = active.first,
                  sole.id != entry.accountID else { return }
            table[entry.accountID] = sole.id
        }
        return store.history
            .filter { entry in
                guard let cutoff else { return true }
                return entry.timestamp >= cutoff
            }
            .compactMap { entry -> QuotaPoint? in
                guard let ratio = entry.remainingRatio else { return nil }
                let resolvedID = remapTable[entry.accountID] ?? entry.accountID
                return QuotaPoint(
                    timestamp: entry.timestamp,
                    accountID: resolvedID,
                    accountName: aliasMap[resolvedID] ?? entry.accountName,
                    remainingRatio: ratio
                )
            }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private struct QuotaPoint: Identifiable {
        let id: String
        let timestamp: Date
        let accountID: String
        let accountName: String
        let remainingRatio: Double

        init(timestamp: Date, accountID: String, accountName: String, remainingRatio: Double) {
            self.id = "\(timestamp.timeIntervalSince1970)-\(accountID)"
            self.timestamp = timestamp
            self.accountID = accountID
            self.accountName = accountName
            self.remainingRatio = remainingRatio
        }
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 24))
            Text(text).font(.system(size: 13))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    struct LocalSpendRow: Equatable, Sendable {
        let currencyCode: String
        var today = 0.0
        var week = 0.0
        var month = 0.0
        var allTime = 0.0
        var todayTokens = 0.0
        var weekTokens = 0.0
        var monthTokens = 0.0
        var allTimeTokens = 0.0
    }

    nonisolated static func spendRows(
        pi: PiUsageClient.Totals?,
        openCode: OpenCodeUsageClient.Totals?,
        fx: FxUsageClient.Totals?,
        sarvam: SarvamCodeUsageClient.Totals?
    ) -> [LocalSpendRow] {
        var rows: [String: LocalSpendRow] = [:]
        func add(_ amount: Double, currency: String, keyPath: WritableKeyPath<LocalSpendRow, Double>) {
            var row = rows[currency] ?? LocalSpendRow(currencyCode: currency)
            row[keyPath: keyPath] += amount
            rows[currency] = row
        }
        func addUSD(costs: (Double, Double, Double, Double), tokens: (Double, Double, Double, Double)) {
            add(costs.0, currency: "USD", keyPath: \.today)
            add(costs.1, currency: "USD", keyPath: \.week)
            add(costs.2, currency: "USD", keyPath: \.month)
            add(costs.3, currency: "USD", keyPath: \.allTime)
            add(tokens.0, currency: "USD", keyPath: \.todayTokens)
            add(tokens.1, currency: "USD", keyPath: \.weekTokens)
            add(tokens.2, currency: "USD", keyPath: \.monthTokens)
            add(tokens.3, currency: "USD", keyPath: \.allTimeTokens)
        }

        if let pi {
            addUSD(
                costs: (pi.todayCost, pi.weekCost, pi.monthCost, pi.allTimeCost),
                tokens: (pi.todayTokens, pi.weekTokens, pi.monthTokens, pi.allTimeTokens)
            )
        }
        if let openCode {
            addUSD(
                costs: (openCode.todayCost, openCode.weekCost, openCode.monthCost, openCode.allTimeCost),
                tokens: (openCode.todayTokens, openCode.weekTokens, openCode.monthTokens, openCode.allTimeTokens)
            )
        }
        if let fx {
            addUSD(
                costs: (fx.todayCost, fx.weekCost, fx.monthCost, fx.allTimeCost),
                tokens: (fx.todayTokens, fx.weekTokens, fx.monthTokens, fx.allTimeTokens)
            )
        }
        if let sarvam {
            for money in sarvam.todayCosts.sortedMoney { add(money.amount, currency: money.currencyCode, keyPath: \.today) }
            for money in sarvam.weekCosts.sortedMoney { add(money.amount, currency: money.currencyCode, keyPath: \.week) }
            for money in sarvam.monthCosts.sortedMoney { add(money.amount, currency: money.currencyCode, keyPath: \.month) }
            for money in sarvam.allTimeCosts.sortedMoney { add(money.amount, currency: money.currencyCode, keyPath: \.allTime) }
            let base = dominantCurrency(sarvam.allTimeCosts) ?? "USD"
            add(Double(sarvam.todayTokens), currency: dominantCurrency(sarvam.todayCosts) ?? base, keyPath: \.todayTokens)
            add(Double(sarvam.weekTokens), currency: dominantCurrency(sarvam.weekCosts) ?? base, keyPath: \.weekTokens)
            add(Double(sarvam.monthTokens), currency: dominantCurrency(sarvam.monthCosts) ?? base, keyPath: \.monthTokens)
            add(Double(sarvam.allTimeTokens), currency: base, keyPath: \.allTimeTokens)
        }
        return rows.values.sorted { $0.currencyCode < $1.currencyCode }
    }

    nonisolated private static func dominantCurrency(_ totals: MoneyTotals) -> String? {
        totals.sortedMoney.max { $0.amount < $1.amount }?.currencyCode
    }
}

private struct PercentFormat: FormatStyle {
    typealias FormatInput = Double
    typealias FormatOutput = String

    func format(_ value: Double) -> String {
        "\(Int(value * 100))%"
    }
}
