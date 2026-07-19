import Foundation

struct MetricLine: Identifiable, Hashable {
    var id = UUID()
    var label: String
    var value: String
}

// A single rate-limit window (e.g. Codex's rolling 5h window or its 7-day window), broken
// out separately from `metrics` so providers with more than one concurrent quota window can
// surface each one explicitly instead of collapsing them into a single generic percentage.
struct RateLimitWindow: Identifiable, Hashable {
    var id: String { label }
    var label: String
    var percentLeft: Int
    var resetHint: String?
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
    // A compact value (e.g. Pi's "$1.20" today-spend) for cost-based providers that have no
    // percentage to show. When set, the menu bar renders this instead of a "--" placeholder.
    var menuBarValue: String? = nil
    // True for providers with no usage/quota API at all (Grok, Copilot) - the card still
    // shows identity and active-session count, but never a percentage or progress bar.
    var isAgentDetectionOnly: Bool = false

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
