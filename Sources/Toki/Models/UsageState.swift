import Foundation

struct UsageState: Codable {
    var accounts: [String: AccountUsageState] = [:]
    var apiLastCalledAt: [String: Date] = [:]
    var eventLastRecordedAt: [String: Date] = [:]
    var preferences = AppPreferences()
    var events: [TokiEvent] = []
    var history: [UsageHistoryEntry] = []
    var session: SessionState?

    enum CodingKeys: String, CodingKey {
        case accounts
        case apiLastCalledAt
        case eventLastRecordedAt
        case preferences
        case events
        case history
        case session
    }

    init(
        accounts: [String: AccountUsageState] = [:],
        apiLastCalledAt: [String: Date] = [:],
        eventLastRecordedAt: [String: Date] = [:],
        preferences: AppPreferences = AppPreferences(),
        events: [TokiEvent] = [],
        history: [UsageHistoryEntry] = [],
        session: SessionState? = nil
    ) {
        self.accounts = accounts
        self.apiLastCalledAt = apiLastCalledAt
        self.eventLastRecordedAt = eventLastRecordedAt
        self.preferences = preferences
        self.events = events
        self.history = history
        self.session = session
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try container.decodeIfPresent([String: AccountUsageState].self, forKey: .accounts) ?? [:]
        apiLastCalledAt = try container.decodeIfPresent([String: Date].self, forKey: .apiLastCalledAt) ?? [:]
        eventLastRecordedAt = try container.decodeIfPresent([String: Date].self, forKey: .eventLastRecordedAt) ?? [:]
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

/// Where the notch panel rests when it is not expanded.
enum NotchPlacement: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Hangs below the housing, matching its width.
    case hanging
    /// Sits in the menu bar band beside the housing, reading as a wider notch.
    case sideways

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hanging: return "Hanging"
        case .sideways: return "Sideways"
        }
    }
}

struct AppPreferences: Codable, Equatable {
    var notificationsEnabled = true
    var dndEnabled = false
    var lowQuotaThreshold = 0.20
    var notificationCooldownMinutes = 90
    var menuBarMode = MenuBarDisplayMode.smart
    // 30 days by default so the usage heatmap can fill its full window; it renders
    // min(30, retention), so a shorter retention silently shortens the chart.
    var historyRetentionDays = 30
    var sessionWarningThreshold = 0.15
    /// Experimental: render the status readout at the display notch instead of the menu bar.
    /// Off by default - it relocates the whole app, so it is opt-in.
    var notchModeEnabled = false
    var notchPlacement = NotchPlacement.hanging

    enum CodingKeys: String, CodingKey {
        case notificationsEnabled
        case dndEnabled
        case lowQuotaThreshold
        case notificationCooldownMinutes
        case menuBarMode
        case historyRetentionDays
        case sessionWarningThreshold
        case notchModeEnabled
        case notchPlacement
    }

    init() {}

    // Decoded field by field with decodeIfPresent so that every key is optional and a missing
    // one falls back to its default.
    //
    // The synthesized decoder does NOT do this: it calls decode() for each non-optional
    // property and throws keyNotFound when a key is absent, and a property's default value is
    // never consulted. That makes adding a single preference a breaking change for every
    // existing state file - the decode throws, StateLoader falls back to an empty state, and
    // the next save overwrites the user's accumulated history with it. That is exactly what
    // adding notchModeEnabled did, so this decoder exists to make the whole struct additive
    // by construction rather than relying on remembering the hazard next time.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppPreferences()
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? defaults.notificationsEnabled
        dndEnabled = try container.decodeIfPresent(Bool.self, forKey: .dndEnabled) ?? defaults.dndEnabled
        lowQuotaThreshold = try container.decodeIfPresent(Double.self, forKey: .lowQuotaThreshold) ?? defaults.lowQuotaThreshold
        notificationCooldownMinutes = try container.decodeIfPresent(Int.self, forKey: .notificationCooldownMinutes) ?? defaults.notificationCooldownMinutes
        menuBarMode = try container.decodeIfPresent(MenuBarDisplayMode.self, forKey: .menuBarMode) ?? defaults.menuBarMode
        historyRetentionDays = try container.decodeIfPresent(Int.self, forKey: .historyRetentionDays) ?? defaults.historyRetentionDays
        sessionWarningThreshold = try container.decodeIfPresent(Double.self, forKey: .sessionWarningThreshold) ?? defaults.sessionWarningThreshold
        notchModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .notchModeEnabled) ?? defaults.notchModeEnabled
        notchPlacement = try container.decodeIfPresent(NotchPlacement.self, forKey: .notchPlacement) ?? defaults.notchPlacement
    }
}

enum TokiEventKind: String, Codable {
    case lowQuota
    case recovered
    case switchAccount
    case session
    case notification
    case refresh
    case reset
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
