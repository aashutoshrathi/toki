import AppKit
import SwiftUI
import TokiWidgetShared
import WidgetKit

private struct TokiTimelineEntry: TimelineEntry {
    let date: Date
    let data: WidgetDataSnapshot?
}

private struct TokiTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> TokiTimelineEntry {
        TokiTimelineEntry(date: Date(), data: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (TokiTimelineEntry) -> Void) {
        completion(TokiTimelineEntry(date: Date(), data: context.isPreview ? .placeholder : loadSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TokiTimelineEntry>) -> Void) {
        let now = Date()
        let data = loadSnapshot()
        let entry = TokiTimelineEntry(date: now, data: data)
        let regularRefresh = now.addingTimeInterval(15 * 60)
        let staleRefresh = data?.updatedAt.addingTimeInterval(tokiWidgetStaleAfter) ?? regularRefresh
        // Never ask WidgetKit to refresh in the past, but do schedule a re-render for when a
        // snapshot is about to cross the stale boundary and fall back to the empty state.
        let nextRefresh = max(now.addingTimeInterval(60), min(regularRefresh, staleRefresh))
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func loadSnapshot() -> WidgetDataSnapshot? {
        let dataURL: URL?
        if tokiUsesLocalWidgetData() {
            dataURL = tokiLocalWidgetDataURL()
        } else {
            dataURL = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: tokiAppGroupIdentifier)?
                .appendingPathComponent(tokiWidgetDataFilename)
        }
        for url in [dataURL].compactMap({ $0 }) {
            guard let data = try? Data(contentsOf: url) else { continue }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let snapshot = try? decoder.decode(WidgetDataSnapshot.self, from: data) {
                return snapshot
            }
        }
        return nil
    }
}

private extension WidgetDataSnapshot {
    static var placeholder: WidgetDataSnapshot {
        WidgetDataSnapshot(
            updatedAt: Date(),
            entries: [
                WidgetEntry(
                    id: "claude",
                    provider: "claudeCode",
                    displayName: "Claude Code",
                    value: "82%",
                    remainingRatio: 0.82,
                    leadingText: nil,
                    colorHex: "#D97757"
                ),
                WidgetEntry(
                    id: "codex",
                    provider: "codex",
                    displayName: "Codex",
                    value: "64%",
                    remainingRatio: 0.64,
                    leadingText: nil,
                    colorHex: "#7A9CFF"
                )
            ],
            awaitingInputCount: 1,
            allExhausted: false,
            breakSuggestion: nil
        )
    }
}

private struct TokiWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TokiTimelineEntry

    var body: some View {
        Group {
            if let data = entry.data, !data.entries.isEmpty, !data.isStale(at: entry.date) {
                content(data)
            } else {
                emptyState
            }
        }
        .widgetContainerBackground()
    }

    @ViewBuilder
    private func content(_ data: WidgetDataSnapshot) -> some View {
        if data.allExhausted {
            VStack(alignment: .leading, spacing: 8) {
                widgetHeader
                Text(data.breakSuggestion ?? "Take a break")
                    .font(family == .systemSmall ? .title3 : .title2)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .topTrailing) {
                attentionBadge(data.awaitingInputCount)
            }
        } else if family == .systemMedium {
            mediumContent(data)
        } else {
            smallContent(data)
        }
    }

    private func smallContent(_ data: WidgetDataSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                widgetHeader
                Spacer()
                attentionBadge(data.awaitingInputCount)
            }
            let shown = Array(data.entries.prefix(2))
            let titles = disambiguatedTitles(shown)
            ForEach(shown) { item in
                ProviderRow(item: item, title: titles[item.id] ?? item.displayName)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func mediumContent(_ data: WidgetDataSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                widgetHeader
                Spacer()
                attentionBadge(data.awaitingInputCount)
            }
            let shown = Array(data.entries.prefix(4))
            let titles = disambiguatedTitles(shown)
            HStack(alignment: .top, spacing: 12) {
                ForEach(shown) { item in
                    ProviderColumn(item: item, title: titles[item.id] ?? item.displayName)
                        .frame(maxWidth: .infinity)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetTokiLogo(size: 32)
            Text("Open Toki")
                .font(.headline)
            Text("Refresh usage to enable this widget.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var widgetHeader: some View {
        WidgetTokiLogo(size: 20)
            .accessibilityLabel("Toki")
    }

    @ViewBuilder
    private func attentionBadge(_ count: Int) -> some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption2.monospacedDigit().bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.red, in: Capsule())
                .accessibilityLabel("\(count) agents awaiting input")
        }
    }

}

private struct ProviderRow: View {
    let item: WidgetEntry
    var title: String

    var body: some View {
        HStack(spacing: 8) {
            ProviderGlyph(item: item, size: 18)
            Text(title)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(item.value)
                .font(.body.monospacedDigit().weight(.semibold))
                .lineLimit(1)
        }
    }
}

