import Charts
import SwiftUI

struct SpendAnalyticsPanel: View {
    @ObservedObject var store: UsageStore
    @State private var piTotals: PiUsageClient.Totals?
    @State private var selectedRange: TimeRange = .week

    enum TimeRange: String, CaseIterable, Identifiable {
        case week = "7 Days"
        case month = "30 Days"
        case all = "All"
        var id: String { rawValue }
        var days: Int? {
            switch self {
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
                quotaSection
                Divider()
                providerSection
                Divider()
                agentSection
                Divider()
                piSection
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
            summaryBlock(value: "\(store.history.count)", label: "Data points")
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

    // MARK: - Quota History

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Quota History")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Picker("Range", selection: $selectedRange) {
                    ForEach(TimeRange.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            let points = chartData
            if points.isEmpty {
                emptyState(icon: "chart.line.flattrend.xyaxis", text: "Not enough history yet")
            } else {
                Chart {
                    ForEach(points) { point in
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Remaining", point.remainingRatio)
                        )
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
                .chartYScale(domain: 0...1)
                .chartLegend(position: .bottom, spacing: 8)
                .frame(height: 180)
            }
        }
    }

    private var chartData: [QuotaPoint] {
        let cutoff = selectedRange.days.flatMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) }
        return store.history
            .filter { entry in
                guard let cutoff else { return true }
                return entry.timestamp >= cutoff
            }
            .compactMap { entry -> QuotaPoint? in
                guard let ratio = entry.remainingRatio else { return nil }
                return QuotaPoint(
                    timestamp: entry.timestamp,
                    accountName: entry.accountName,
                    remainingRatio: ratio
                )
            }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private struct QuotaPoint: Identifiable {
        let id: String
        let timestamp: Date
        let accountName: String
        let remainingRatio: Double

        init(timestamp: Date, accountName: String, remainingRatio: Double) {
            self.id = "\(timestamp.timeIntervalSince1970)-\(accountName)"
            self.timestamp = timestamp
            self.accountName = accountName
            self.remainingRatio = remainingRatio
        }
    }

    // MARK: - Provider Breakdown

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accounts")
                .font(.system(size: 11, weight: .semibold))

            let tracked = store.snapshots.filter { !$0.isError }
            if tracked.isEmpty {
                emptyState(icon: "person.crop.circle", text: "No accounts connected")
            } else {
                Chart {
                    ForEach(tracked) { snap in
                        if let ratio = snap.remainingRatio {
                            BarMark(
                                x: .value("Account", snap.name),
                                y: .value("Remaining", ratio),
                                width: 20
                            )
                            .foregroundStyle(by: .value("Account", snap.name))
                        }
                    }
                }
                .chartXAxis(.hidden)
                .chartLegend(position: .bottom, spacing: 8)
                .chartYAxis {
                    AxisMarks(values: [0, 0.5, 1]) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: PercentFormat())
                    }
                }
                .chartYScale(domain: 0...1)
                .frame(height: 100)

                ForEach(tracked) { snap in
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
                        if snap.isAgentDetectionOnly {
                            Text("Agent only")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        } else if let ratio = snap.remainingRatio {
                            Text(ratio, format: PercentFormat())
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        } else if let bar = snap.menuBarValue {
                            Text(bar)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                    )
                }
            }
        }
    }

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Session Costs")
                .font(.system(size: 11, weight: .semibold))

            let costAgents = store.activeAgents.filter { $0.sessionUsage?.cost != nil }
            if costAgents.isEmpty {
                emptyState(icon: "dollarsign.circle", text: "No active agents with cost data")
            } else {
                Chart {
                    ForEach(costAgents) { agent in
                        if let cost = agent.sessionUsage?.cost {
                            BarMark(
                                x: .value("Agent", agent.title),
                                y: .value("Cost", cost)
                            )
                            .foregroundStyle(by: .value("Provider", agent.provider.displayName))
                        }
                    }
                }
                .chartXAxis(.hidden)
                .chartLegend(position: .bottom, spacing: 8)
                .frame(height: 100)

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
                }
            }
        }
    }

    // MARK: - Pi Spend

    private var piSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pi Spend")
                .font(.system(size: 11, weight: .semibold))

            if let totals = piTotals {
                Chart {
                    BarMark(x: .value("Period", "Today"), y: .value("Cost", totals.todayCost))
                        .foregroundStyle(by: .value("Period", "Today"))
                    BarMark(x: .value("Period", "Week"), y: .value("Cost", totals.weekCost))
                        .foregroundStyle(by: .value("Period", "Week"))
                    BarMark(x: .value("Period", "Month"), y: .value("Cost", totals.monthCost))
                        .foregroundStyle(by: .value("Period", "Month"))
                }
                .chartXAxis(.hidden)
                .chartLegend(position: .bottom, spacing: 8)
                .frame(height: 100)

                HStack(spacing: 4) {
                    piBlock(label: "Today", cost: totals.todayCost)
                    piBlock(label: "Week", cost: totals.weekCost)
                    piBlock(label: "Month", cost: totals.monthCost)
                    piBlock(label: "All Time", cost: totals.allTimeCost)
                }
            } else {
                emptyState(icon: "chart.bar", text: "Loading Pi data\u{2026}")
            }
        }
    }

    private func piBlock(label: String, cost: Double) -> some View {
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
        guard store.snapshots.contains(where: { $0.provider == .pi }) else { return }
        piTotals = try? PiUsageClient.aggregate()
    }
}

private struct PercentFormat: FormatStyle {
    typealias FormatInput = Double
    typealias FormatOutput = String

    func format(_ value: Double) -> String {
        "\(Int(value * 100))%"
    }
}
