import SwiftUI

struct MenuContentView: View {
    @ObservedObject var store: UsageStore
    @State private var selectedTab: TokiTab = .accounts

    private enum TokiTab: String, CaseIterable, Identifiable {
        case accounts = "Accounts"
        case history = "History"
        case events = "Events"
        case settings = "Settings"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .accounts: return "person.2"
            case .history: return "chart.line.uptrend.xyaxis"
            case .events: return "bell.badge"
            case .settings: return "slider.horizontal.3"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            overview
            recommendationPanel
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
            StatBlock(title: "Accounts", value: "\(store.snapshots.count)", systemImage: "person.2")
            StatBlock(title: "Lowest", value: lowestRemainingText, systemImage: "gauge.with.dots.needle.bottom.50percent")
            StatBlock(title: store.preferences.dndEnabled ? "DND" : "Alerts", value: store.preferences.dndEnabled ? "On" : "Ready", systemImage: store.preferences.dndEnabled ? "moon.zzz" : "bell")
        }
    }

    private var lowestRemainingText: String {
        guard let ratio = store.snapshots.compactMap(\.remainingRatio).min() else { return "--" }
        return "\(Int((ratio * 100).rounded()))%"
    }

    private var recommendationPanel: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: recommendationIcon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(recommendationColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.recommendation.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(store.recommendation.detail)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if store.recommendation.switchTarget != nil {
                Button {
                    store.switchBestAccount()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.plain)
                .frame(width: 25, height: 25)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .help("Switch to recommended Claude account")
                .pointerOnHover()
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(recommendationColor.opacity(0.25), lineWidth: 1)
        )
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
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .frame(height: 28)
                .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                .background(selectedTab == tab ? Color.primary.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .help(tab.rawValue)
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
        case .settings:
            SettingsPanel(store: store)
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

    private var recommendationIcon: String {
        switch store.recommendation.severity {
        case .good: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        case .neutral: return "sparkles"
        }
    }

    private var recommendationColor: Color {
        switch store.recommendation.severity {
        case .good: return .green
        case .warning: return .orange
        case .critical: return .red
        case .neutral: return .blue
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
