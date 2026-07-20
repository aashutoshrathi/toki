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
            if days.allSatisfy({ $0.intensity == nil }) {
                Text("No usage recorded in the last \(dayCount) days")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                grid
                legend
            }
        }
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
            .fill(color(for: day.intensity))
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

    // A single-hue sequential ramp, light to dark. Sequential data gets one hue - a
    // multi-hue/rainbow ramp implies categories where there is only magnitude.
    //
    // The dark-mode steps are chosen against the dark surface rather than derived by
    // inverting the light ones: on a dark background the ramp has to run dark-to-bright to
    // keep intensity reading as "more", and a flipped light ramp would put its most saturated
    // step at the wrong end.
    // Steps are spaced so that every adjacent pair clears ΔE 15 for normal vision and stays
    // above the CVD floor under protanopia, deuteranopia, and tritanopia - measured, not
    // eyeballed. An earlier, prettier ramp sat at ΔE 11 between its first two steps, which is
    // hard to separate even with full colour vision, and its lightest step was 1.34:1 against
    // the surface, effectively invisible.
    //
    // Light: #B4D3F1 #69A0E5 #2A5FB4 #0A2E5C (worst adjacent ΔE 17.0 normal / 15.9 CVD)
    // Dark:  #24466E #2E6FBF #57A0F5 #B3D6FD (worst adjacent ΔE 15.5 normal / 15.6 CVD)
    private var ramp: [Color] {
        colorScheme == .dark
            ? [
                Color(red: 0.141, green: 0.275, blue: 0.431),
                Color(red: 0.180, green: 0.435, blue: 0.749),
                Color(red: 0.341, green: 0.627, blue: 0.961),
                Color(red: 0.702, green: 0.839, blue: 0.992),
            ]
            : [
                Color(red: 0.706, green: 0.827, blue: 0.945),
                Color(red: 0.412, green: 0.627, blue: 0.898),
                Color(red: 0.165, green: 0.373, blue: 0.706),
                Color(red: 0.039, green: 0.180, blue: 0.361),
            ]
    }

    /// The no-data step, deliberately a neutral rather than a lighter tint of the ramp hue -
    /// "nothing recorded" is a different fact from "a very small amount".
    private var emptyColor: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.07)
    }

    private func color(for intensity: Double?) -> Color {
        guard let intensity else { return emptyColor }
        switch intensity {
        case ..<0.25: return ramp[0]
        case ..<0.50: return ramp[1]
        case ..<0.75: return ramp[2]
        default: return ramp[3]
        }
    }

    // MARK: - Data

    private var availableProviders: [Provider] {
        Array(Set(store.history.map(\.provider))).sorted { $0.displayName < $1.displayName }
    }

    private var days: [HeatmapDay] {
        UsageHeatmap.days(from: store.history, provider: provider, dayCount: dayCount, now: Date())
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
        from history: [UsageHistoryEntry],
        provider: Provider?,
        dayCount: Int,
        now: Date
    ) -> [HeatmapDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let relevant = provider.map { wanted in history.filter { $0.provider == wanted } } ?? history

        // Consumption is measured as how far the remaining quota FELL during the day, not from
        // the standing remaining figure.
        //
        // Using the standing figure conflates state with activity: an account sitting at 0%
        // remaining reports "100% used" every single day until its quota resets, so idle days
        // paint as fully saturated and the chart says nothing about when work happened. Summing
        // the drops between consecutive readings measures what was actually spent that day.
        // Increases are ignored - a rise in remaining quota is a reset, not negative usage.
        var byDay: [Date: [String: (consumed: Double, provider: Provider)]] = [:]
        var samplesByDay: [Date: Int] = [:]

        for (_, entries) in Dictionary(grouping: relevant, by: \.accountID) {
            var previous: Double?
            for entry in entries.sorted(by: { $0.timestamp < $1.timestamp }) {
                guard let ratio = entry.remainingRatio else { continue }
                let day = calendar.startOfDay(for: entry.timestamp)
                samplesByDay[day, default: 0] += 1
                defer { previous = ratio }
                guard let last = previous, last - ratio > 0 else { continue }
                let existing = byDay[day]?[entry.accountName]?.consumed ?? 0
                byDay[day, default: [:]][entry.accountName] = (min(existing + (last - ratio), 1), entry.provider)
            }
        }

        return (0..<dayCount).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let accounts = (byDay[date] ?? [:])
                .map { AccountUsage(name: $0.key, peak: $0.value.consumed, provider: $0.value.provider) }
                .sorted { $0.peak > $1.peak }
            return HeatmapDay(
                date: date,
                intensity: accounts.map(\.peak).max(),
                accounts: accounts,
                sampleCount: samplesByDay[date] ?? 0
            )
        }
    }
}

struct AccountUsage: Hashable {
    let name: String
    let peak: Double
    let provider: Provider
}

struct HeatmapDay: Identifiable {
    let id: String
    let date: Date
    let intensity: Double?
    let isPlaceholder: Bool
    /// Per-account peak consumption that day, heaviest first.
    let accounts: [AccountUsage]
    /// How many readings were recorded - a rough proxy for how active the day was.
    let sampleCount: Int

    init(date: Date, intensity: Double?, accounts: [AccountUsage] = [], sampleCount: Int = 0) {
        self.id = ISO8601DateFormatter().string(from: date)
        self.date = date
        self.intensity = intensity
        self.isPlaceholder = false
        self.accounts = accounts
        self.sampleCount = sampleCount
    }

    private init(placeholderIndex: Int) {
        self.id = "placeholder-\(placeholderIndex)"
        self.date = .distantPast
        self.intensity = nil
        self.isPlaceholder = true
        self.accounts = []
        self.sampleCount = 0
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
        guard let intensity else { return "\(day) - no usage recorded" }

        var lines = ["\(day) - \(percent(intensity)) of quota consumed"]
        for account in accounts.prefix(4) {
            lines.append("\(account.name): \(percent(account.peak))")
        }
        if accounts.count > 4 {
            lines.append("+\(accounts.count - 4) more")
        }
        if sampleCount > 0 {
            lines.append("\(sampleCount) reading\(sampleCount == 1 ? "" : "s")")
        }
        return lines.joined(separator: "\n")
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
