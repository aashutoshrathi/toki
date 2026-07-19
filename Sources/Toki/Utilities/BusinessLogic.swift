import Foundation
import SwiftUI

func usageFromRemaining(_ account: AccountConfig) -> Double {
    max((account.limit ?? 0) - (account.remaining ?? 0), 0)
}

func resetAnchorDate(for account: AccountConfig) -> Date? {
    guard let resetAnchor = account.resetAnchor else { return nil }
    return ISO8601DateFormatter().date(from: resetAnchor)
}

func nextResetDate(for account: AccountConfig, state: AccountUsageState?) -> Date? {
    guard let resetEveryHours = account.resetEveryHours, resetEveryHours > 0 else { return nil }
    let window = resetEveryHours * 3600
    let anchor = state?.lastResetAt ?? resetAnchorDate(for: account) ?? Date()
    let elapsed = max(Date().timeIntervalSince(anchor), 0)
    let windowsElapsed = floor(elapsed / window) + 1
    return anchor.addingTimeInterval(windowsElapsed * window)
}

// Cards are grouped first by whether there's anything useful to show: a real quota
// (tier 0), then agent-detection-only providers with an active session right now
// (tier 1, since there's at least a live signal), then agent-detection-only providers
// sitting idle (tier 2). Everything else (error state, remaining ratio) only breaks
// ties within a tier - it never lets an idle no-API card outrank a real quota card.
func sortedByAvailability(_ snapshots: [AccountSnapshot], activeProviders: Set<Provider> = []) -> [AccountSnapshot] {
    snapshots.enumerated()
        .sorted { lhs, rhs in
            let left = lhs.element
            let right = rhs.element

            let leftTier = availabilityTier(for: left, activeProviders: activeProviders)
            let rightTier = availabilityTier(for: right, activeProviders: activeProviders)
            if leftTier != rightTier {
                return leftTier < rightTier
            }

            if left.isError != right.isError {
                return !left.isError
            }

            let leftRemaining = left.remainingRatio
            let rightRemaining = right.remainingRatio
            if (leftRemaining == nil) != (rightRemaining == nil) {
                return leftRemaining != nil
            }

            if let leftRemaining, let rightRemaining, leftRemaining != rightRemaining {
                return leftRemaining > rightRemaining
            }

            return lhs.offset < rhs.offset
        }
        .map(\.element)
}

private func availabilityTier(for snapshot: AccountSnapshot, activeProviders: Set<Provider>) -> Int {
    if !snapshot.isAgentDetectionOnly { return 0 }
    return activeProviders.contains(snapshot.provider) ? 1 : 2
}

func menuBarEntries(for snapshots: [AccountSnapshot], mode: MenuBarDisplayMode = .smart) -> [MenuBarStatusEntry] {
    if allTrackedQuotaExhausted(snapshots) {
        let suggestion = currentBreakSuggestion()
        return [MenuBarStatusEntry(provider: .manual, value: suggestion.menuBarText, leadingText: suggestion.emoji)]
    }

    switch mode {
    case .smart:
        return smartMenuBarEntries(for: snapshots)
    case .lowest:
        return lowestMenuBarEntries(for: snapshots)
    case .activeClaude:
        return snapshots.first { $0.provider.isClaudeAccount && $0.switchTarget == nil && !$0.isError }
            .map { [menuBarEntry(for: $0)] } ?? []
    case .codex:
        return snapshots.first { $0.provider == .codex && !$0.isError }
            .map { [menuBarEntry(for: $0)] } ?? []
    case .combined:
        return smartMenuBarEntries(for: snapshots)
    case .accounts:
        return [MenuBarStatusEntry(provider: .manual, value: "\(snapshots.filter { !$0.isError }.count)")]
    }
}

private func smartMenuBarEntries(for snapshots: [AccountSnapshot]) -> [MenuBarStatusEntry] {
    let activeClaude = snapshots.first {
        $0.provider.isClaudeAccount && $0.switchTarget == nil && !$0.isError
    }
    let fallbackClaude = snapshots.first {
        $0.provider.isClaudeAccount && !$0.isError
    }
    let codex = snapshots.first {
        $0.provider == .codex && !$0.isError
    }

    // Cost-based providers (Pi) have no quota percentage, so they're never picked as the
    // Claude/Codex quota segments above and would otherwise be invisible in the menu bar - even
    // for a Pi-only user, who'd be left staring at the "-- / --" placeholder. Append their
    // compact spend value after the quota segments so they always surface.
    let costSegments = snapshots.filter { !$0.isError && $0.remainingRatio == nil && $0.menuBarValue != nil }
    let segments = [activeClaude ?? fallbackClaude, codex].compactMap { $0 } + costSegments

    return segments.map(menuBarEntry)
}

