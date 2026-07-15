import SwiftUI

struct MenuContentView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updateChecker: UpdateChecker
    @State private var selectedTab: TokiTab = .accounts
    @State private var showConfig = false
    @State private var showAddAccount = false

    private enum TokiTab: String, CaseIterable, Identifiable {
        case accounts = "Accounts"
        case agents = "Agents"
        case events = "Events"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .accounts: return "person.2"
            case .events: return "bell.badge"
            case .agents: return "terminal"
            }
        }
    }

    var body: some View {
        Group {
            if showConfig {
                ConfigPage(store: store, updateChecker: updateChecker) { showConfig = false }
            } else if showAddAccount {
                AddAccountPage(store: store, onClose: { showAddAccount = false }) {
                    showAddAccount = false
                    showConfig = true
                }
            } else {
                mainContent
            }
        }
        .frame(width: popoverWidth(), height: popoverHeight(), alignment: .top)
        .background(.regularMaterial)
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let update = updateChecker.availableUpdate {
                UpdateAvailableBanner(update: update, updateChecker: updateChecker)
            }
            if let session = store.session {
                SessionRecordingCard(startedAt: session.startedAt)
            }
            if store.needsOnboarding {
                OnboardingView(store: store) { showConfig = true }
            } else {
                overview
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
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 9) {
            TokiLogoMark(size: 34)
                .padding(5)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("/toki")
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    Text("v\(appVersion)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                        .onTapGesture(count: 5) {
                            store.toggleDebug()
                        }
                }
            }
            Spacer()
            headerControls
        }
    }

    private var headerControls: some View {
        HStack(spacing: 5) {
            Button {
                store.session == nil ? store.startSession() : store.endSession()
            } label: {
                Image(systemName: store.session == nil ? "play.fill" : "stop.fill")
                    .frame(width: 25, height: 25)
                    .background((store.session == nil ? Color.primary : Color.blue).opacity(store.session == nil ? 0.06 : 0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(store.session == nil ? Color.primary : Color.blue)
            .help(store.session == nil ? "Start session tracking" : "End session tracking")
            .accessibilityLabel(store.session == nil ? "Start session tracking" : "End session tracking")
            .pointerOnHover()

            Button {
                store.refresh(minimumRefreshInterval: 60)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 25, height: 25)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .help("Refresh")
            .pointerOnHover()

            Button {
                showAddAccount = true
            } label: {
                Image(systemName: "plus")
                    .overlay(alignment: .topTrailing) {
                        if !store.addableProviders.isEmpty {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 6, height: 6)
                                .offset(x: 7, y: -7)
                        }
                    }
                    .frame(width: 25, height: 25)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .disabled(store.addableProviders.isEmpty)
            .help(store.addableProviders.isEmpty ? "No new providers detected" : "Add account - new provider detected")
            .accessibilityLabel("Add account")
            .pointerOnHover()

            Button {
                showConfig = true
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 25, height: 25)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .help("Settings")
            .pointerOnHover()

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .frame(width: 25, height: 25)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.red.opacity(0.42), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.red)
            .help("Quit")
            .pointerOnHover()
        }
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
        HStack(spacing: 4) {
            ForEach(TokiTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Image(systemName: tab.systemImage)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .background(selectedTab == tab ? Color.primary.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                .help(tab.rawValue)
                .accessibilityLabel(tab.rawValue)
                .pointerOnHover()
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .accounts:
            accountList
        case .events:
            EventPanel(store: store)
        case .agents:
            ActiveAgentsPanel(store: store)
        }
    }

    private var accountList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(store.snapshots) { snapshot in
                        AccountCard(snapshot: snapshot, store: store) { id in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                    proxy.scrollTo(id, anchor: .top)
                                }
                            }
                        }
                        .id(snapshot.id)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.trailing, 2)
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: store.snapshots.map(\.id))
            }
            .frame(maxHeight: accountListHeight())
        }
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
