import SwiftUI

struct MenuContentView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updateChecker: UpdateChecker
    @State private var selectedTab: TokiTab = .accounts

    private enum TokiTab: String, CaseIterable, Identifiable {
        case accounts = "Accounts"
        case history = "History"
        case events = "Events"
        case agents = "Agents"
        case settings = "Settings"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .accounts: return "person.2"
            case .history: return "chart.line.uptrend.xyaxis"
            case .events: return "bell.badge"
            case .agents: return "terminal"
            case .settings: return "slider.horizontal.3"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let update = updateChecker.availableUpdate {
                updateBanner(update)
            }
            overview
            sessionPanel
            tabBar
            if let configError = store.configError {
                ErrorBanner(message: configError)
            }
            tabContent

            if store.debugMode {
                debugPanel
            }
        }
        .padding(12)
        .frame(width: popoverWidth(), height: popoverHeight(), alignment: .top)
        .background(.regularMaterial)
    }

    private func updateBanner(_ update: AvailableUpdate) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Toki \(update.version) is available")
                        .font(.system(size: 11, weight: .semibold))
                    Text(updateChecker.isInstalling ? "Downloading and verifying update…" : "Install the latest GitHub release.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    updateChecker.installUpdate()
                } label: {
                    if updateChecker.isInstalling {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Update")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(updateChecker.isInstalling)

                Button {
                    updateChecker.dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Dismiss this version")
                .accessibilityLabel("Dismiss update notification")
            }

            if let error = updateChecker.installError {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.blue.opacity(0.28), lineWidth: 1)
        )
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
                store.refresh(minimumRefreshInterval: 60)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 25, height: 25)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .help("Refresh")
            .pointerOnHover()

            Button {
                ConfigLoader.openInDefaultEditor()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 25, height: 25)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .help("Open config")
            .pointerOnHover()

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 25, height: 25)
            .foregroundStyle(.red)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.red.opacity(0.42), lineWidth: 1)
            )
            .help("Quit")
            .pointerOnHover()
        }
    }

    private var overview: some View {
        HStack(spacing: 8) {
            StatBlock(title: "Use", value: recommendedAgentText, systemImage: "sparkles", action: smartSwitchAction)
                .help("Recommended account")
            StatBlock(title: "Lowest", value: lowestRemainingText, systemImage: "gauge.with.dots.needle.bottom.50percent")
            StatBlock(title: "Status", value: store.preferences.dndEnabled ? "DND" : "Ready", systemImage: store.preferences.dndEnabled ? "moon.zzz" : "bell")
        }
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

    private var lowestRemainingText: String {
        guard let ratio = store.snapshots.compactMap(\.remainingRatio).min() else { return "--" }
        return percentText(ratio)
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

    private var sessionPanel: some View {
        HStack(spacing: 8) {
            Image(systemName: store.session == nil ? "timer" : "timer.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(store.session == nil ? Color.secondary : Color.blue)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.session == nil ? "Session mode" : "Session active")
                    .font(.system(size: 11, weight: .semibold))
                Text(sessionDetail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                store.session == nil ? store.startSession() : store.endSession()
            } label: {
                Image(systemName: store.session == nil ? "play.fill" : "stop.fill")
            }
            .buttonStyle(.plain)
            .frame(width: 25, height: 25)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .help(store.session == nil ? "Start session tracking" : "End session tracking")
            .accessibilityLabel(store.session == nil ? "Start session tracking" : "End session tracking")
            .pointerOnHover()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
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
        case .history:
            HistoryPanel(store: store)
        case .events:
            EventPanel(store: store)
        case .agents:
            ActiveAgentsPanel(store: store)
        case .settings:
            SettingsPanel(store: store, updateChecker: updateChecker)
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

    private var sessionDetail: String {
        guard let session = store.session else {
            return "Track burn rate while you work."
        }
        let elapsed = formatDuration(seconds: Date().timeIntervalSince(session.startedAt))
        let lines = store.sessionBurnLines()
        guard let first = lines.first else {
            return "Running for \(elapsed)."
        }
        return "\(elapsed), \(first.value)"
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
