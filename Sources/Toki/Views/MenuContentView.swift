import SwiftUI

struct MenuContentView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updateChecker: UpdateChecker
    @ObservedObject private var remoteServer = RemoteControlServer.shared
    @State private var selectedTab: TokiTab = .accounts
    @State private var showConfig = false
    @State private var focusRemoteControlSettings = false
    @State private var showChangelog = false

    private enum TokiTab: String, CaseIterable, Identifiable {
        case accounts = "Accounts"
        case agents = "Agents"
        case analytics = "Analytics"
        case events = "Events"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .accounts: return "person.crop.circle"
            case .events: return "bell.badge"
            case .agents: return "terminal"
            case .analytics: return "chart.bar.xaxis"
            }
        }
    }

    var body: some View {
        Group {
            if showConfig {
                ConfigPage(
                    store: store,
                    updateChecker: updateChecker,
                    focusRemoteControl: focusRemoteControlSettings
                ) {
                    showConfig = false
                }
            } else if showChangelog {
                ChangelogPage { showChangelog = false }
            } else {
                mainContent
            }
        }
        // Keep the popover frame stable while switching tabs. Allowing the hosting controller to
        // follow each tab's preferred height makes AppKit re-anchor the panel while the menu bar
        // auto-hides, which can move the entire popover to the left edge of the screen.
        .frame(width: popoverWidth(), height: popoverHeight(), alignment: .top)
    }

    @ViewBuilder
    private var mainContent: some View {
        if #available(macOS 26, *) {
            contentBody
                .safeAreaBar(edge: .top, spacing: 0) {
                    functionalBar
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                        .padding(.bottom, 6)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            VStack(spacing: 0) {
                functionalBar
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                contentBody
            }
        }
    }

    private var contentBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let update = updateChecker.availableUpdate {
                UpdateAvailableBanner(update: update, updateChecker: updateChecker)
            }
            if let session = store.session {
                SessionRecordingCard(startedAt: session.startedAt)
            }
            if store.needsOnboarding {
                OnboardingView(store: store) { showConfig = true }
            } else {
                // Connecting an account ends onboarding but not setup: the permissions Toki needs
                // to actually be useful are still unanswered, so the first-run checklist stays
                // until it is worked through or put away. Only for an install that started from
                // nothing - an existing one finds the same list in Settings.
                if store.preferences.setupChecklistStarted, !store.preferences.setupChecklistCompleted {
                    SetupChecklistView(store: store, mode: .firstRun, showsDismiss: true)
                        .padding(10)
                        .contentSurface()
                }
                if store.preferences.aiInsightEnabled {
                    overview
                }
                tabBar
                if let configError = store.configError {
                    ErrorBanner(message: configError)
                }
                tabContent
            }

            if store.debugMode {
                debugPanel
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var functionalBar: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 0) {
                functionalBarContents
            }
        } else {
            functionalBarContents
        }
    }

    private var functionalBarContents: some View {
        HStack(alignment: .center, spacing: 7) {
            TokiLogoMark(size: 28)
                .accessibilityHidden(true)

            Text("/toki")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .fixedSize()

            Text("v\(appVersion)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .functionalGlass(in: Capsule(), interactive: true)
                .accessibilityLabel("Toki version \(appVersion)")
                .onTapGesture(count: 7) {
                    store.toggleDebug()
                }

            Spacer(minLength: 0)
            headerControls
        }
        .frame(height: 28)
    }

    private var headerControls: some View {
        HStack(spacing: 8) {
            if remoteServer.isRunning {
                Button {
                    focusRemoteControlSettings = true
                    showConfig = true
                } label: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .functionalControlStyle()
                .foregroundStyle(Color.teal)
                .help("Remote Control is on — open its Settings")
                .accessibilityLabel("Remote Control is on. Open Remote Control Settings")
                .pointerOnHover()
            }

            HStack(spacing: 5) {
                Button {
                    store.refresh(minimumRefreshInterval: 60)
                } label: {
                    Group {
                        if store.isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                        } else if !store.isNetworkAvailable {
                            Image(systemName: "wifi.slash")
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                }
                .functionalControlStyle()
                .disabled(store.isRefreshing || !store.isNetworkAvailable)
                .help(
                    store.isRefreshing
                        ? "Refreshing…"
                        : (store.isNetworkAvailable
                            ? "Refresh"
                            : "Offline — usage refreshes automatically when the connection returns")
                )
                .pointerOnHover()

                Button {
                    store.hidesSensitiveInfo.toggle()
                } label: {
                    Image(systemName: store.hidesSensitiveInfo ? "eye.slash" : "eye")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .functionalControlStyle()
                .foregroundStyle(store.hidesSensitiveInfo ? Color.blue : Color.primary)
                .help(store.hidesSensitiveInfo ? "Showing masked emails and org info - click to reveal" : "Hide emails and org info for screenshots")
                .accessibilityLabel(store.hidesSensitiveInfo ? "Reveal sensitive info" : "Hide sensitive info")
                .pointerOnHover()
            }

            HStack(spacing: 5) {
                Button {
                    focusRemoteControlSettings = false
                    showConfig = true
                } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .functionalControlStyle()
                .help("Settings")
                .pointerOnHover()

                Menu {
                    Button {
                        showChangelog = true
                    } label: {
                        Label("What's New", systemImage: "doc.text")
                    }

                    Divider()

                    Button(role: .destructive) {
                        NSApp.terminate(nil)
                    } label: {
                        Label("Quit Toki", systemImage: "power")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .functionalControlStyle()
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                .accessibilityLabel("More actions")
                .pointerOnHover()
            }
        }
        .font(.system(size: 13, weight: .semibold))
    }

    private var overview: some View {
        AIInsightCard(
            summary: store.aiInsight?.summary ?? "\(store.recommendation.title) - \(store.recommendation.detail)",
            suggestions: store.aiInsight?.suggestions ?? [],
            isAI: store.aiInsight != nil,
            isUpdating: store.isGeneratingInsight,
            switchAction: smartSwitchAction
        )
    }

    private var smartSwitchAction: StatBlockAction? {
        guard store.recommendation.switchTarget != nil else { return nil }
        return StatBlockAction(
            systemImage: "arrow.triangle.2.circlepath",
            help: "Switch Claude Code to \(recommendedAgentText)"
        ) {
            store.switchBestAccount()
        }
    }

    private var recommendedAgentText: String {
        if let accountID = store.recommendation.accountID,
           let snapshot = store.snapshots.first(where: { $0.id == accountID }) {
            return snapshot.name
        }

        if store.recommendation.title == "Connect an account" {
            return "Connect"
        }

        return store.recommendation.title
            .replacingOccurrences(of: "Use ", with: "")
            .replacingOccurrences(of: "Switch to ", with: "")
            .replacingOccurrences(of: " now", with: "")
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(TokiTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Image(systemName: tab.systemImage)
                    .overlay(alignment: .topTrailing) {
                        if tab == .agents, !store.activeAgents.isEmpty {
                            let blocked = store.activeAgents.filter(\.needsInput).count
                            Text("\(blocked > 0 ? blocked : store.activeAgents.count)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(2)
                                .frame(minWidth: 12, minHeight: 12)
                                .background(blocked > 0 ? Color.red : Color.blue, in: Circle())
                                .offset(x: 8, y: -6)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 26)
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedTab == tab ? Color.primary : Color.secondary)
                .background(
                    selectedTab == tab ? Color.accentColor.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .help(tab.rawValue)
                .accessibilityLabel(tab.rawValue)
                .accessibilityValue(selectedTab == tab ? "Selected" : "")
                .pointerOnHover()
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel("Toki section")
    }

    private var tabContent: some View {
        Group {
            switch selectedTab {
            case .accounts:
                accountsContent
            case .agents:
                ActiveAgentsPanel(store: store)
            case .analytics:
                SpendAnalyticsPanel(store: store)
            case .events:
                EventPanel(store: store)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // Active accounts first, then exhausted (0% remaining), then errored/not connected.
    private var sortedSnapshots: [AccountSnapshot] {
        let order = Dictionary(store.snapshots.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return store.snapshots.sorted { a, b in
            let aPriority = accountSortPriority(a)
            let bPriority = accountSortPriority(b)
            if aPriority != bPriority { return aPriority < bPriority }
            let aActivity = latestActivity(for: a)
            let bActivity = latestActivity(for: b)
            if aActivity != bActivity {
                return (aActivity ?? .distantPast) > (bActivity ?? .distantPast)
            }
            return (order[a.id] ?? 0) < (order[b.id] ?? 0)
        }
    }

    private func latestActivity(for snapshot: AccountSnapshot) -> Date? {
        let agentActivity = store.activeAgents
            .filter { $0.provider == snapshot.provider }
            .compactMap { $0.lastActivity }
            .max()
        return [agentActivity, snapshot.lastActivity].compactMap { $0 }.max()
    }

    private func accountSortPriority(_ snapshot: AccountSnapshot) -> Int {
        if snapshot.isError { return 2 }
        if let ratio = snapshot.remainingRatio, ratio <= 0 { return 1 }
        return 0
    }

    private var accountsContent: some View {
        VStack(spacing: 0) {
            if showsQuotaRings {
                QuotaRingsPanel(snapshots: store.snapshots) {
                    var next = store.preferences
                    next.quotaRingsEnabled = false
                    store.updatePreferences(next)
                }

                Divider()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 2)
            }

            accountList
        }
    }

    private var accountList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                let snapshots = sortedSnapshots
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, snapshot in
                        AccountCard(snapshot: snapshot, store: store) { id in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                    proxy.scrollTo(id, anchor: .top)
                                }
                            }
                        }
                        .id(snapshot.id)

                        if index < snapshots.count - 1 {
                            Divider()
                                .padding(.horizontal, 10)
                                .padding(.vertical, 2)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var showsQuotaRings: Bool {
        store.preferences.quotaRingsEnabled
            && selectedTab == .accounts
            && store.snapshots.contains(where: { !$0.isError && $0.remainingRatio != nil })
    }

    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "ant.fill")
                    .foregroundStyle(.orange)
                Text("Debug")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                Spacer()
                Button("Clear") {
                    store.debugLog.removeAll()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .pointerOnHover()
            }
            if store.debugLog.isEmpty {
                Text("No log entries")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(store.debugLog) { entry in
                            HStack(spacing: 6) {
                                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Text(entry.message)
                                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
        .padding(8)
        .contentSurface(stroke: .orange)
    }
}
