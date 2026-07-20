import Charts
import SwiftUI

struct SpendAnalyticsPanel: View {
    @ObservedObject var store: UsageStore
    @State private var piTotals: PiUsageClient.Totals?
    @State private var openCodeTotals: OpenCodeUsageClient.Totals?
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
                summarySection
                UsageHeatmap(store: store)
                Divider()
                spendSection
                Divider()
                quotaSection
            }
            .padding(2)
        }
        .frame(maxHeight: accountListHeight())
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    // MARK: - Spend ($)

    private var spendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spend")
                .font(.system(size: 11, weight: .semibold))

            // Cost-based provider cards (Pi, OpenCode)
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
                        if let bar = snap.menuBarValue {
                            Text(bar)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                    )
                }
            }

            // Combined spend breakdown across all cost providers
            let today = (piTotals?.todayCost ?? 0) + (openCodeTotals?.todayCost ?? 0)
            let week = (piTotals?.weekCost ?? 0) + (openCodeTotals?.weekCost ?? 0)
            let month = (piTotals?.monthCost ?? 0) + (openCodeTotals?.monthCost ?? 0)
            let allTime = (piTotals?.allTimeCost ?? 0) + (openCodeTotals?.allTimeCost ?? 0)
            if piTotals != nil || openCodeTotals != nil {
                HStack(spacing: 4) {
                    spendBlock(label: "Today", cost: today)
                    spendBlock(label: "Week", cost: week)
                    spendBlock(label: "Month", cost: month)
                    spendBlock(label: "All Time", cost: allTime)
                }
            }

            // Session costs donut
            let costAgents = store.activeAgents.filter { $0.sessionUsage?.cost != nil }
            if !costAgents.isEmpty {
                let totalCost = costAgents.compactMap(\.sessionUsage?.cost).reduce(0, +)

                Text("Session Costs")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                Chart {
                    ForEach(costAgents) { agent in
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
                .chartLegend(position: .bottom, spacing: 8)
                .frame(height: 160)

                // Hover detail / total line
                if let selID = selectedAgentID,
                   let agent = costAgents.first(where: { $0.id == selID }),
                   let cost = agent.sessionUsage?.cost {
                    HStack(spacing: 6) {
                        ProviderLogo(provider: agent.provider, size: 14)
                        Text(agent.title)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(cost, format: .currency(code: "USD").precision(.fractionLength(2)))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 4)
                    .transition(.opacity)
                } else {
                    HStack {
                        Text("Total")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text(totalCost, format: .currency(code: "USD").precision(.fractionLength(2)))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 4)
                }

                ForEach(costAgents) { agent in
                    HStack(spacing: 8) {
                        ProviderLogo(provider: agent.provider, size: 16)
                        Text(agent.title)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        if let cost = agent.sessionUsage?.cost {
                            Text(cost, format: .currency(code: "USD").precision(.fractionLength(2)))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        }
                        if let usage = agent.sessionUsage {
                            Text("\(formatCompact(Double(usage.tokensInput + usage.tokensOutput))) tokens")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                    )
                    .onHover { isHovered in
                        selectedAgentID = isHovered ? agent.id : nil
                    }
                }
            }

            if costProviders.isEmpty && piTotals == nil && openCodeTotals == nil && costAgents.isEmpty {
                emptyState(icon: "dollarsign.circle", text: "No spend data yet")
            }
        }
    }

    private func spendBlock(label: String, cost: Double) -> some View {
        VStack(spacing: 4) {
            Text(cost, format: .currency(code: "USD").precision(.fractionLength(2)))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    // MARK: - Quota (%)

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
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                    )
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
                        .foregroundStyle(by: .value("Account", point.accountID))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
                .chartYAxis {
                    AxisMarks(values: [0, 0.25, 0.5, 0.75, 1]) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: PercentFormat())
                    }
                }
                .chartYScale(domain: 0...1)
                .chartLegend(position: .bottom, spacing: 8)
                .frame(height: 180)
            }
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
        if store.snapshots.contains(where: { $0.provider == .pi }) {
            piTotals = try? PiUsageClient.aggregate()
        }
        if store.snapshots.contains(where: { $0.provider == .openCode }) {
            openCodeTotals = try? OpenCodeUsageClient.aggregate()
        }
    }
}

private struct PercentFormat: FormatStyle {
    typealias FormatInput = Double
    typealias FormatOutput = String

    func format(_ value: Double) -> String {
        "\(Int(value * 100))%"
    }
}
