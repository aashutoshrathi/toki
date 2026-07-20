import SwiftUI

// Calendar layout (weekday columns, week rows) rather than GitHub's transposed form: at 30
// days the transposed version is only ~5 columns, too narrow to read in a popover.
struct UsageHeatmap: View {
    @ObservedObject var store: UsageStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var provider: Provider?
    @State private var isPulsing = false
    @State private var hoveredDay: HeatmapDay?

    // Capped at retention: rendering days already pruned would show them as "no usage".
    private var dayCount: Int {
        min(30, max(store.preferences.historyRetentionDays, 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            // Without this the empty grid renders first, which reads as "no activity".
            if store.isScanningActivity, store.dailyActivity.isEmpty {
                loadingGrid
            } else if days.allSatisfy({ $0.level == nil }) {
                // A read failure is not an absence of work - say which one this is.
                let unreadable = store.unreadableActivityProviders
                Text(unreadable.isEmpty
                     ? "No agent activity found in the last \(dayCount) days"
                     : "Couldn't read session history for \(unreadable.map(\.displayName).joined(separator: ", "))")
                    .font(.system(size: 10))
                    .foregroundStyle(unreadable.isEmpty ? .tertiary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                grid
                legend
            }
        }
        .task { store.refreshDailyActivity() }
    }

    private var header: some View {
        HStack {
            Text("Daily usage")
                .font(.system(size: 11, weight: .semibold))
            Spacer()
            Menu {
                Button("All providers") { provider = nil }
                ForEach(availableProviders, id: \.self) { candidate in
                    Button(candidate.displayName) { provider = candidate }
                }
            } label: {
                Text(provider?.displayName ?? "All providers")
                    .font(.system(size: 10, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // Skeleton rather than a spinner, so the panel doesn't jump when data lands.
    private var loadingGrid: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Reading session history…")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
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
                            .frame(height: 18)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .opacity(isPulsing ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isPulsing)
        .onAppear { isPulsing = true }
        .accessibilityLabel("Loading daily usage")
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.tertiary)
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
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(color(for: day.level))
            .frame(height: 18)
            .frame(maxWidth: .infinity)
            // The palest steps fall under 3:1 against the surface, so the fill alone is not
            // enough to delimit a cell - and forced-colors modes may drop the fill entirely.
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(
                        // Ringed so the detail line below has a visible anchor.
                        hoveredDay?.id == day.id
                            ? Color.primary.opacity(0.85)
                            : Color.primary.opacity(day.isPlaceholder ? 0 : 0.18),
                        lineWidth: hoveredDay?.id == day.id ? 1.5 : 1
                    )
            )
            .opacity(day.isPlaceholder ? 0 : 1)
            // Not .help(): system tooltips are delayed and frequently never appear inside a
            // popover. Figures go to the detail line below instead.
            .onHover { isInside in
                guard !day.isPlaceholder else { return }
                if isInside {
                    hoveredDay = day
                } else if hoveredDay?.id == day.id {
                    hoveredDay = nil
                }
            }
            // Not colour-alone: VoiceOver gets the same figures.
            .accessibilityLabel(day.tooltip)
    }

    // Fixed height, shared with the legend, so the panel doesn't resize on hover.
    private var legend: some View {
        ZStack {
            if let day = hoveredDay {
                hoverDetail(for: day)
            } else {
                HStack(spacing: 5) {
                    Spacer()
                    Text("Less")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                    // A bar, not swatches: 64 chips would be illegible.
                    LinearGradient(
                        colors: (0..<Self.shadeCount).map { shade(at: Double($0) / Double(Self.shadeCount - 1)) },
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 72, height: 8)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.18), lineWidth: 0.5))
                    Text("More")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(height: 26, alignment: .center)
    }

    private func hoverDetail(for day: HeatmapDay) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text(day.headline)
                    .font(.system(size: 10, weight: .semibold))
                // Shown for quiet days too - a bare date reads as a failed load.
                Text(day.figures)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(day.level == nil ? .tertiary : .secondary)
                Spacer()
            }
            if !day.breakdown.isEmpty {
                Text(day.breakdown)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        Array(Set(store.dailyActivity.map(\.provider))).sorted { $0.displayName < $1.displayName }
    }

    private var days: [HeatmapDay] {
        UsageHeatmap.days(from: store.dailyActivity, provider: provider, dayCount: dayCount, now: Date())
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
                return HeatmapDay(date: date, level: nil, accounts: [], tokens: 0, cost: 0)
            }
            let tokens = entries.reduce(0) { $0 + $1.tokens }
            let cost = entries.reduce(0) { $0 + $1.cost }
            let accounts = entries
                .sorted { $0.tokens > $1.tokens }
                .map { AccountUsage(name: $0.provider.displayName, tokens: $0.tokens, cost: $0.cost) }
            return HeatmapDay(
                date: date,
                level: rankLevel(tokens: tokens, among: distinct),
                accounts: accounts,
                tokens: tokens,
                cost: cost
            )
        }
    }

    /// Rank among distinct active-day totals, mapped onto the ramp.
    nonisolated static func rankLevel(tokens: Int, among distinct: [Int]) -> Int {
        let top = shadeCount - 1
        // A single active day is by definition the busiest one; showing it at the lowest shade
        // would read as "barely anything happened".
        guard distinct.count > 1, let index = distinct.firstIndex(of: tokens) else { return top }
        return index * top / (distinct.count - 1)
    }
}

struct AccountUsage: Hashable {
    let name: String
    let tokens: Int
    let cost: Double
}

struct HeatmapDay: Identifiable {
    let id: String
    let date: Date
    let level: Int?
    let isPlaceholder: Bool
    /// Per-provider breakdown for the day, heaviest first.
    let accounts: [AccountUsage]
    let tokens: Int
    let cost: Double

    init(date: Date, level: Int?, accounts: [AccountUsage] = [], tokens: Int = 0, cost: Double = 0) {
        self.id = ISO8601DateFormatter().string(from: date)
        self.date = date
        self.level = level
        self.isPlaceholder = false
        self.accounts = accounts
        self.tokens = tokens
        self.cost = cost
    }

    private init(placeholderIndex: Int) {
        self.id = "placeholder-\(placeholderIndex)"
        self.date = .distantPast
        self.level = nil
        self.isPlaceholder = true
        self.accounts = []
        self.tokens = 0
        self.cost = 0
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
        if cost > 0 { text += "  \(formatUSD(cost))" }
        return text
    }

    /// Per-provider split, heaviest first.
    var breakdown: String {
        guard accounts.count > 1 || (accounts.count == 1 && level != nil) else { return "" }
        return accounts.prefix(4).map { account in
            var text = "\(account.name) \(formatCompact(Double(account.tokens)))"
            if account.cost > 0 { text += " (\(formatUSD(account.cost)))" }
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
        if cost > 0 {
            lines[0] += " · \(formatUSD(cost))"
        }
        for account in accounts.prefix(4) {
            var line = "\(account.name): \(formatCompact(Double(account.tokens)))"
            if account.cost > 0 { line += " · \(formatUSD(account.cost))" }
            lines.append(line)
        }
        if accounts.count > 4 {
            lines.append("+\(accounts.count - 4) more")
        }
        return lines.joined(separator: "\n")
    }
}
