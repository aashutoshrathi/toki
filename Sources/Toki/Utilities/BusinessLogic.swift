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

func sortedByAvailability(_ snapshots: [AccountSnapshot]) -> [AccountSnapshot] {
    snapshots.enumerated()
        .sorted { lhs, rhs in
            let left = lhs.element
            let right = rhs.element

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

func menuBarStatus(for snapshots: [AccountSnapshot]) -> String {
    let entries = menuBarEntries(for: snapshots)
    guard !entries.isEmpty else { return "Toki --" }
    return entries.map { "\($0.value)" }.joined(separator: "  ")
}

func menuBarEntries(for snapshots: [AccountSnapshot]) -> [MenuBarStatusEntry] {
    let activeClaude = snapshots.first {
        $0.provider.isClaudeAccount && $0.switchTarget == nil && !$0.isError
    }
    let fallbackClaude = snapshots.first {
        $0.provider.isClaudeAccount && !$0.isError
    }
    let codex = snapshots.first {
        $0.provider == .codex && !$0.isError
    }

    let segments = [activeClaude ?? fallbackClaude, codex].compactMap { $0 }

    return segments.map(menuBarEntry)
}

func menuBarPlaceholderEntries() -> [MenuBarStatusEntry] {
    [
        MenuBarStatusEntry(provider: .claudeCode, value: "--"),
        MenuBarStatusEntry(provider: .codex, value: "--")
    ]
}

func menuBarEntry(for snapshot: AccountSnapshot) -> MenuBarStatusEntry {
    let value = snapshot.remainingRatio.map { "\(Int(($0 * 100).rounded()))%" } ?? "--"
    return MenuBarStatusEntry(provider: snapshot.provider, value: value)
}

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


