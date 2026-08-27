import Charts
import SwiftUI

struct SpendAnalyticsPanel: View {
    @ObservedObject var store: UsageStore
    @State private var piTotals: PiUsageClient.Totals?
    @State private var openCodeTotals: OpenCodeUsageClient.Totals?
    @State private var sarvamCodeTotals: SarvamCodeUsageClient.Totals?
    @State private var fxTotals: FxUsageClient.Totals?
    @State private var isLoadingLocalTotals = true
    @State private var selectedRange: TimeRange = .day
    @State private var selectedAgentID: Int32?

    enum TimeRange: String, CaseIterable, Identifiable {
        case day = "24h"
        case week = "1w"
        case month = "1m"
        case all = "All"
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
            VStack(alignment: .leading, spacing: 14) {
                UsageHeatmap(store: store)
                Divider()
                spendSection
                Divider()
                quotaSection
            }
            .padding(2)
        }
        .frame(maxHeight: .infinity)
        .task { await loadPiTotals() }
    }

    // MARK: - Summary

    private var summarySection: some View {
        HStack(spacing: 4) {
            summaryBlock(value: "\(store.snapshots.filter { !$0.isAgentDetectionOnly && !$0.isError }.count)", label: "Tracked")
            if let oldest = store.history.min(by: { $0.timestamp < $1.timestamp })?.timestamp {
                let daysAgo = Calendar.current.dateComponents([.day], from: oldest, to: Date()).day ?? 0
                summaryBlock(value: "\(daysAgo)d ago", label: "Oldest data")
            }
            summaryBlock(value: "\(store.activeAgents.count)", label: "Active agents")
        }
    }

    private func summaryBlock(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .contentSurface()
    }

    // MARK: - Spend ($)

    private var spendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spend")
                .font(.system(size: 11, weight: .semibold))

            let costProviders = store.snapshots.filter { !$0.isError && $0.remainingRatio == nil && $0.menuBarValue != nil }
            if !costProviders.isEmpty {
                ForEach(costProviders) { snap in
                    HStack(spacing: 8) {
                        ProviderLogo(provider: snap.provider, size: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(snap.name)
                                .font(.system(size: 11, weight: .medium))
                            Text(snap.provider.displayName)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if let todayTokens = todayTokens(for: snap.provider), todayTokens > 0 {
                            Text("\(formatCompact(todayTokens)) tokens")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        if let bar = snap.menuBarValue {
                            Text(bar)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentSurface()
                }
            }

            if isLoadingLocalTotals && hasLocalCostProvider {
                HStack(spacing: 4) {
                    spendBlock(label: "Today", money: .usd(0), tokens: 0)
                    spendBlock(label: "Week", money: .usd(0), tokens: 0)
                    spendBlock(label: "Month", money: .usd(0), tokens: 0)
                    spendBlock(label: "All Time", money: .usd(0), tokens: 0)
                }
                .redacted(reason: .placeholder)
            } else {
                ForEach(localSpendRows, id: \.currencyCode) { row in
                    let tokens = row.allTimeTokens > 0
                    VStack(alignment: .leading, spacing: 4) {
                        if localSpendRows.count > 1 {
                            Text(row.currencyCode)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                        HStack(spacing: 4) {
                            spendBlock(label: "Today", money: Money(amount: row.today, currencyCode: row.currencyCode), tokens: tokens ? row.todayTokens : nil)
                            spendBlock(label: "Week", money: Money(amount: row.week, currencyCode: row.currencyCode), tokens: tokens ? row.weekTokens : nil)
                            spendBlock(label: "Month", money: Money(amount: row.month, currencyCode: row.currencyCode), tokens: tokens ? row.monthTokens : nil)
                            spendBlock(label: "All Time", money: Money(amount: row.allTime, currencyCode: row.currencyCode), tokens: tokens ? row.allTimeTokens : nil)
                        }
                    }
                }
            }

            let costAgents = store.activeAgents.filter { $0.sessionUsage?.cost != nil }
            if !costAgents.isEmpty {
                Text("Session Costs")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(sessionCostGroups(costAgents), id: \.currencyCode) { group in
                    sessionCostChart(agents: group.agents, currencyCode: group.currencyCode)
                }
            }

            if !isLoadingLocalTotals && costProviders.isEmpty && piTotals == nil && openCodeTotals == nil && sarvamCodeTotals == nil && fxTotals == nil && costAgents.isEmpty {
                emptyState(icon: "dollarsign.circle", text: "No spend data yet")
            }
        }
    }

    private func spendBlock(label: String, money: Money, tokens: Double?) -> some View {
        VStack(spacing: 4) {
            Text(formatMoney(money))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            if let tokens {
                Text("\(formatCompact(tokens)) tokens")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .contentSurface()
    }

    @ViewBuilder
    private func sessionCostChart(agents: [ActiveAgent], currencyCode: String) -> some View {
        let totalCost = agents.compactMap(\.sessionUsage?.cost).reduce(0, +)
        if sessionCostGroups(store.activeAgents).count > 1 {
            Text(currencyCode)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        Chart {
            ForEach(agents) { agent in
                if let cost = agent.sessionUsage?.cost {
                    SectorMark(
                        angle: .value("Cost", cost),
                        innerRadius: .ratio(0.62),
                        angularInset: 2
                    )
                    .foregroundStyle(by: .value("Agent", agent.title))
                    .opacity(selectedAgentID == nil || selectedAgentID == agent.id ? 1 : 0.3)
                }
            }
        }
        .chartLegend(.hidden)
        .frame(height: 110)
        .chartOverlay { _ in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            selectedAgentID = Self.agentID(at: location, in: geometry.size, agents: agents)
                        case .ended:
                            selectedAgentID = nil
                        }
                    }
            }
        }

        Group {
            if let selectedAgentID,
               let agent = agents.first(where: { $0.id == selectedAgentID }),
               let cost = agent.sessionUsage?.cost {
                HStack(spacing: 6) {
                    ProviderLogo(provider: agent.provider, size: 14)
                    Text(agent.title)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(formatMoney(Money(amount: cost, currencyCode: currencyCode)))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
            } else {
                HStack {
                    Text("Total")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text(formatMoney(Money(amount: totalCost, currencyCode: currencyCode)))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
            }
        }
        .frame(height: 14)
        .padding(.horizontal, 4)

        ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(agents) { agent in
                    HStack(spacing: 8) {
                        ProviderLogo(provider: agent.provider, size: 16)
                        Text(agent.title)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        if let usage = agent.sessionUsage, let cost = usage.cost {
                            Text(formatMoney(Money(amount: cost, currencyCode: usage.currencyCode)))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            Text("\(formatCompact(Double(usage.tokensInput + usage.tokensOutput))) tokens")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(8)
                    .contentSurface()
                    .onHover { isHovered in
                        selectedAgentID = isHovered ? agent.id : nil
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: 220)
    }

    private func sessionCostGroups(_ agents: [ActiveAgent]) -> [(currencyCode: String, agents: [ActiveAgent])] {
        let billed = agents.filter { $0.sessionUsage?.cost != nil }
        let grouped: [String: [ActiveAgent]] = Dictionary(grouping: billed) { agent in
            agent.sessionUsage?.currencyCode ?? "USD"
        }
        return grouped
            .map { key, value -> (currencyCode: String, agents: [ActiveAgent]) in
                (currencyCode: key, agents: value.sorted { cost(of: $0) > cost(of: $1) })
            }
            .sorted { $0.currencyCode < $1.currencyCode }
    }

    private func cost(of agent: ActiveAgent) -> Double {
        agent.sessionUsage?.cost ?? 0
    }

    // MARK: - Quota (%)

    /// Which slice sits under a point, or nil when the pointer is outside the ring.
    ///
    /// Extracted and made static so the geometry can be tested without a rendered chart.
    /// Returns nil inside the donut hole and outside the outer edge, so the empty middle does
    /// not select whichever slice happens to be nearest.
    ///
    /// nonisolated: pure geometry over values, with no view state. Without it the method
    /// inherits the View's MainActor isolation and cannot be called from a synchronous test -
    /// which builds locally but fails under CI's stricter concurrency checking.
    nonisolated static func agentID(at point: CGPoint, in size: CGSize, agents: [ActiveAgent]) -> Int32? {
        let costs = agents.compactMap { agent -> (id: Int32, cost: Double)? in
            guard let cost = agent.sessionUsage?.cost, cost > 0 else { return nil }
            return (agent.id, cost)
        }
        let total = costs.reduce(0) { $0 + $1.cost }
        guard total > 0 else { return nil }

        // The chart is centred in its frame; the legend occupies the lower portion, so the
        // ring is centred on the square that the plot area actually occupies.
        let outerRadius = min(size.width, size.height) / 2
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = (dx * dx + dy * dy).squareRoot()
        // innerRadius is .ratio(0.62) on the mark.
        guard distance >= outerRadius * 0.62, distance <= outerRadius else { return nil }

        // Clockwise from twelve o'clock. SwiftUI's y grows downward, hence -dy.
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        let fraction = angle / (2 * .pi)

        var cumulative = 0.0
        for entry in costs {
            cumulative += entry.cost / total
            if fraction <= cumulative { return entry.id }
        }
        return costs.last?.id
    }

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Quota")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Picker("", selection: $selectedRange) {
                    ForEach(TimeRange.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }

            // Quota-based account cards
            let quotaProviders = store.snapshots.filter { !$0.isError && $0.remainingRatio != nil }
            if !quotaProviders.isEmpty {
                ForEach(quotaProviders) { snap in
                    HStack(spacing: 8) {
                        ProviderLogo(provider: snap.provider, size: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(snap.name)
                                .font(.system(size: 11, weight: .medium))
                            Text(snap.provider.displayName)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if let ratio = snap.remainingRatio {
                            Text(ratio, format: PercentFormat())
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
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
                                    .font(.system(size: 9))
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
        switch selectedRange {
        case .day:
            return .dateTime.hour()
        case .week:
            return .dateTime.weekday(.abbreviated).day()
        case .month, .all:
            return .dateTime.month(.abbreviated).day()
        }
    }

    private var chartData: [QuotaPoint] {
        let cutoff = selectedRange.days.flatMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) }
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

    // MARK: - Shared

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func loadPiTotals() async {
        defer { isLoadingLocalTotals = false }
        if store.snapshots.contains(where: { $0.provider == .pi }) {
            piTotals = try? PiUsageClient.aggregate()
        }
        if store.snapshots.contains(where: { $0.provider == .openCode }) {
            openCodeTotals = try? OpenCodeUsageClient.aggregate()
        }
        if store.snapshots.contains(where: { $0.provider == .sarvamCode }) {
            sarvamCodeTotals = try? SarvamCodeUsageClient.aggregate()
        }
        if store.snapshots.contains(where: { $0.provider == .fx }) {
            fxTotals = try? FxUsageClient.aggregate()
        }
    }

    private var hasLocalCostProvider: Bool {
        store.snapshots.contains { $0.provider == .pi || $0.provider == .openCode || $0.provider == .sarvamCode || $0.provider == .fx }
    }

    private func todayTokens(for provider: Provider) -> Double? {
        switch provider {
        case .pi: return piTotals?.todayTokens
        case .openCode: return openCodeTotals?.todayTokens
        case .fx: return fxTotals?.todayTokens
        case .sarvamCode: return sarvamCodeTotals.map { Double($0.todayTokens) }
        default: return nil
        }
    }

    struct LocalSpendRow: Equatable {
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

    private var localSpendRows: [LocalSpendRow] {
        Self.spendRows(pi: piTotals, openCode: openCodeTotals, fx: fxTotals, sarvam: sarvamCodeTotals)
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
