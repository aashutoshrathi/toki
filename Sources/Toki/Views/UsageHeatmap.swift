import SwiftUI

// A calendar heatmap of daily quota consumption, GitHub-contribution style.
//
// Laid out as a calendar (weekday columns, week rows) rather than GitHub's transposed
// weekday-rows form: capped at 30 days this is only ~5 week-columns, which reads as a narrow
// strip in a popover, whereas the calendar form fills the available width and is easier to
// locate a specific day in.
struct UsageHeatmap: View {
    @ObservedObject var store: UsageStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var provider: Provider?

    // The window is the retention window, capped at 30 days. Rendering a full 30 when the
    // user retains fewer would show pruned days as empty cells - indistinguishable from days
    // with genuinely no usage, which is a different fact.
    private var dayCount: Int {
        min(30, max(store.preferences.historyRetentionDays, 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if days.allSatisfy({ $0.level == nil }) {
                Text("No agent activity found in the last \(dayCount) days")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
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
            // The palest steps fall below 3:1 against the surface, which obliges visible
            // relief rather than relying on the fill alone. A defined border keeps every cell
            // legible as a cell - and keeps the grid readable under forced-colors/high-contrast
            // modes, where the fills may be overridden entirely.
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Color.primary.opacity(day.isPlaceholder ? 0 : 0.18), lineWidth: 1)
            )
            .opacity(day.isPlaceholder ? 0 : 1)
            // Identity is never color-alone: the exact figure is available on hover and to
            // VoiceOver, so the ramp only has to convey rough magnitude.
            .help(day.tooltip)
            .accessibilityLabel(day.tooltip)
    }

    private var legend: some View {
        HStack(spacing: 3) {
            Spacer()
            Text("Less")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            ForEach(0..<ramp.count, id: \.self) { step in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(ramp[step])
                    .frame(width: 10, height: 10)
            }
            Text("More")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Colour

    // A single-hue sequential ramp. Sequential data gets one hue - a multi-hue/rainbow ramp
    // implies categories where there is only magnitude. The dark-mode steps are chosen against
    // the dark surface rather than derived by inverting the light ones: on a dark background
    // the ramp has to run dark-to-bright for intensity to read as "more".
    //
    // Green rather than blue, for two reasons beyond taste. The blue ramp's darkest step sat
    // close enough to the neutral empty cell to be mistaken for it, and blue is already the
    // app's accent - the tab count badge is blue - so an activity grid in the same hue read as
    // if it were part of the same signal.
    //
    // Both ramps are measured, not copied. GitHub's own contribution greens fail the
    // normal-vision separation floor (deltaE 13.0 dark, 10.2 light, against a floor of 15), so
    // these are re-spaced versions rather than the originals.
    //
    // Light: #B7E9BF #52C878 #1F8A4C #0B4A26 (worst adjacent deltaE 16.3 normal / 13.1 CVD)
    // Dark:  #0A4526 #0F8A50 #35D073 #B6F5CE (worst adjacent deltaE 18.8 normal / 15.3 CVD)
    private var ramp: [Color] {
        colorScheme == .dark
            ? [
                Color(red: 0.039, green: 0.271, blue: 0.149),
                Color(red: 0.059, green: 0.541, blue: 0.314),
                Color(red: 0.208, green: 0.816, blue: 0.451),
                Color(red: 0.714, green: 0.961, blue: 0.808),
            ]
            : [
                Color(red: 0.718, green: 0.914, blue: 0.749),
                Color(red: 0.322, green: 0.784, blue: 0.471),
                Color(red: 0.122, green: 0.541, blue: 0.298),
                Color(red: 0.043, green: 0.290, blue: 0.149),
            ]
    }

    /// The no-data step, deliberately a neutral rather than a lighter tint of the ramp hue -
    /// "nothing recorded" is a different fact from "a very small amount".
    private var emptyColor: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.07)
    }

    private func color(for level: Int?) -> Color {
        guard let level else { return emptyColor }
        return ramp[min(max(level, 0), ramp.count - 1)]
    }

    // MARK: - Data

    private var availableProviders: [Provider] {
        Array(Set(store.dailyActivity.map(\.provider))).sorted { $0.displayName < $1.displayName }
    }

    private var days: [HeatmapDay] {
        UsageHeatmap.days(from: store.dailyActivity, provider: provider, dayCount: dayCount, now: Date())
    }

    // Padded to whole weeks so the calendar rows line up under the weekday headers. Leading
    // placeholders render as blanks, not as zero-usage days.
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

    // Extracted for testing. Intensity is the peak share of quota consumed that day - the
    // deepest the account got into its allowance - which is the figure a user recognises as
    // "how heavy was that day", and is derivable from the remaining-ratio samples on hand.
    // nonisolated: this is pure computation over values with no view state, and marking it so
    // keeps it callable from tests and background contexts. Without it the method inherits the
    // View's MainActor isolation, which builds locally but fails under CI's stricter checking.
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

        // Shading is by RANK among active days, not by share of the busiest day.
        //
        // Daily token counts are heavily skewed - one long session can be an order of magnitude
        // above a normal day. Scaling linearly against the maximum then crushes every other day
        // into the lowest step: the grid renders as one bright cell in a field of near-empty
        // ones and conveys nothing about the pattern of work. Ranking active days across the
        // ramp guarantees the whole scale is used and the relative shape stays readable.
        //
        // The trade-off is that a shade means "busy compared to your other days", not an
        // absolute amount - which is why the tooltip carries the real token and cost figures.
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

    /// Maps a day onto 0...3 by its rank among the distinct active-day totals, so the quietest
    /// active day is always the lowest step and the busiest always the highest.
    nonisolated static func rankLevel(tokens: Int, among distinct: [Int]) -> Int {
        // A single active day is by definition the busiest one; showing it at the lowest step
        // would read as "barely anything happened".
        guard distinct.count > 1, let index = distinct.firstIndex(of: tokens) else { return 3 }
        return index * 3 / (distinct.count - 1)
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

    // Breaks the day down rather than repeating the single number the colour already encodes:
    // which accounts were busy and how deep each got, plus how many readings landed that day.
    // Deliberately limited to what history actually records - it stores quota ratios, not token
    // or cost figures, so those are not claimed here.
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