private struct ProviderColumn: View {
    let item: WidgetEntry
    var title: String

    var body: some View {
        VStack(spacing: 6) {
            ProviderGlyph(item: item, size: 22)
            Text(item.value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private func disambiguatedTitles(_ entries: [WidgetEntry]) -> [String: String] {
    var counts: [String: Int] = [:]
    for entry in entries { counts[entry.provider, default: 0] += 1 }
    var used: [String: Int] = [:]
    var result: [String: String] = [:]
    for entry in entries {
        if counts[entry.provider, default: 0] > 1 {
            used[entry.provider, default: 0] += 1
            result[entry.id] = "\(entry.displayName) \(used[entry.provider]!)"
        } else {
            result[entry.id] = entry.displayName
        }
    }
    return result
}

private struct QuotaRings: View {
    @Environment(\.colorScheme) private var colorScheme
    let entries: [WidgetEntry]
    let size: CGFloat

    var body: some View {
        let colors = resolvedRingColors(ringEntries, colorScheme: colorScheme)
        return ZStack {
            ForEach(Array(ringEntries.enumerated()), id: \.element.id) { index, item in
                let diameter = size - CGFloat(index) * ringSpacing * 2
                let color = colors[item.id] ?? providerColor(item.provider)

                ZStack {
                    Circle()
                        .stroke(color.opacity(0.16), lineWidth: lineWidth)
                    Circle()
                        .trim(from: 0, to: clamped(item.remainingRatio))
                        .stroke(
                            color,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: diameter, height: diameter)
                .help("\(item.displayName) · \(item.value)")
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var ringEntries: [WidgetEntry] {
        distinctByID(entries.filter { $0.remainingRatio != nil })
    }

    private var lineWidth: CGFloat {
        size / (CGFloat(max(ringEntries.count, 1)) * 5)
    }

    private var ringSpacing: CGFloat { lineWidth * 1.75 }

    private func clamped(_ ratio: Double?) -> Double {
        min(1, max(0, ratio ?? 0))
    }

    private var accessibilitySummary: String {
        ringEntries.map { "\($0.displayName), \($0.value) remaining" }.joined(separator: "; ")
    }
}

private func providerColor(_ provider: String) -> Color {
    switch provider {
    case "claude", "claudeCode", "anthropic":
        return Color(red: 0.85, green: 0.47, blue: 0.34)
    case "codex", "openai", "chatgpt":
        return Color(red: 0.48, green: 0.61, blue: 1)
    case "openCode":
        return Color(red: 0.20, green: 0.72, blue: 0.48)
    case "gemini":
        return Color(red: 0.66, green: 0.33, blue: 0.97)
    case "copilot":
        return Color(red: 0.55, green: 0.45, blue: 0.95)
    case "pi":
        return Color(red: 0.94, green: 0.36, blue: 0.55)
    case "grok":
        return Color(red: 0.66, green: 0.68, blue: 0.72)
    case "aider":
        return Color(red: 0.16, green: 0.63, blue: 0.60)
    default:
        return Color(red: 0.93, green: 0.39, blue: 0.58)
    }
}

private struct TokiQuotaRingsEntryView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: TokiTimelineEntry

    var body: some View {
        Group {
            if let data = entry.data,
               !data.isStale(at: entry.date),
               !ringEntries(data).isEmpty {
                content(data)
            } else {
                emptyState
            }
        }
        .widgetContainerBackground()
    }

    private func content(_ data: WidgetDataSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                WidgetTokiLogo(size: 20)
                    .accessibilityLabel("Toki")
                Spacer()
                if data.awaitingInputCount > 0 {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("\(data.awaitingInputCount) agents awaiting input")
                }
            }

            if family == .systemMedium {
                let rings = ringEntries(data)
                let colors = resolvedRingColors(rings, colorScheme: colorScheme)
                HStack(spacing: 22) {
                    QuotaRings(entries: data.entries, size: 104)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(rings) { item in
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(colors[item.id] ?? providerColor(item.provider))
                                    .frame(width: 8, height: 8)
                                Text(item.displayName)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(item.value)
                                    .font(.caption.monospacedDigit().weight(.semibold))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer(minLength: 6)
                QuotaRings(entries: data.entries, size: 94)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetTokiLogo(size: 32)
            Text("Open Toki")
                .font(.headline)
            Text("Refresh percentage-based usage to draw your quota rings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func ringEntries(_ data: WidgetDataSnapshot) -> [WidgetEntry] {
        distinctByID(data.entries.filter { $0.remainingRatio != nil })
    }
}

private func distinctByID(_ entries: [WidgetEntry]) -> [WidgetEntry] {
    var seen = Set<String>()
    return entries.filter { seen.insert($0.id).inserted }
}

private func resolvedRingColors(_ entries: [WidgetEntry], colorScheme: ColorScheme) -> [String: Color] {
    var result: [String: Color] = [:]
    let groups = Dictionary(grouping: entries, by: { $0.provider })
    for (_, group) in groups {
        for (index, entry) in group.enumerated() {
            if let custom = Color(hex: entry.colorHex) {
                result[entry.id] = custom
            } else if group.count == 1 {
                result[entry.id] = providerColor(entry.provider)
            } else {
                result[entry.id] = shadedColor(
                    providerColor(entry.provider),
                    index: index,
                    count: group.count,
                    colorScheme: colorScheme
                )
            }
        }
    }
    return result
}

private func shadedColor(_ base: Color, index: Int, count: Int, colorScheme: ColorScheme) -> Color {
    let ns = NSColor(base).usingColorSpace(.sRGB) ?? NSColor(base)
    let t = count > 1 ? Double(index) / Double(count - 1) : 0.5
    let factor = colorScheme == .dark ? 1 + t * 0.32 : 0.72 + t * 0.28
    return Color(
        red: min(1, Double(ns.redComponent) * factor),
        green: min(1, Double(ns.greenComponent) * factor),
        blue: min(1, Double(ns.blueComponent) * factor)
    )
}

private struct ProviderGlyph: View {
    let item: WidgetEntry
    let size: CGFloat

    var body: some View {
        Group {
            if let assetName {
                WidgetSVGLogo(asset: assetName, size: size, template: item.provider == "grok")
            } else if let leadingText = item.leadingText, !leadingText.isEmpty {
                Text(leadingText)
            } else {
                Image(systemName: symbolName)
                    .foregroundStyle(Color(hex: item.colorHex) ?? fallbackColor)
            }
        }
        .font(.system(size: size, weight: .semibold))
        .frame(width: size + 2, height: size + 2)
    }

    private var assetName: String? {
        switch item.provider {
        case "claude", "claudeCode", "anthropic": return "claude-logo"
        case "codex", "openai", "chatgpt": return "codex-logo"
        case "openCode": return "opencode-logo"
        case "gemini": return "gemini-logo"
        case "grok": return "grok-logo"
        case "pi": return "pi-logo"
        case "cursor": return "cursor-logo"
        default: return nil
        }
    }

    private var symbolName: String {
        switch item.provider {
        case "claude", "claudeCode", "anthropic": return "sparkle"
        case "codex", "openai", "chatgpt": return "hexagon"
        case "copilot": return "chevron.left.forwardslash.chevron.right"
        case "gemini": return "sparkles"
        case "grok": return "asterisk"
        case "aider": return "terminal.fill"
        default: return "terminal"
        }
    }

    private var fallbackColor: Color {
        switch item.provider {
        case "claude", "claudeCode", "anthropic": return Color(red: 0.85, green: 0.47, blue: 0.34)
        case "codex", "openai", "chatgpt": return Color(red: 0.48, green: 0.61, blue: 1)
        case "aider": return Color(red: 0.16, green: 0.63, blue: 0.60)
        default: return .primary
        }
    }
}

private enum WidgetSVGAsset {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor static func image(named name: String, template: Bool = false) -> NSImage? {
        let cacheKey = "\(name):\(template)"
        if let cached = cache[cacheKey] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.isTemplate = template
        cache[cacheKey] = image
        return image
    }
}

private struct WidgetSVGLogo: View {
    let asset: String
    let size: CGFloat
    var template = false

    var body: some View {
        Group {
            if let image = WidgetSVGAsset.image(named: asset, template: template) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.primary)
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct WidgetTokiLogo: View {
    @Environment(\.colorScheme) private var colorScheme
    let size: CGFloat

    var body: some View {
        WidgetSVGLogo(
            asset: colorScheme == .dark
                ? "toki-router-glyph-dark"
                : "toki-router-glyph-light",
            size: size
        )
        .accessibilityLabel("/toki")
    }
}

private extension Color {
    init?(hex: String?) {
        guard let hex else { return nil }
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}

private extension View {
    @ViewBuilder
    func widgetContainerBackground() -> some View {
        if #available(macOS 26, *) {
            containerBackground(.regularMaterial, for: .widget)
        } else {
            containerBackground(.fill.tertiary, for: .widget)
        }
    }
}

private struct TokiWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: tokiWidgetKind, provider: TokiTimelineProvider()) { entry in
            TokiWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Toki Usage")
        .description("Your AI coding account quota at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct TokiQuotaRingsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: tokiQuotaRingsWidgetKind, provider: TokiTimelineProvider()) { entry in
            TokiQuotaRingsEntryView(entry: entry)
        }
        .configurationDisplayName("Toki Quota Rings")
        .description("Three live quota rings for your percentage-based AI accounts.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct TokiWidgets: WidgetBundle {
    var body: some Widget {
        TokiWidget()
        TokiQuotaRingsWidget()
    }
}
