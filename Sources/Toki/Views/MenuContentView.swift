import SwiftUI

struct MenuContentView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updateChecker: UpdateChecker
    @ObservedObject private var remoteServer = RemoteControlServer.shared
    @ObservedObject var presentation: PopoverPresentationState
    var onDismiss: () -> Void
    var onFinishQuit: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showMoreActions = false
    @State private var hoveredMoreAction: String?

    var body: some View {
        Group {
            switch presentation.page {
            case .settings:
                ConfigPage(
                    store: store,
                    updateChecker: updateChecker,
                    navigation: presentation.settings
                ) { presentation.page = .main }
            case .changelog:
                ChangelogPage { presentation.page = .main }
            case .main:
                mainContent
            }
        }
        .disabled(presentation.confirmingQuit)
        .accessibilityHidden(presentation.confirmingQuit)
        // Keep the popover frame stable while switching tabs. Allowing the hosting controller to
        // follow each tab's preferred height makes AppKit re-anchor the panel while the menu bar
        // auto-hides, which can move the entire popover to the left edge of the screen.
        .frame(width: popoverWidth(), height: presentation.contentHeight, alignment: .top)
        .onExitCommand {
            if presentation.confirmingQuit { onFinishQuit(false) }
            else if !presentation.goBack() { onDismiss() }
        }
        .onChange(of: store.snapshots.map(\.id)) { _, ids in
            presentation.retainPresentAccounts(ids)
        }
        .overlay {
            if presentation.confirmingQuit { quitConfirmation }
        }
    }

    private var quitConfirmation: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            VStack(alignment: .leading, spacing: 16) {
                Text("Save changes before quitting?").font(TokiTypography.heading)
                Text("Your configuration or AI instructions have unsaved changes.")
                    .font(TokiTypography.body)
                Button("Save and Quit") {
                    onFinishQuit(presentation.settings.saveDrafts(store: store))
                }
                .buttonStyle(.borderedProminent)
                Button("Discard and Quit", role: .destructive) {
                    presentation.settings.discardDrafts()
                    onFinishQuit(true)
                }
                Button("Cancel", role: .cancel) { onFinishQuit(false) }
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.large)
            .padding(24)
        }
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
                // Nothing else is on screen during onboarding, so this is the one place the body
                // itself can scroll without nesting inside a tab's own scroll view.
                ScrollView(.vertical) {
                    OnboardingView(store: store) { presentation.openConfigEditor() }
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                if store.preferences.setupChecklistStarted, !store.preferences.setupChecklistCompleted {
                    HStack {
                        Button("Finish optional setup") {
                            presentation.settings.openPermissions()
                            presentation.page = .settings
                        }
                            .buttonStyle(.borderless)
                        Spacer()
                        Button("Dismiss") { store.completeSetupChecklist() }
                            .buttonStyle(.borderless)
                    }
                    .font(TokiTypography.supporting)
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.fill.tertiary, in: Capsule())
                .accessibilityLabel("Toki version \(appVersion)")
                .onTapGesture(count: 7) {
                    store.toggleDebug()
                }

            if let prerelease = prereleaseBadge(for: UpdateChecker.installedVersion) {
                Text(prerelease)
                    .font(.system(size: 8, weight: .heavy))
                    .tracking(0.4)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.45, green: 0.35, blue: 0.95),
                                     Color(red: 0.85, green: 0.35, blue: 0.65)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: Capsule()
                    )
                    .fixedSize()
                    .help("You are on a prerelease build")
                    .accessibilityLabel("Prerelease build, \(prerelease)")
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
                    presentation.openSettings(remoteControl: true)
                } label: {
                    Image(systemName: "arcade.stick")
                        .frame(width: 13, height: 13)
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
                    .frame(width: 13, height: 13)
                    .contentShape(Rectangle())
                }
                .functionalControlStyle()
                .disabled(store.isRefreshing || !store.isNetworkAvailable)
                .accessibilityLabel(store.isRefreshing ? "Refreshing" : "Refresh usage")
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
                        .frame(width: 13, height: 13)
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
                    presentation.openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 13, height: 13)
                        .contentShape(Rectangle())
                }
                .functionalControlStyle()
                .help("Settings (⌘,)")
                .accessibilityLabel("Settings")
                .pointerOnHover()

                // A popover rather than a Menu: SwiftUI hands a Menu's rows to AppKit as
                // NSMenuItems, which keep the arrow cursor and the system highlight, so the
                // rows here could not pick up the pointer and hover treatment every other
                // control in this panel has.
                Button {
                    showMoreActions.toggle()
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 13, height: 13)
                        .contentShape(Rectangle())
                }
                .functionalControlStyle()
                .help("More")
                .accessibilityLabel("More actions")
                .pointerOnHover()
                .popover(isPresented: $showMoreActions, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        moreActionRow(title: "What's New", icon: "doc.text") {
                            presentation.page = .changelog
                        }
                        Divider()
                            .padding(.horizontal, 6)
                        moreActionRow(title: "Quit Toki", icon: "power", isDestructive: true) {
                            NSApp.terminate(nil)
                        }
                    }
                    .padding(6)
                    .frame(width: 170)
                }
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
                    presentation.select(tab)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 13, weight: .medium))
                            .overlay(alignment: .topTrailing) {
                                let blocked = store.activeAgents.filter(\.needsInput).count
                                if tab == .agents, blocked > 0 {
                                    Text("\(blocked)")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 4)
                                        .background(Color.red, in: Capsule())
                                        .offset(x: 10, y: -6)
                                        .accessibilityLabel("\(blocked) agents need input")
                                }
                            }
                        Text(tab.rawValue).font(TokiTypography.supporting)
                    }
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(presentation.selectedTab == tab ? Color.primary : Color.secondary)
                .background(
                    presentation.selectedTab == tab ? Color.accentColor.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .help(tab.rawValue)
                .accessibilityLabel(tab.rawValue)
                .accessibilityValue(presentation.selectedTab == tab ? "Selected" : "")
                .pointerOnHover()
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity)
        .functionalGlass(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel("Toki section")
    }

    private var tabContent: some View {
        Group {
            switch presentation.selectedTab {
            case .accounts:
                accountsContent
            case .agents:
                ActiveAgentsPanel(store: store, presentation: presentation.accounts)
            case .analytics:
                SpendAnalyticsPanel(store: store, presentation: presentation.analytics)
            case .events:
                EventPanel(store: store, presentation: presentation.events)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var sortedSnapshots: [AccountSnapshot] {
        let byID = Dictionary(store.snapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = PopoverPresentationState.reconciledOrder(presentation.accountOrder, presentIDs: store.snapshots.map(\.id))
        return ids.compactMap { byID[$0] }
    }

    private var accountsContent: some View {
        VStack(spacing: 0) {
            if showsQuotaRings {
                QuotaRingsPanel(
                    snapshots: store.snapshots,
                    quotaWindows: store.preferences.quotaDisplayWindows,
                    presentation: presentation.accounts
                ) {
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
                        AccountCard(snapshot: snapshot, store: store, presentation: presentation.accounts) { id in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                                    presentation.accountScrollID = id
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
                .scrollTargetLayout()
                .padding(.trailing, 8)
            }
            .scrollPosition(id: $presentation.accountScrollID, anchor: .top)
            .frame(maxHeight: .infinity)
        }
    }

    private var showsQuotaRings: Bool {
        store.preferences.quotaRingsEnabled
            && presentation.selectedTab == .accounts
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

    private func moreActionRow(
        title: String,
        icon: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredMoreAction == title
        return Button {
            showMoreActions = false
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isDestructive ? Color.red : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (isDestructive ? Color.red : Color.accentColor).opacity(isHovered ? 0.16 : 0),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hoveredMoreAction = $0 ? title : (hoveredMoreAction == title ? nil : hoveredMoreAction) }
        .pointerOnHover()
    }

}
