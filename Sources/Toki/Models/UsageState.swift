import Foundation

struct UsageState: Codable {
    var accounts: [String: AccountUsageState] = [:]
    var apiLastCalledAt: [String: Date] = [:]
    var notificationLastSentAt: [String: Date] = [:]
    var preferences = AppPreferences()
    var events: [TokiEvent] = []
    var history: [UsageHistoryEntry] = []
    var session: SessionState?

    enum CodingKeys: String, CodingKey {
        case accounts
        case apiLastCalledAt
        case notificationLastSentAt
        case preferences
        case events
        case history
        case session
    }

    init(
        accounts: [String: AccountUsageState] = [:],
        apiLastCalledAt: [String: Date] = [:],
        notificationLastSentAt: [String: Date] = [:],
        preferences: AppPreferences = AppPreferences(),
        events: [TokiEvent] = [],
        history: [UsageHistoryEntry] = [],
        session: SessionState? = nil
    ) {
        self.accounts = accounts
        self.apiLastCalledAt = apiLastCalledAt
        self.notificationLastSentAt = notificationLastSentAt
        self.preferences = preferences
        self.events = events
        self.history = history
        self.session = session
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try container.decodeIfPresent([String: AccountUsageState].self, forKey: .accounts) ?? [:]
        apiLastCalledAt = try container.decodeIfPresent([String: Date].self, forKey: .apiLastCalledAt) ?? [:]
        notificationLastSentAt = try container.decodeIfPresent([String: Date].self, forKey: .notificationLastSentAt) ?? [:]
        preferences = try container.decodeIfPresent(AppPreferences.self, forKey: .preferences) ?? AppPreferences()
        events = try container.decodeIfPresent([TokiEvent].self, forKey: .events) ?? []
        history = try container.decodeIfPresent([UsageHistoryEntry].self, forKey: .history) ?? []
        session = try container.decodeIfPresent(SessionState.self, forKey: .session)
    }
}

struct AccountUsageState: Codable {
    var used: Double
    var lastResetAt: Date?
}

enum MenuBarDisplayMode: String, Codable, CaseIterable, Identifiable {
    case smart
    case lowest
    case activeClaude
    case codex
    case combined
    case accounts

    var id: String { rawValue }

    var label: String {
        switch self {
        case .smart: return "Smart"
        case .lowest: return "Lowest"
        case .activeClaude: return "Claude"
        case .codex: return "Codex"
        case .combined: return "Claude + Codex"
        case .accounts: return "Accounts"
        }
    }
}

struct AppPreferences: Codable, Equatable {
    var notificationsEnabled = true
    var dndEnabled = false
    var lowQuotaThreshold = 0.20
    var notificationCooldownMinutes = 90
    var menuBarMode = MenuBarDisplayMode.smart
    var historyRetentionDays = 14
    var sessionWarningThreshold = 0.15

    enum CodingKeys: String, CodingKey {
        case notificationsEnabled
        case dndEnabled
        case lowQuotaThreshold
        case notificationCooldownMinutes
        case menuBarMode
        case historyRetentionDays
        case sessionWarningThreshold
    }
}

enum TokiEventKind: String, Codable {
    case lowQuota
    case recovered
    case switchAccount
    case session
    case notification
    case refresh
}

struct TokiEvent: Codable, Identifiable, Hashable {
    var id = UUID()
    var timestamp = Date()
    var kind: TokiEventKind
    var title: String
    var detail: String
    var deliveredNotification: Bool
}

struct UsageHistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var timestamp = Date()
    var accountID: String
    var accountName: String
    var provider: Provider
    var remainingRatio: Double?
    var primary: String
}

struct SessionState: Codable, Equatable {
    var startedAt: Date
    var startingRemainingRatios: [String: Double]
    var startingPrimaries: [String: String]
}