private func lowestMenuBarEntries(for snapshots: [AccountSnapshot]) -> [MenuBarStatusEntry] {
    snapshots
        .filter { !$0.isError && $0.remainingRatio != nil }
        .min { ($0.remainingRatio ?? 1) < ($1.remainingRatio ?? 1) }
        .map { [menuBarEntry(for: $0)] } ?? []
}

func menuBarPlaceholderEntries() -> [MenuBarStatusEntry] {
    [
        MenuBarStatusEntry(provider: .claudeCode, value: "--"),
        MenuBarStatusEntry(provider: .codex, value: "--")
    ]
}

func menuBarEntry(for snapshot: AccountSnapshot) -> MenuBarStatusEntry {
    let value = snapshot.remainingRatio.map(percentText) ?? snapshot.menuBarValue ?? "--"
    return MenuBarStatusEntry(provider: snapshot.provider, value: value)
}

func smartRecommendation(for snapshots: [AccountSnapshot]) -> SmartRecommendation {
    let usable = snapshots.filter { !$0.isError && $0.remainingRatio != nil }
    guard let best = usable.max(by: { ($0.remainingRatio ?? 0) < ($1.remainingRatio ?? 0) }) else {
        return SmartRecommendation(
            title: "Connect an account",
            detail: "Toki needs at least one live usage source before it can recommend where to work.",
            accountID: nil,
            switchTarget: nil,
            switchCommand: nil,
            severity: .neutral
        )
    }

    if allTrackedQuotaExhausted(snapshots) {
        let suggestion = currentBreakSuggestion()
        return SmartRecommendation(
            title: suggestion.title,
            detail: "All tracked coding quota is empty. \(suggestion.detail)",
            accountID: nil,
            switchTarget: nil,
            switchCommand: nil,
            severity: .critical
        )
    }

    let ratio = best.remainingRatio ?? 0
    if ratio <= 0.15 {
        return SmartRecommendation(
            title: "All coding fuel is low",
            detail: "Best available is \(best.name) at \(percentText(ratio)). Consider waiting for the next reset.",
            accountID: best.id,
            switchTarget: best.switchTarget,
            switchCommand: best.switchCommand,
            severity: .critical
        )
    }

    if let activeClaude = usable.first(where: { $0.provider == .claudeCode && $0.switchTarget == nil }),
       let bestClaude = usable.filter({ $0.provider == .claudeCode }).max(by: { ($0.remainingRatio ?? 0) < ($1.remainingRatio ?? 0) }),
       bestClaude.id != activeClaude.id,
       (bestClaude.remainingRatio ?? 0) - (activeClaude.remainingRatio ?? 0) >= 0.20 {
        return SmartRecommendation(
            title: "Switch to \(bestClaude.name)",
            detail: "\(bestClaude.name) has \(percentText(bestClaude.remainingRatio ?? 0)) left versus \(percentText(activeClaude.remainingRatio ?? 0)) on the active Claude Code account.",
            accountID: bestClaude.id,
            switchTarget: bestClaude.switchTarget,
            switchCommand: bestClaude.switchCommand,
            severity: .warning
        )
    }

    let severity: RecommendationSeverity = ratio <= 0.35 ? .warning : .good
    return SmartRecommendation(
        title: "Use \(best.name) now",
        detail: "\(best.name) has the healthiest available quota at \(percentText(ratio)) remaining.",
        accountID: best.id,
        switchTarget: best.switchTarget,
        switchCommand: best.switchCommand,
        severity: severity
    )
}

func percentText(_ ratio: Double) -> String {
    "\(Int((max(0, min(1, ratio)) * 100).rounded()))%"
}

func allTrackedQuotaExhausted(_ snapshots: [AccountSnapshot]) -> Bool {
    let tracked = snapshots.filter { !$0.isError && $0.remainingRatio != nil }
    guard !tracked.isEmpty else { return false }
    return tracked.allSatisfy { ($0.remainingRatio ?? 1) <= 0.01 }
}

struct BreakSuggestion {
    var title: String
    var detail: String
    var menuBarText: String
    var emoji: String
}

func currentBreakSuggestion(now: Date = Date()) -> BreakSuggestion {
    breakSuggestions[breakSuggestionIndex(for: now)]
}

