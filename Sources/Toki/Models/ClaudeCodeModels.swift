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
    /// Weekly limits that apply to one model rather than to everything. Kept apart from
    /// `rateLimitWindows` because they are a separate allowance: burning the Fable week does not
    /// touch the shared one, so folding them together would misreport both.
    var modelWindows: [RateLimitWindow] = []
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
        appendModelWindows(data["limits"])
    }

    // The top-level keys are codenames (seven_day_omelette, seven_day_tangelo) that say nothing
    // about which model they belong to, and a release can add another at any time. `limits`
    // describes itself instead: a scoped weekly entry carries the model's own display name, so a
    // limit for a model Toki has never heard of renders correctly and reads the way Anthropic
    // writes it.
    private mutating func appendModelWindows(_ raw: Any?) {
        guard let entries = raw as? [[String: Any]] else { return }
        for entry in entries {
            guard Self.isScopedWeekly(entry),
                  let name = Self.scopeName(entry["scope"]),
                  let percentUsed = optionalNumber(entry["percent"]) else { continue }

            let clampedUsed = max(0, min(100, percentUsed))
            let reset = resetDescription(entry["resets_at"])
            modelWindows.append(RateLimitWindow(
                label: "\(name) 7d",
                percentLeft: Int((100 - clampedUsed).rounded()),
                resetHint: reset.map { "resets in \($0)" }
            ))
        }
    }

    /// `weekly_scoped` is what the API calls a limit that applies to one model. `weekly_all` is
    /// the shared allowance, already covered by seven_day, and counting it here would show the
    /// same quota twice. The group check is a fallback for a kind spelled differently later.
    static func isScopedWeekly(_ entry: [String: Any]) -> Bool {
        let kind = (entry["kind"] as? String) ?? ""
        if kind == "weekly_all" { return false }
        return kind == "weekly_scoped" || kind.hasPrefix("weekly") || (entry["group"] as? String) == "weekly"
    }

    /// The scope is an object - `scope.model.display_name` - not a string, so a model reads as
    /// "Fable 5" rather than as whatever codename the top-level keys use. A bare string is
    /// accepted too, in case the shape is ever flattened.
    static func scopeName(_ scope: Any?) -> String? {
        if let text = scope as? String, !text.isEmpty { return text }
        guard let dict = scope as? [String: Any] else { return nil }
        if let model = dict["model"] as? [String: Any],
           let name = model["display_name"] as? String, !name.isEmpty { return name }
        if let name = dict["display_name"] as? String, !name.isEmpty { return name }
        return nil
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
