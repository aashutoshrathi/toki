import Foundation

struct CodexCredentials {
    var accessToken: String
    var accountID: String?
    var authMode: String?
    var email: String?
    var source: String
}

struct CodexAppServerPayload {
    var usage: Any?
    var rateLimits: Any?
    var account: Any?
}

struct CodexUsage {
    var metrics: [MetricLine] = []
    var todayTokens: Double?
    private var summary: [String: Any] = [:]

    var hasUsage: Bool {
        !metrics.isEmpty || todayTokens != nil
    }

    init(json: Any) {
        guard let data = json as? [String: Any] else { return }
        summary = (data["summary"] as? [String: Any]) ?? [:]

        let buckets = dailyBuckets(in: data)
        if let todayBucket = bucketForToday(buckets) {
            todayTokens = optionalNumber(firstValue(todayBucket, keys: ["tokens"]))
        } else if let latestBucket = latestBucket(buckets) {
            todayTokens = optionalNumber(firstValue(latestBucket, keys: ["tokens"]))
        }

        if let todayTokens {
            metrics.append(MetricLine(label: "Today", value: "\(formatCompact(todayTokens)) tokens"))
        }
        if let lifetime = summaryMetric("lifetime_tokens", "lifetimeTokens") {
            metrics.append(MetricLine(label: "Lifetime", value: "\(formatCompact(lifetime)) tokens"))
        }
        if let peak = summaryMetric("peak_daily_tokens", "peakDailyTokens") {
            metrics.append(MetricLine(label: "Peak day", value: "\(formatCompact(peak)) tokens"))
        }
        if let longestTurn = summaryMetric("longest_running_turn_sec", "longestRunningTurnSec"),
           longestTurn > 0 {
            metrics.append(MetricLine(label: "Longest turn", value: formatDuration(seconds: longestTurn)))
        }
        if let currentStreak = summaryMetric("current_streak_days", "currentStreakDays") {
            metrics.append(MetricLine(label: "Current streak", value: "\(Int(currentStreak)) days"))
        }
        if let longestStreak = summaryMetric("longest_streak_days", "longestStreakDays") {
            metrics.append(MetricLine(label: "Longest streak", value: "\(Int(longestStreak)) days"))
        }
    }

    func summaryMetric(_ keys: String...) -> Double? {
        optionalNumber(firstValue(summary, keys: keys))
    }

    private func dailyBuckets(in data: [String: Any]) -> [[String: Any]] {
        for key in ["daily_usage_buckets", "dailyUsageBuckets"] {
            if let buckets = data[key] as? [[String: Any]] {
                return buckets
            }
        }
        return []
    }

    private func bucketForToday(_ buckets: [[String: Any]]) -> [String: Any]? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        return buckets.first { bucket in
            guard let startDate = firstValue(bucket, keys: ["start_date", "startDate"]) as? String else {
                return false
            }
            return startDate.hasPrefix(today)
        }
    }

    private func latestBucket(_ buckets: [[String: Any]]) -> [String: Any]? {
        buckets.max { lhs, rhs in
            let lhsDate = (firstValue(lhs, keys: ["start_date", "startDate"]) as? String) ?? ""
            let rhsDate = (firstValue(rhs, keys: ["start_date", "startDate"]) as? String) ?? ""
            return lhsDate < rhsDate
        }
    }
}

struct CodexRateLimits {
    var metrics: [MetricLine] = []
    var primary: String?
    var subtitle: String?
    var remainingRatio: Double?
    var progressRatio: Double?
    var resetCreditsAvailable: Int = 0

    var hasUsage: Bool {
        !metrics.isEmpty || primary != nil
    }

