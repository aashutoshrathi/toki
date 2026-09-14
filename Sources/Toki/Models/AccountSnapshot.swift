import Foundation

enum MetricGroup: String, CaseIterable, Hashable {
    case quota = "Quota"
    case activity = "Activity"
    case usage = "Usage"
    case account = "Account details"
}

struct MetricLine: Identifiable, Hashable {
    var id = UUID()
    var label: String
    var value: String
    var group: MetricGroup = .usage
}

enum AccountProgressKind: Hashable {
    case quota
    case usage
}

// A single rate-limit window (e.g. Codex's rolling 5h window or its 7-day window), broken
// out separately from `metrics` so providers with more than one concurrent quota window can
// surface each one explicitly instead of collapsing them into a single generic percentage.
struct RateLimitWindow: Identifiable, Hashable {
    var id: String { label }
    var label: String
    var percentLeft: Int
    var resetHint: String?
    var resetAt: Date? = nil
    var duration: TimeInterval? = nil

    func expectedRemainingRatio(at date: Date = Date()) -> Double? {
        guard let resetAt, let duration, duration.isFinite, duration > 0 else { return nil }
        let remaining = resetAt.timeIntervalSince(date)
        guard remaining > 0, remaining <= duration else { return nil }
        return remaining / duration
    }

    func paceDeviation(at date: Date = Date()) -> Int? {
        guard let expectedRemaining = expectedRemainingRatio(at: date) else { return nil }
        let expectedUsed = (1 - expectedRemaining) * 100
        return Int((Double(100 - percentLeft) - expectedUsed).rounded())
    }
}

struct AccountSnapshot: Identifiable, Hashable {
    var id: String
    var name: String
    var provider: Provider
    var primary: String
    var subtitle: String
    var remainingRatio: Double?
    var progressRatio: Double? = nil
    var resetCreditsAvailable: Int = 0
    // Soonest expiry of available Codex reset credits. Null when credits don't expire or
    // when only the count is known. Surfaced in the UI so the user can decide whether to
    // redeem now or wait (issue #130).
    var resetCreditExpiry: Date? = nil
    var metrics: [MetricLine]
    var accountInfo: [MetricLine] = []
    var isError: Bool = false
    var canAdjust: Bool = false
    var switchTarget: String?
    var switchCommand: String?
    var emoji: String?
    var colorHex: String?
    var primaryWindow: RateLimitWindow? = nil
    var secondaryWindow: RateLimitWindow? = nil
    /// Weekly limits scoped to a single model, which are a separate allowance from the shared
    /// windows above rather than a subdivision of them.
    var modelWindows: [RateLimitWindow] = []
    // A compact value (e.g. Pi's "$1.20" today-spend) for cost-based providers that have no
    // percentage to show. When set, the menu bar renders this instead of a "--" placeholder.
    var menuBarValue: String? = nil
    // True for providers with no usage/quota API at all (Grok, Copilot) - the card still
    // shows identity and active-session count, but never a percentage or progress bar.
    var isAgentDetectionOnly: Bool = false
    var isSignInExpired: Bool = false
    var lastActivity: Date? = nil
    /// Supplied by the source of a compact cost reading; a display string alone cannot tell
    /// whether a provider reports a day, billing cycle, or lifetime amount.
    var menuBarValuePeriod: String? = nil
    var progressKind: AccountProgressKind = .usage

    var displayProgressRatio: Double? {
        let value = progressKind == .quota ? remainingRatio : (progressRatio ?? remainingRatio.map { 1 - $0 })
        return value.map { min(1, max(0, $0)) }
    }

    static let loadingPrimary = "Refreshing"

    var isLoadingPlaceholder: Bool {
        primary == AccountSnapshot.loadingPrimary && metrics.isEmpty && remainingRatio == nil
    }

    static func loading(for account: AccountConfig) -> AccountSnapshot {
        AccountSnapshot(
            id: account.id,
            name: account.name,
            provider: account.provider,
            primary: loadingPrimary,
            subtitle: account.provider.displayName,
            remainingRatio: nil,
            progressRatio: nil,
            metrics: [],
            isError: false
        )
    }
}
