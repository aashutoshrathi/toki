import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshots: [AccountSnapshot] = []
    @Published var lastUpdated: Date?
    @Published var configError: String?
    @Published var debugMode = false
    // Masks emails and org identifiers across the UI so screenshots and demos can be shared
    // without leaking PII. Transient by design - it resets on relaunch so the app never
    // quietly stays redacted.
    @Published var hidesSensitiveInfo = false
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
    @Published private(set) var isNetworkAvailable = true

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
    // Published: the Agents panel's refresh button shows a spinner and disables itself off this.
    @Published var isScanningAgents = false
    // Published: the heatmap shows a loading state off this, so the view has to observe it.
    @Published var isScanningActivity = false
    var dailyActivityScannedAt: Date?
    var eventGeneration = 0
    var insightGeneration = 0
    var notificationAuthorization: Bool?
    var agentTimer: Timer?
    let connectivityMonitor = ConnectivityMonitor()
    var connectivityGeneration = 0
    var refreshAfterReconnect = false

    init() {
        reloadConfig()
        refreshActiveAgents()
        agentTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshActiveAgents() }
        }
        connectivityMonitor.start { [weak self] isAvailable in
            Task { @MainActor [weak self] in
                self?.connectivityDidChange(isAvailable: isAvailable)
            }
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

    func connectivityDidChange(isAvailable: Bool) {
        guard isNetworkAvailable != isAvailable else { return }
        isNetworkAvailable = isAvailable
        connectivityGeneration &+= 1

        if !isAvailable {
            logDebug("Internet connection unavailable - keeping last successful usage")
            DiagnosticLogger.shared.record(.info, component: "connectivity", code: "offline")
            return
        }

        logDebug("Internet connection restored - refreshing usage")
        DiagnosticLogger.shared.record(.info, component: "connectivity", code: "restored")
        if isRefreshing {
            refreshAfterReconnect = true
        } else {
            refresh(keepsExistingSnapshots: true, minimumRefreshInterval: 0)
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
        // Remember that this install started from nothing, so the first-run checklist can survive
        // connecting an account - that is the moment onboarding ends and the permissions the app
        // actually needs start mattering. An existing install never sets this and never sees it;
        // its checklist lives in Settings.
        if value, !preferences.setupChecklistStarted {
            var next = preferences
            next.setupChecklistStarted = true
            updatePreferences(next)
        }
    }
}
