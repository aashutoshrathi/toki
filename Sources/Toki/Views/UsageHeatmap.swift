import SwiftUI

// Calendar layout (weekday columns, week rows) rather than GitHub's transposed form: at 30
// days the transposed version is only ~5 columns, too narrow to read in a popover.
struct UsageHeatmap: View {
    @ObservedObject var store: UsageStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @ObservedObject var presentation: AnalyticsPresentationState
    @State private var isPulsing = false
    @State private var hoveredDayID: String?

    // Capped at retention: rendering days already pruned would show them as "no usage".
    private var dayCount: Int {
        min(30, max(store.preferences.historyRetentionDays, 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Text(dateRange)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            // Without this the empty grid renders first, which reads as "no activity".
            if store.isScanningActivity, store.dailyActivity.isEmpty {
                loadingGrid
            } else if days.allSatisfy({ $0.level == nil }) {
                // A read failure is not an absence of work - say which one this is.
                Text(unreadableProviders.isEmpty
                     ? "No agent activity found in the last \(dayCount) days"
                     : unreadableNotice)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                // A grid drawn from some of the providers looks exactly like one drawn from all
                // of them, so a partial failure has to say so above the data it is missing from.
                if !unreadableProviders.isEmpty {
                    Text(unreadableNotice)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                grid
                legend
            }
        }
        .task { store.refreshDailyActivity() }
    }

    private var unreadableNotice: String {
        let names = unreadableProviders.map(\.displayName).joined(separator: ", ")
        return "Couldn't read session history for \(names)"
    }

    private var header: some View {
        HStack {
            Text("Daily activity")
                .font(.system(size: 11, weight: .semibold))
            Spacer()
            Menu {
                Button("All providers") { presentation.provider = nil }
                ForEach(availableProviders, id: \.self) { candidate in
                    Button(candidate.displayName) { presentation.provider = candidate }
                }
            } label: {
                Text(presentation.provider?.displayName ?? "All providers")
                    .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .frame(minHeight: 28)
            .accessibilityLabel("Activity provider")
        }
    }

    // Skeleton rather than a spinner, so the panel doesn't jump when data lands.
    private var loadingGrid: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Reading session history…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            }
            .padding(.bottom, 2)

            ForEach(0..<5, id: \.self) { _ in
                HStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(emptyColor)
                            .frame(height: 28)
                            .frame(maxWidth: .infinity)
                    }
                }
            }

