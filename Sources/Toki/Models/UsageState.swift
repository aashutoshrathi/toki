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
    case pinned
    case accounts
    case logoOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .smart: return "Smart"
        case .lowest: return "Lowest"
        case .pinned: return "Pinned"
        case .accounts: return "Accounts"
        case .logoOnly: return "Logo only"
        }
    }

    var detail: String {
        switch self {
        case .smart: return "The account you are on, plus Codex"
        case .lowest: return "Whichever quota is closest to running out"
        case .pinned: return "Only the providers you choose"
        case .accounts: return "How many accounts are connected"
        case .logoOnly: return "Just the Toki mark, no numbers"
        }
    }

    /// Reads a stored raw value, including ones written by versions before 3.1. `combined`
    /// was an exact duplicate of `smart`, and the two hardcoded provider modes are now
    /// `pinned` with the provider itself carried in `menuBarPinnedProviders`.
    ///
    /// The retired Claude mode matched the whole Claude family, not just Claude Code, so it
    /// migrates to a pin on both. Pins that match no connected account are skipped, so a user
    /// on one of the two still sees exactly the single segment they saw before.
    static func stored(rawValue: String) -> (mode: MenuBarDisplayMode, pinned: [Provider])? {
        switch rawValue {
        case "combined": return (.smart, [])
        case "activeClaude": return (.pinned, [.claudeCode, .claude])
        case "codex": return (.pinned, [.codex])
        default: return MenuBarDisplayMode(rawValue: rawValue).map { ($0, []) }
        }
    }
}

/// How tightly the menu bar readout is packed. Independent of `MenuBarDisplayMode`, which
/// decides *what* is shown - this only decides how much horizontal room it takes, because the
/// status item competes with every other icon on the bar.
enum MenuBarDensity: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Full-size glyphs and numbers on a single row.
    case comfortable
    /// Smaller glyphs and numbers on a single row, with the percent sign dropped.
    case compact
    /// Two half-height rows, so a two-provider readout is about half as wide.
    case stacked

    var id: String { rawValue }

    var label: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .compact: return "Compact"
        case .stacked: return "Stacked"
        }
    }
}

/// Where the notch panel rests when it is not expanded.
enum NotchPlacement: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Hangs below the housing, matching its width.
    case hanging
    /// Sits in the menu bar band beside the housing, reading as a wider notch.
    case sideways
    /// Splits across both bands, wrapping the housing on the left and right.
    case around

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hanging: return "Hanging"
        case .sideways: return "Sideways"
        case .around: return "Around"
        }
    }
}

struct AppPreferences: Codable, Equatable {
    var notificationsEnabled = true
    var dndEnabled = false
    var lowQuotaThreshold = 0.20
    var notificationCooldownMinutes = 90
    var menuBarMode = MenuBarDisplayMode.smart
    var menuBarDensity = MenuBarDensity.comfortable
    /// Which providers `MenuBarDisplayMode.pinned` shows, in the order they are shown. Empty
    /// means the mode has nothing to draw, so the readout falls back to Smart rather than
    /// leaving an empty status item behind.
    var menuBarPinnedProviders: [Provider] = [.claudeCode, .codex]
    // 30 days by default so the usage heatmap can fill its full window; it renders
    // min(30, retention), so a shorter retention silently shortens the chart.
    var historyRetentionDays = 30
    var sessionWarningThreshold = 0.15
    /// Shows the recommendation/AI summary card at the top of the main panel.
    var aiInsightEnabled = true
    /// Shows the provider availability rings in the Accounts panel. The standalone macOS
    /// widget is independently opt-in through the system widget gallery.
    var quotaRingsEnabled = true
    /// Experimental: render the status readout at the display notch instead of the menu bar.
    /// Off by default - it relocates the whole app, so it is opt-in.
    var notchModeEnabled = false
    var notchPlacement = NotchPlacement.hanging
    /// Whether Toki may read the Claude Code sign-in out of the Keychain, which puts up the
    /// system's Keychain dialog. Off until the setup checklist asks for it, so a fresh install
    /// doesn't raise that dialog just because someone opened the menu.
    var keychainReadsApproved = false
    /// Set the first time Toki launches with nothing configured. It keeps the first-run checklist
    /// on screen after an account is connected - which is when onboarding ends and the permissions
    /// start mattering - without showing it to an install that was already set up.
    var setupChecklistStarted = false
    /// Set once the setup checklist has been worked through, so it stops taking up the panel.
    var setupChecklistCompleted = false

    enum CodingKeys: String, CodingKey {
        case notificationsEnabled
        case dndEnabled
        case lowQuotaThreshold
        case notificationCooldownMinutes
        case menuBarMode
        case menuBarDensity
        case menuBarPinnedProviders
        case historyRetentionDays
        case sessionWarningThreshold
        case aiInsightEnabled
        case quotaRingsEnabled
        case notchModeEnabled
        case notchPlacement
        case keychainReadsApproved
        case setupChecklistStarted
        case setupChecklistCompleted
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
        // Decoded as a raw string rather than as MenuBarDisplayMode so that a retired mode
        // written by an older build maps onto its replacement instead of throwing, which
        // would take the whole state file down with it.
        let storedMode = try container.decodeIfPresent(String.self, forKey: .menuBarMode)
            .flatMap(MenuBarDisplayMode.stored(rawValue:))
        menuBarMode = storedMode?.mode ?? defaults.menuBarMode
        menuBarDensity = try container.decodeIfPresent(MenuBarDensity.self, forKey: .menuBarDensity) ?? defaults.menuBarDensity
        // Unrecognised provider names are dropped rather than thrown on, so a state file
        // written by a newer build that knows more providers still loads here.
        let migratedPins = storedMode?.pinned ?? []
        menuBarPinnedProviders = try container.decodeIfPresent([String].self, forKey: .menuBarPinnedProviders)
            .map { $0.compactMap(Provider.init(rawValue:)) }
            ?? (migratedPins.isEmpty ? defaults.menuBarPinnedProviders : migratedPins)
        historyRetentionDays = try container.decodeIfPresent(Int.self, forKey: .historyRetentionDays) ?? defaults.historyRetentionDays
        sessionWarningThreshold = try container.decodeIfPresent(Double.self, forKey: .sessionWarningThreshold) ?? defaults.sessionWarningThreshold
        aiInsightEnabled = try container.decodeIfPresent(Bool.self, forKey: .aiInsightEnabled) ?? defaults.aiInsightEnabled
        quotaRingsEnabled = try container.decodeIfPresent(Bool.self, forKey: .quotaRingsEnabled) ?? defaults.quotaRingsEnabled
        notchModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .notchModeEnabled) ?? defaults.notchModeEnabled
        notchPlacement = try container.decodeIfPresent(NotchPlacement.self, forKey: .notchPlacement) ?? defaults.notchPlacement
        keychainReadsApproved = try container.decodeIfPresent(Bool.self, forKey: .keychainReadsApproved) ?? defaults.keychainReadsApproved
        setupChecklistStarted = try container.decodeIfPresent(Bool.self, forKey: .setupChecklistStarted) ?? defaults.setupChecklistStarted
        setupChecklistCompleted = try container.decodeIfPresent(Bool.self, forKey: .setupChecklistCompleted) ?? defaults.setupChecklistCompleted
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
