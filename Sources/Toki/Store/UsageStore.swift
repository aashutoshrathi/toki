import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshots: [AccountSnapshot] = []
    @Published var lastUpdated: Date?
    @Published var configError: String?
    @Published var debugMode = false
    @Published var debugLog: [DebugLogEntry] = []
    @Published var preferences = AppPreferences()
    @Published var events: [TokiEvent] = []
    @Published var history: [UsageHistoryEntry] = []
    @Published var session: SessionState?
    @Published var activeAgents: [ActiveAgent] = []
    @Published var dailyActivity: [DailyActivity] = []
    /// Providers whose session history could not be read on the last scan.
    @Published var unreadableActivityProviders: [Provider] = []
    @Published var aiInsight: UsageInsight?
    @Published var isGeneratingInsight = false
    @Published var recommendation = SmartRecommendation(
        title: "Loading",
        detail: "Checking account quota.",
        accountID: nil,
        switchTarget: nil,
        switchCommand: nil,
        severity: .neutral
    )
    @Published var statusEntries: [MenuBarStatusEntry] = menuBarPlaceholderEntries()
    @Published var detectedProviders: [DetectedProvider] = []
    @Published var isScanningProviders = false
    @Published private(set) var needsOnboarding = false
    @Published var resettingAccountIDs: Set<String> = []

    // Not private(set): these are written from UsageStore+*.swift extensions in other
    // files, and Swift's `private`/`private(set)` is scoped to the declaring file, not
    // the type - a same-type extension in a different file can't assign through it.
    // Nothing outside UsageStore reads or writes these; the boundary is convention here,
    // not the compiler.
    var config: AppConfig?
    var usageState = UsageState()
    var timer: Timer?
    // Published: the header refresh button shows a spinner and disables itself off this.
    @Published var isRefreshing = false
    // Published: the refresh button shows a spinner and disables itself off this.
    @Published var isScanningAgents = false
    // Published: the heatmap shows a loading state off this, so the view has to observe it.
    @Published var isScanningActivity = false
    var dailyActivityScannedAt: Date?
    var eventGeneration = 0
    var insightGeneration = 0
    var notificationAuthorization: Bool?
    var agentTimer: Timer?

    init() {
        reloadConfig()
        refreshActiveAgents()
        agentTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshActiveAgents() }
        }
    }

    var refreshInterval: TimeInterval {
        TimeInterval(max(config?.refreshMinutes ?? 5, 1) * 60)
    }

    func scheduleRefresh() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(keepsExistingSnapshots: true) }
        }
    }

    func syncPublishedState() {
        preferences = usageState.preferences
        events = usageState.events.sorted { $0.timestamp > $1.timestamp }
        history = usageState.history.sorted { $0.timestamp > $1.timestamp }
        session = usageState.session
    }

    func setNeedsOnboarding(_ value: Bool) {
        needsOnboarding = value
    }
}