private func breakSuggestionIndex(for date: Date) -> Int {
    let hour = Calendar.current.component(.hour, from: date)
    let day = Calendar.current.ordinality(of: .day, in: .year, for: date) ?? 0
    return abs(day + hour) % breakSuggestions.count
}

private let breakSuggestions = [
    BreakSuggestion(title: "Take a walk", detail: "Take a walk, mate. Ten minutes away from the screen is a valid productivity tool.", menuBarText: "Take a walk, mate", emoji: "🚶"),
    BreakSuggestion(title: "Drink water", detail: "Drink some water and let the next idea arrive without a loading spinner.", menuBarText: "Drink water", emoji: "💧"),
    BreakSuggestion(title: "Stretch a bit", detail: "Stand up, stretch your shoulders, and give your neck a tiny ceasefire.", menuBarText: "Stretch a bit", emoji: "🙆"),
    BreakSuggestion(title: "Make tea", detail: "Make tea or coffee and come back when the quota gods are less dramatic.", menuBarText: "Make tea", emoji: "☕️"),
    BreakSuggestion(title: "Look outside", detail: "Look out a window for a minute. The pixels will still be here.", menuBarText: "Look outside", emoji: "🌤️"),
    BreakSuggestion(title: "Tidy desk", detail: "Clear one small thing from your desk. Future you gets a cleaner runway.", menuBarText: "Tidy desk", emoji: "🧹"),
    BreakSuggestion(title: "Breathe slowly", detail: "Take five slow breaths. Debugging is better when your nervous system is not on fire.", menuBarText: "Breathe slowly", emoji: "🫁"),
    BreakSuggestion(title: "Rest your eyes", detail: "Rest your eyes for 60 seconds and let the afterimage of the code fade.", menuBarText: "Rest eyes", emoji: "😌"),
    BreakSuggestion(title: "Write a note", detail: "Write down the next thing you wanted to ask. Save the thought before the quota resets.", menuBarText: "Write a note", emoji: "📝"),
    BreakSuggestion(title: "Check posture", detail: "Reset your posture, unclench your jaw, and pretend ergonomics is a feature.", menuBarText: "Check posture", emoji: "🪑")
]

func svgPath(_ raw: String, in rect: CGRect, viewBox: CGSize) -> Path {
    let tokens = raw.replacingOccurrences(of: "Z", with: " Z ")
        .replacingOccurrences(of: "M", with: " M ")
        .replacingOccurrences(of: "L", with: " L ")
        .replacingOccurrences(of: "H", with: " H ")
        .replacingOccurrences(of: "V", with: " V ")
        .replacingOccurrences(of: "C", with: " C ")
        .split { $0.isWhitespace || $0 == "," }
        .map(String.init)

    var path = Path()
    var index = 0
    var command = ""
    var current = CGPoint.zero
    let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
    let xOffset = rect.midX - viewBox.width * scale / 2
    let yOffset = rect.midY - viewBox.height * scale / 2

    func mapped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: xOffset + point.x * scale, y: yOffset + point.y * scale)
    }

    func nextNumber() -> CGFloat? {
        guard index < tokens.count, let number = Double(tokens[index]) else { return nil }
        index += 1
        return CGFloat(number)
    }

    while index < tokens.count {
        if Double(tokens[index]) == nil {
            command = tokens[index]
            index += 1
        }

        switch command {
        case "M":
            guard let x = nextNumber(), let y = nextNumber() else { return path }
            current = CGPoint(x: x, y: y)
            path.move(to: mapped(current))
            command = "L"
        case "L":
            guard let x = nextNumber(), let y = nextNumber() else { return path }
            current = CGPoint(x: x, y: y)
            path.addLine(to: mapped(current))
        case "H":
            guard let x = nextNumber() else { return path }
            current = CGPoint(x: x, y: current.y)
            path.addLine(to: mapped(current))
        case "V":
            guard let y = nextNumber() else { return path }
            current = CGPoint(x: current.x, y: y)
            path.addLine(to: mapped(current))
        case "C":
            guard let x1 = nextNumber(), let y1 = nextNumber(),
                  let x2 = nextNumber(), let y2 = nextNumber(),
                  let x = nextNumber(), let y = nextNumber() else { return path }
            let end = CGPoint(x: x, y: y)
            path.addCurve(to: mapped(end), control1: mapped(CGPoint(x: x1, y: y1)), control2: mapped(CGPoint(x: x2, y: y2)))
            current = end
        case "Z":
            path.closeSubpath()
        default:
            index += 1
        }
    }

    return path
}
