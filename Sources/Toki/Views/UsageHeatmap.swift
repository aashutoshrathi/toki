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
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Color.primary.opacity(day.isPlaceholder ? 0 : 0.06), lineWidth: 1)
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
    private var ramp: [Color] {
        colorScheme == .dark
            ? [
                Color(red: 0.09, green: 0.20, blue: 0.33),
                Color(red: 0.12, green: 0.36, blue: 0.58),
                Color(red: 0.18, green: 0.50, blue: 0.93),
                Color(red: 0.50, green: 0.70, blue: 0.96),
            ]
            : [
                Color(red: 0.78, green: 0.87, blue: 0.97),
                Color(red: 0.56, green: 0.75, blue: 0.94),
                Color(red: 0.29, green: 0.56, blue: 0.89),
                Color(red: 0.11, green: 0.37, blue: 0.69),
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
    static func days(
        from history: [UsageHistoryEntry],
        provider: Provider?,
        dayCount: Int,
        now: Date
    ) -> [HeatmapDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let relevant = provider.map { wanted in history.filter { $0.provider == wanted } } ?? history

        var peakByDay: [Date: Double] = [:]
        for entry in relevant {
            guard let ratio = entry.remainingRatio else { continue }
            let day = calendar.startOfDay(for: entry.timestamp)
            let used = min(max(1 - ratio, 0), 1)
            peakByDay[day] = max(peakByDay[day] ?? 0, used)
        }

        return (0..<dayCount).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return HeatmapDay(date: date, intensity: peakByDay[date])
        }
    }
}

struct HeatmapDay: Identifiable {
    let id: String
    let date: Date
    let intensity: Double?
    let isPlaceholder: Bool

    init(date: Date, intensity: Double?) {
        self.id = ISO8601DateFormatter().string(from: date)
        self.date = date
        self.intensity = intensity
        self.isPlaceholder = false
    }

    private init(placeholderIndex: Int) {
        self.id = "placeholder-\(placeholderIndex)"
        self.date = .distantPast
        self.intensity = nil
        self.isPlaceholder = true
    }

    static func placeholder(index: Int) -> HeatmapDay {
        HeatmapDay(placeholderIndex: index)
    }

    var tooltip: String {
        guard !isPlaceholder else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let day = formatter.string(from: date)
        guard let intensity else { return "\(day): no usage recorded" }
        return "\(day): \(Int((intensity * 100).rounded()))% of quota used"
    }
}
