import Foundation

struct MetricLine: Identifiable, Hashable {
    var id = UUID()
    var label: String
    var value: String
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