    init(json: Any) {
        guard let data = json as? [String: Any] else { return }
        let limits = preferredLimit(from: data)
        let plan = firstValue(limits, keys: ["planType"]) as? String
        subtitle = plan.map { "OpenAI Codex - \($0)" } ?? "OpenAI Codex rate limits"

        if let primaryWindow = limits["primary"] as? [String: Any] {
            appendWindow(primaryWindow, fallbackLabel: "5h")
        }
        if let secondaryWindow = limits["secondary"] as? [String: Any] {
            appendWindow(secondaryWindow, fallbackLabel: "7d")
        }
        if let resetCredits = data["rateLimitResetCredits"] as? [String: Any],
           let count = optionalNumber(firstValue(resetCredits, keys: ["availableCount"])) {
            resetCreditsAvailable = Int(count)
            if resetCreditsAvailable > 0 {
                metrics.append(MetricLine(label: "Resets", value: "\(resetCreditsAvailable) available"))
            }
        }
        if let credits = limits["credits"] as? [String: Any] {
            appendCredits(credits)
        }
        if let reached = firstValue(limits, keys: ["rateLimitReachedType"]) as? String, !reached.isEmpty {
            metrics.append(MetricLine(label: "Limit", value: reached))
        }
    }

    private func preferredLimit(from data: [String: Any]) -> [String: Any] {
        if let byID = data["rateLimitsByLimitId"] as? [String: Any],
           let codex = byID["codex"] as? [String: Any] {
            return codex
        }
        return (data["rateLimits"] as? [String: Any]) ?? [:]
    }

    private mutating func appendWindow(_ window: [String: Any], fallbackLabel: String) {
        guard let usedPercent = optionalNumber(firstValue(window, keys: ["usedPercent"])) else {
            return
        }

        let label = windowLabel(window, fallback: fallbackLabel)
        let clampedUsed = max(0, min(100, usedPercent))
        if primary == nil {
            primary = "\(Int((100 - clampedUsed).rounded()))% left"
            progressRatio = clampedUsed / 100
            remainingRatio = 1 - (clampedUsed / 100)
        }

        var value = "\(Int(clampedUsed.rounded()))% used"
        if let reset = resetDescriptionFromUnix(firstValue(window, keys: ["resetsAt"])) {
            value += " - resets in \(reset)"
        }
        metrics.append(MetricLine(label: label, value: value))
    }

    private func windowLabel(_ window: [String: Any], fallback: String) -> String {
        guard let minutes = optionalNumber(firstValue(window, keys: ["windowDurationMins"])) else {
            return fallback
        }
        if minutes == 300 { return "5h" }
        if minutes == 10080 { return "7d" }
        if minutes >= 1440 { return "\(Int(minutes / 1440))d" }
        if minutes >= 60 { return "\(Int(minutes / 60))h" }
        return "\(Int(minutes))m"
    }

    private mutating func appendCredits(_ credits: [String: Any]) {
        if let unlimited = credits["unlimited"] as? Bool, unlimited {
            metrics.append(MetricLine(label: "Credits", value: "Unlimited"))
            return
        }
        if let hasCredits = credits["hasCredits"] as? Bool {
            metrics.append(MetricLine(label: "Credits", value: hasCredits ? "Available" : "Depleted"))
        }
        if let balance = credits["balance"] as? String, !balance.isEmpty {
            metrics.append(MetricLine(label: "Balance", value: balance))
        }
    }
}

struct CodexAccountInfo {
    static func lines(from value: Any?) -> [MetricLine] {
        guard let data = value as? [String: Any],
              let account = data["account"] as? [String: Any] else {
            return []
        }

        var lines: [MetricLine] = []
        if let type = firstValue(account, keys: ["type"]) as? String {
            lines.append(MetricLine(label: "Account type", value: type))
        }
        if let plan = firstValue(account, keys: ["planType"]) as? String {
            lines.append(MetricLine(label: "Plan", value: plan))
        }
        if let email = firstValue(account, keys: ["email"]) as? String, !email.isEmpty {
            lines.append(MetricLine(label: "Email", value: email))
        }
        return lines
    }
}
