import Foundation

struct ClaudeCodeAccountRecord: Hashable {
    var id: String
    var name: String
    var email: String?
    var organizationName: String?
    var organizationUUID: String?
    var accountNumber: Int?
    var isActive: Bool
    var source: String
    var credentials: String?
    var loadError: String?
    var label: AccountPresentation?

    // The human-facing label for this account.
    //
    // `name` carries whatever the registry recorded, which for claude-swap is the bare
    // email, while `id` is a machine key ("claude-1-user@example.com") built from the
    // registry's own account numbering. Neither reads as a name. An explicit nickname
    // always wins; otherwise "Claude - <email>" keeps a multi-account setup
    // distinguishable without leaking the internal numbering into the UI.
    //
    // `id` is deliberately left alone - it keys aliases, adjustments, and cached state,
    // so renaming it would orphan any of those a user has already set.
    var displayName: String {
        if let nickname = label?.nickname, !nickname.isEmpty { return nickname }
        guard let email, !email.isEmpty else { return "Claude" }
        return "Claude - \(email)"
    }
}

struct AccountPresentation: Hashable {
    var nickname: String?
    var emoji: String?
    var color: String?
}

struct ClaudeSwapSequence: Decodable {
    var activeAccountNumber: Int?
    var sequence: [Int]?
    var accounts: [String: ClaudeSwapAccount]
}

struct ClaudeSwapAccount: Decodable {
    var email: String
    var uuid: String?
    var organizationUuid: String?
    var organizationName: String?
    var added: String?
}

struct UsageMetric {
    var label: String
    var utilization: Double
    var resetDescription: String?
}

struct ClaudeCodeUsage {
    var primaryMetric: UsageMetric?
    var metrics: [MetricLine] = []
    var rateLimitWindows: [RateLimitWindow] = []
    var worstUtilization: Double?

    var hasUsage: Bool {
        !metrics.isEmpty
    }

    init(json: Any) {
        guard let data = json as? [String: Any] else { return }

        if let fiveHour = data["five_hour"] as? [String: Any] {
            appendWindow("5h", fiveHour)
        }
        if let sevenDay = data["seven_day"] as? [String: Any] {
            appendWindow("7d", sevenDay)
        }
        if let extraUsage = data["extra_usage"] as? [String: Any] {
            appendExtraUsage(extraUsage)
        }
    }

    private mutating func appendWindow(_ label: String, _ window: [String: Any]) {
        // Anthropic keeps a window key in the response even when that quota does not apply,
        // using null utilization. Treat that as absent rather than inventing 0% usage.
        guard let utilization = optionalNumber(window["utilization"]) else { return }

        worstUtilization = max(worstUtilization ?? utilization, utilization)
        let reset = resetDescription(window["resets_at"])
        let metric = UsageMetric(
            label: label,
            utilization: utilization,
            resetDescription: reset
        )
        if primaryMetric == nil {
            primaryMetric = metric
        }

        let clampedUsed = max(0, min(100, utilization))
        rateLimitWindows.append(RateLimitWindow(
            label: label,
            percentLeft: Int((100 - clampedUsed).rounded()),
            resetHint: reset.map { "resets in \($0)" }
        ))

        var value = "\(Int(utilization.rounded()))% used"
        if let reset {
            value += " - resets in \(reset)"
        }
        metrics.append(MetricLine(label: label, value: value))
    }

    private mutating func appendExtraUsage(_ extraUsage: [String: Any]) {
        guard (extraUsage["is_enabled"] as? Bool) == true else {
            metrics.append(MetricLine(label: "Extra", value: "Disabled"))
            return
        }

        guard let usedCents = optionalNumber(extraUsage["used_credits"]),
              let limitCents = optionalNumber(extraUsage["monthly_limit"]),
              let utilization = optionalNumber(extraUsage["utilization"]) else {
            metrics.append(MetricLine(label: "Extra", value: "Enabled"))
            return
        }
        var value = "\(formatUSD(usedCents / 100)) / \(formatUSD(limitCents / 100))"
        value += " - \(Int(utilization.rounded()))%"
        if let reset = resetDescription(extraUsage["resets_at"]) {
            value += " - resets in \(reset)"
        }
        metrics.append(MetricLine(label: "Extra", value: value))
    }
}

struct DebugLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
}

struct MenuBarStatusEntry: Identifiable, Codable, Sendable {
    var id: Provider { provider }
    var provider: Provider
    var value: String
    var leadingText: String? = nil
}
