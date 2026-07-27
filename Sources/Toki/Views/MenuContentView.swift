import SwiftUI

struct MenuContentView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updateChecker: UpdateChecker
    @State private var selectedTab: TokiTab = .accounts
    @State private var showConfig = false
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
                ConfigPage(store: store, updateChecker: updateChecker) { showConfig = false }
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
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 6)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            VStack(spacing: 0) {
                functionalBar
                    .padding(.horizontal, 12)
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
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var functionalBar: some View {
        HStack(alignment: .center, spacing: 7) {
            TokiLogoMark(size: 22)

            Text("/toki")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .fixedSize()
                .onTapGesture(count: 5) {
                    store.toggleDebug()
                }

            Spacer(minLength: 0)
            headerControls
        }
        .padding(6)
        .functionalGlass()
    }

    private var headerControls: some View {
        HStack(spacing: 5) {
            // Same reasoning as the Agents panel's refresh: without a visible busy state the
            // button looks identical before, during and after a refresh, so a press that is
            // already running reads as one that did nothing and invites another - and the
            // store drops overlapping refreshes, so those presses go nowhere.
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
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
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
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(store.hidesSensitiveInfo ? Color.blue : Color.primary)
            .help(store.hidesSensitiveInfo ? "Showing masked emails and org info - click to reveal" : "Hide emails and org info for screenshots")
            .accessibilityLabel(store.hidesSensitiveInfo ? "Reveal sensitive info" : "Hide sensitive info")
            .pointerOnHover()

            Button {
                showConfig = true
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .pointerOnHover()

            Menu {
                Button("Version \(appVersion)") {}
                    .disabled(true)

                Divider()

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
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More actions")
            .pointerOnHover()
        }
        .font(.system(size: 13, weight: .semibold))
        .controlSize(.small)
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
                .foregroundStyle(selectedTab == tab ? Color.white : Color.secondary)
                .background(
                    selectedTab == tab ? Color.accentColor : Color.clear,
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
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel("Toki section")
    }

    private var tabContent: some View {
        Group {
            switch selectedTab {
            case .accounts:
                accountList
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
        store.snapshots.sorted { a, b in
            let aPriority = accountSortPriority(a)
            let bPriority = accountSortPriority(b)
            if aPriority != bPriority { return aPriority < bPriority }
            return false // stable within groups
        }
    }

    private func accountSortPriority(_ snapshot: AccountSnapshot) -> Int {
        if snapshot.isError { return 2 }
        if let ratio = snapshot.remainingRatio, ratio <= 0 { return 1 }
        return 0
    }

    private var accountList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if showsQuotaRings {
                        QuotaRingsPanel(snapshots: store.snapshots) {
                            var next = store.preferences
                            next.quotaRingsEnabled = false
                            store.updatePreferences(next)
                        }

                        Divider()
                            .padding(.leading, 44)
                    }

                    ForEach(Array(sortedSnapshots.enumerated()), id: \.element.id) { index, snapshot in
                        AccountCard(snapshot: snapshot, store: store) { id in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                    proxy.scrollTo(id, anchor: .top)
                                }
                            }
                        }
                        .id(snapshot.id)
                        .transition(.move(edge: .top).combined(with: .opacity))

                        if index < sortedSnapshots.count - 1 {
                            Divider()
                                .padding(.leading, 44)
                        }
                    }
                }
                .padding(.horizontal, 2)
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: store.snapshots.map(\.id))
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}
