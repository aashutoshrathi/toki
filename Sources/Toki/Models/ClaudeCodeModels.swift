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
    var worstUtilization: Double?

    var hasUsage: Bool {
        !metrics.isEmpty
    }

    init(json: Any) {
        guard let data = json as? [String: Any] else { return }

        if let fiveHour = data["five_hour"] as? [String: Any] {
            setPrimaryWindow("Daily", fiveHour)
        }
        if let sevenDay = data["seven_day"] as? [String: Any] {
            appendWindow("7d", sevenDay)
        }
        if let extraUsage = data["extra_usage"] as? [String: Any] {
            appendExtraUsage(extraUsage)
        }
    }

    private mutating func setPrimaryWindow(_ label: String, _ window: [String: Any]) {
        let utilization = numericValue(window["utilization"] ?? 0)
        worstUtilization = max(worstUtilization ?? utilization, utilization)
        primaryMetric = UsageMetric(
            label: label,
            utilization: utilization,
            resetDescription: resetDescription(window["resets_at"])
        )
        var value = "\(Int(utilization.rounded()))% used"
        if let reset = primaryMetric?.resetDescription {
            value += " - resets \(reset)"
        }
        metrics.append(MetricLine(label: label, value: value))
    }

    private mutating func appendWindow(_ label: String, _ window: [String: Any]) {
        let utilization = numericValue(window["utilization"] ?? 0)
        worstUtilization = max(worstUtilization ?? utilization, utilization)

        var value = "\(Int(utilization.rounded()))% used"
        if let reset = resetDescription(window["resets_at"]) {
            value += " - resets \(reset)"
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
            value += " - resets \(reset)"
        }
        metrics.append(MetricLine(label: "Extra", value: value))
    }
}

struct DebugLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
}

struct MenuBarStatusEntry: Identifiable {
    var id: Provider { provider }
    var provider: Provider
    var value: String
    var leadingText: String? = nil
}