            Color.clear
                .frame(height: 26)
        }
        .opacity(accessibilityReduceMotion ? 1 : (isPulsing ? 0.55 : 1))
        .animation(
            accessibilityReduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
            value: isPulsing
        )
        .onAppear { isPulsing = !accessibilityReduceMotion }
        .accessibilityLabel("Loading daily usage")
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                ForEach(weekdaySymbols.indices, id: \.self) { index in
                    Text(weekdaySymbols[index])
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(weeks.indices, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(weeks[row]) { day in
                        cell(for: day)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(for day: HeatmapDay) -> some View {
        if day.isPlaceholder {
            Color.clear.frame(height: 28).frame(maxWidth: .infinity)
                .accessibilityHidden(true)
        } else {
            Button {
                presentation.pinnedDayID = presentation.pinnedDayID == day.id ? nil : day.id
            } label: {
                Text(day.date, format: .dateTime.day())
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    // These crossings maximize text contrast on the light and dark blue ramps.
                    .foregroundStyle(day.level.map { $0 >= (colorScheme == .dark ? 55 : 46) ? Color.white : Color.black } ?? Color.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .background(color(for: day.level), in: RoundedRectangle(cornerRadius: 4))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.primary.opacity((hoveredDayID ?? presentation.pinnedDayID) == day.id ? 0.85 : 0.18),
                                    lineWidth: (hoveredDayID ?? presentation.pinnedDayID) == day.id ? 2 : 1)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isInside in
                if isInside { hoveredDayID = day.id }
                else if hoveredDayID == day.id { hoveredDayID = nil }
            }
            .accessibilityLabel(day.tooltip)
            .accessibilityValue(presentation.pinnedDayID == day.id ? "Pinned" : "")
            .accessibilityHint("Activate to pin or unpin daily details")
        }
    }

    private var detailDay: HeatmapDay? {
        guard let id = hoveredDayID ?? presentation.pinnedDayID else { return nil }
        return days.first { $0.id == id }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let day = detailDay {
                Text("\(day.headline) · \(day.figures)")
                    .font(.system(size: 11, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                if !day.breakdown.isEmpty {
                    Text(day.breakdown)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 6) {
                    Text("Select a day for details")
                    Spacer()
                    Text("Less")
                    LinearGradient(
                        colors: (0..<Self.shadeCount).map { shade(at: Double($0) / Double(Self.shadeCount - 1)) },
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: 48, height: 8)
                    .clipShape(Capsule())
                    Text("More")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Colour

    /// Adjacent shades are deliberately not separately identifiable; exact figures live in the
    /// hover line. The measured separation holds between the four anchors.
    nonisolated static let shadeCount = 64

    // Measured anchors, spaced so adjacent pairs clear the normal-vision separation floor.
    // Listed in array order, palest first.
    //   light #CFE6FB #79B4EF #3480CF #0E4E93
    //   dark  #EAF5FF #95C9FA #4B9AEA #1A5FA8
    private var anchors: [(r: Double, g: Double, b: Double)] {
        colorScheme == .dark
            ? [
                (0.918, 0.961, 1.000),
                (0.584, 0.788, 0.980),
                (0.294, 0.604, 0.918),
                (0.102, 0.373, 0.659),
            ]
            : [
                (0.812, 0.902, 0.984),
                (0.475, 0.706, 0.937),
                (0.204, 0.502, 0.812),
                (0.055, 0.306, 0.576),
            ]
    }

    /// Colour at `fraction` (0...1) along the ramp, interpolated between the surrounding anchors.
    private func shade(at fraction: Double) -> Color {
        let stops = anchors
        let clamped = min(max(fraction, 0), 1)
        let scaled = clamped * Double(stops.count - 1)
        let lower = min(Int(scaled), stops.count - 2)
        let t = scaled - Double(lower)
        let from = stops[lower]
        let to = stops[lower + 1]
        return Color(
            red: from.r + (to.r - from.r) * t,
            green: from.g + (to.g - from.g) * t,
            blue: from.b + (to.b - from.b) * t
        )
    }

    /// Neutral, not a tint of the ramp: "no data" is not "a very small amount". Kept fainter
    /// than the deepest step in dark mode, or a busy day reads as no heavier than an idle one.
    private var emptyColor: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.07)
    }

    private func color(for level: Int?) -> Color {
        guard let level else { return emptyColor }
        return shade(at: Double(level) / Double(Self.shadeCount - 1))
    }

    // MARK: - Data

    private var availableProviders: [Provider] {
        Array(Set(store.dailyActivity.map(\.provider)).union(store.unreadableActivityProviders)).sorted { $0.displayName < $1.displayName }
    }

    private var unreadableProviders: [Provider] {
        store.unreadableActivityProviders.filter { presentation.provider == nil || $0 == presentation.provider }
    }

    private var dateRange: String {
        guard let first = days.first, let last = days.last else { return "" }
        let format = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        return "\(first.date.formatted(format)) – \(last.date.formatted(format))"
    }

    private var days: [HeatmapDay] {
        UsageHeatmap.days(from: store.dailyActivity, provider: presentation.provider, dayCount: dayCount, now: Date())
    }

    // Padded to whole weeks; placeholders render blank, not as zero-usage days.
    private var weeks: [[HeatmapDay]] {
        let calendar = Calendar.current
        let padding = calendar.component(.weekday, from: days.first?.date ?? Date()) - 1
        let padded = (0..<padding).map { HeatmapDay.placeholder(index: $0) } + days
        return stride(from: 0, to: padded.count, by: 7).map {
            var week = Array(padded[$0..<min($0 + 7, padded.count)])
            while week.count < 7 { week.append(.placeholder(index: -week.count - 1)) }
            return week
        }
    }

    private var weekdaySymbols: [String] {
        let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
        return symbols.isEmpty ? ["S", "M", "T", "W", "T", "F", "S"] : symbols
    }

    // Extracted for testing.
    // nonisolated: pure computation, and must stay callable from tests.
    nonisolated static func days(
        from activity: [DailyActivity],
        provider: Provider?,
        dayCount: Int,
        now: Date
    ) -> [HeatmapDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let relevant = provider.map { wanted in activity.filter { $0.provider == wanted } } ?? activity

        var byDay: [Date: [DailyActivity]] = [:]
        for entry in relevant {
            byDay[calendar.startOfDay(for: entry.day), default: []].append(entry)
        }

        // Ranked, not scaled: daily totals are skewed enough that one long session flattens
        // every other day onto the lowest shade. A shade means "busy relative to your other
        // days", which is why the hover line carries absolute figures.
        let distinct = Set(byDay.values.map { day in day.reduce(0) { $0 + $1.tokens } }).sorted()

        return (0..<dayCount).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            guard let entries = byDay[date], !entries.isEmpty else {
                return HeatmapDay(date: date, level: nil, accounts: [], tokens: 0, costs: MoneyTotals())
            }
            let tokens = entries.reduce(0) { $0 + $1.tokens }
            var costs = MoneyTotals()
            for entry in entries { costs.add(entry.costs) }
            let accounts = entries
                .sorted { $0.tokens > $1.tokens }
                .map { AccountUsage(name: $0.provider.displayName, tokens: $0.tokens, costs: $0.costs) }
            return HeatmapDay(
                date: date,
                level: rankLevel(tokens: tokens, among: distinct),
                accounts: accounts,
                tokens: tokens,
                costs: costs
            )
        }
    }

    /// Rank among distinct active-day totals, mapped onto the ramp.
    nonisolated static func rankLevel(tokens: Int, among distinct: [Int]) -> Int {
        ActivityRank.level(tokens, among: distinct, steps: shadeCount)
    }
}

struct AccountUsage: Hashable {
    let name: String
    let tokens: Int
    let costs: MoneyTotals

    init(name: String, tokens: Int, cost: Double, currencyCode: String = "USD") {
        self.name = name
        self.tokens = tokens
        var totals = MoneyTotals()
        totals.add(Money(amount: cost, currencyCode: currencyCode))
        costs = totals
    }

    init(name: String, tokens: Int, costs: MoneyTotals) {
        self.name = name
        self.tokens = tokens
        self.costs = costs
    }
}

struct HeatmapDay: Identifiable {
    let id: String
    let date: Date
    let level: Int?
    let isPlaceholder: Bool
    /// Per-provider breakdown for the day, heaviest first.
    let accounts: [AccountUsage]
    let tokens: Int
    let costs: MoneyTotals

    init(date: Date, level: Int?, accounts: [AccountUsage] = [], tokens: Int = 0, cost: Double = 0) {
        self.id = ISO8601DateFormatter().string(from: date)
        self.date = date
        self.level = level
        self.isPlaceholder = false
        self.accounts = accounts
        self.tokens = tokens
        var totals = MoneyTotals()
        totals.add(.usd(cost))
        self.costs = totals
    }

    init(date: Date, level: Int?, accounts: [AccountUsage] = [], tokens: Int = 0, costs: MoneyTotals) {
        self.id = ISO8601DateFormatter().string(from: date)
        self.date = date
        self.level = level
        self.isPlaceholder = false
        self.accounts = accounts
        self.tokens = tokens
        self.costs = costs
    }

    private init(placeholderIndex: Int) {
        self.id = "placeholder-\(placeholderIndex)"
        self.date = .distantPast
        self.level = nil
        self.isPlaceholder = true
        self.accounts = []
        self.tokens = 0
        self.costs = MoneyTotals()
    }

    static func placeholder(index: Int) -> HeatmapDay {
        HeatmapDay(placeholderIndex: index)
    }

    /// e.g. "Mon, Jul 20"
    var headline: String {
        guard !isPlaceholder else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: date)
    }

    /// Absolute totals; the colour already carries the relative standing.
    var figures: String {
        guard level != nil else { return "No usage" }
        var text = "\(formatCompact(Double(tokens))) tokens"
        if !costs.isEmpty { text += "  \(costs.formatted)" }
        return text
    }

    /// Per-provider split, heaviest first.
    var breakdown: String {
        guard accounts.count > 1 || (accounts.count == 1 && level != nil) else { return "" }
        return accounts.prefix(4).map { account in
            var text = "\(account.name) \(formatCompact(Double(account.tokens)))"
            if !account.costs.isEmpty { text += " (\(account.costs.formatted))" }
            return text
        }.joined(separator: "  ·  ")
    }

    // Absolute tokens and cost, split per provider.
    var tooltip: String {
        guard !isPlaceholder else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        let day = formatter.string(from: date)
        guard level != nil else { return "\(day) - no activity" }

        // Absolute figures, not the relative shade: the colour already conveys "compared to
        // your other days", so repeating it as a percentage would say nothing new, and a
        // relative percentage is easily misread as a share of some quota.
        var lines = ["\(day) - \(formatCompact(Double(tokens))) tokens"]
        if !costs.isEmpty {
            lines[0] += " · \(costs.formatted)"
        }
        for account in accounts.prefix(4) {
            var line = "\(account.name): \(formatCompact(Double(account.tokens)))"
            if !account.costs.isEmpty { line += " · \(account.costs.formatted)" }
            lines.append(line)
        }
        if accounts.count > 4 {
            lines.append("+\(accounts.count - 4) more")
        }
        return lines.joined(separator: "\n")
    }
}
