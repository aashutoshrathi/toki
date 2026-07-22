import AppKit
import Foundation
import SwiftUI

func resetDescription(_ value: Any?) -> String? {
    // Accept an ISO8601 string or a numeric epoch (seconds or milliseconds), since
    // reset timestamps arrive in different shapes across providers/payloads.
    if let raw = value as? String, let resetDate = parseISODate(raw) {
        return resetDescription(for: resetDate)
    }
    if let seconds = optionalNumber(value) {
        // Values above ~year-2001-in-ms are milliseconds; scale them down.
        let normalized = seconds > 100_000_000_000 ? seconds / 1000 : seconds
        return resetDescription(for: Date(timeIntervalSince1970: normalized))
    }
    return nil
}

// Anthropic's resets_at includes fractional seconds (e.g. 2026-07-12T18:00:00.000Z),
// which the default ISO8601DateFormatter rejects - try both configurations.
private func parseISODate(_ raw: String) -> Date? {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: raw) { return date }
    return ISO8601DateFormatter().date(from: raw)
}

func resetDescriptionFromUnix(_ value: Any?) -> String? {
    guard let seconds = optionalNumber(value) else { return nil }
    return resetDescription(for: Date(timeIntervalSince1970: seconds))
}

// Returns e.g. "3h (18:00)" - a countdown followed by the clock time. Callers prefix
// "resets in", so the countdown must not itself say "in". A fixed en_US_POSIX relative
// formatter keeps this deterministic (system-locale strings vary in word order and would
// either not start with "in" or embed it mid-word, e.g. Finnish "min").
func resetDescription(for resetDate: Date) -> String {
    let relative = RelativeDateTimeFormatter()
    relative.unitsStyle = .abbreviated
    relative.locale = Locale(identifier: "en_US_POSIX")
    var countdown = relative.localizedString(for: resetDate, relativeTo: Date())
    if countdown.hasPrefix("in ") {
        countdown.removeFirst(3)
    }
    let formatter = DateFormatter()
    formatter.dateFormat = Calendar.current.isDateInToday(resetDate) ? "HH:mm" : "MMM d HH:mm"
    return "\(countdown) (\(formatter.string(from: resetDate)))"
}

func formatCompact(_ value: Double) -> String {
    let absValue = abs(value)
    let scaled: Double
    let suffix: String
    // Billions matter here: a heavy month of agent usage runs past 1e9 tokens, and without this
    // step it rendered as "1,023M" - a grouping separator inside a compact figure, which reads
    // worse than the full number it was meant to shorten.
    if absValue >= 1_000_000_000 {
        (scaled, suffix) = (value / 1_000_000_000, "B")
    } else if absValue >= 1_000_000 {
        (scaled, suffix) = (value / 1_000_000, "M")
    } else if absValue >= 1_000 {
        (scaled, suffix) = (value / 1_000, "K")
    } else {
        (scaled, suffix) = (value, "")
    }

    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    // Precision is chosen from the SCALED magnitude, not the original. Deciding from the
    // original meant anything over 100 got zero decimals *after* scaling too, so 1,500,000
    // printed as "2M" - the decimal that carries all the meaning at this size was rounded away.
    formatter.maximumFractionDigits = abs(scaled) >= 100 ? 0 : 1
    return (formatter.string(from: NSNumber(value: scaled)) ?? "0") + suffix
}

func formatUSD(_ value: Double) -> String {
    // A non-zero spend below a cent would round to "$0.00", which reads as free rather than
    // as small - surface it as a floor instead so a just-started session never looks costless.
    if value > 0, value < 0.01 {
        return "<$0.01"
    }
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
