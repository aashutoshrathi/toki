import AppKit
import Foundation
import SwiftUI

func resetDescription(_ value: Any?) -> String? {
    // Accept an ISO8601 string or a numeric epoch (seconds or milliseconds), since
    // reset timestamps arrive in different shapes across providers/payloads.
    if let raw = value as? String, let resetDate = ISO8601DateFormatter().date(from: raw) {
        return resetDescription(for: resetDate)
    }
    if let seconds = optionalNumber(value) {
        // Values above ~year-2001-in-ms are milliseconds; scale them down.
        let normalized = seconds > 100_000_000_000 ? seconds / 1000 : seconds
        return resetDescription(for: Date(timeIntervalSince1970: normalized))
    }
    return nil
}

func resetDescriptionFromUnix(_ value: Any?) -> String? {
    guard let seconds = optionalNumber(value) else { return nil }
    return resetDescription(for: Date(timeIntervalSince1970: seconds))
}

func resetDescription(for resetDate: Date) -> String {
    let countdown = relativeDate(resetDate)
    let formatter = DateFormatter()
    formatter.dateFormat = Calendar.current.isDateInToday(resetDate) ? "HH:mm" : "MMM d HH:mm"
    return "\(formatter.string(from: resetDate)) (\(countdown))"
}

func formatCompact(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = value >= 100 ? 0 : 1

    let absValue = abs(value)
    if absValue >= 1_000_000 {
        return "\(formatter.string(from: NSNumber(value: value / 1_000_000)) ?? "0")M"
    }
    if absValue >= 1_000 {
        return "\(formatter.string(from: NSNumber(value: value / 1_000)) ?? "0")K"
    }
    return formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))"
}

func formatUSD(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.maximumFractionDigits = value >= 10 ? 0 : 2
    return formatter.string(from: NSNumber(value: value)) ?? "$0"
}

func formatDuration(seconds: Double) -> String {
    let total = max(Int(seconds.rounded()), 0)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    if hours > 0 {
        return "\(hours)h \(minutes)m"
    }
    if minutes > 0 {
        return "\(minutes)m"
    }
    return "\(total)s"
}

func remainingText(from value: String) -> String {
    if let usedPercent = usedPercent(in: value) {
        let remaining = max(0, min(100, 100 - Int(usedPercent.rounded())))
        return "\(remaining)% left"
    }
    return value.components(separatedBy: " - ").first ?? value
}

func usedPercent(in value: String) -> Double? {
    guard let percentIndex = value.firstIndex(of: "%") else { return nil }
    let prefix = value[..<percentIndex]
    let candidates = prefix.split { character in
        !character.isNumber && character != "."
    }
    return candidates.last.flatMap { Double($0) }
}

func relativeDate(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

func colorFromHex(_ raw: String?) -> Color? {
    guard var raw else { return nil }
    raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.hasPrefix("#") {
        raw.removeFirst()
    }
    guard raw.count == 6, let value = Int(raw, radix: 16) else {
        return nil
    }
    let red = Double((value >> 16) & 0xFF) / 255
    let green = Double((value >> 8) & 0xFF) / 255
    let blue = Double(value & 0xFF) / 255
    return Color(red: red, green: green, blue: blue)
}

func availabilityColor(for percent: Int) -> Color {
    if percent > 75 {
        return .primary
    }
    if percent > 42 {
        return Color(red: 1.0, green: 0.64, blue: 0.18)
    }
    return Color(red: 1.0, green: 0.48, blue: 0.50)
}

func copyToPasteboard(_ value: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(value, forType: .string)
}

func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

func compactIdentifier(_ value: String) -> String {
    guard value.count > 16 else { return value }
    return "\(value.prefix(8))...\(value.suffix(6))"
}
