import AppKit
import Combine
import SwiftUI

private enum ReachMode: Hashable {
    case network
    case anywhere
}

struct ConfigPage: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updateChecker: UpdateChecker
    @ObservedObject var navigation: SettingsNavigationState
    var onClose: () -> Void

    var body: some View {
        Group {
            if navigation.route == .changelog {
                ChangelogPage { _ = navigation.goBack() }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            if !navigation.goBack() { onClose() }
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 13, height: 13)
                                .contentShape(Rectangle())
                        }
                        .functionalControlStyle()
                        .help("Back")
                        .accessibilityLabel("Back")
                        Text(navigation.route.title)
                            .font(.system(size: 15, weight: .semibold))
                        Spacer(minLength: 0)
                    }
                    switch navigation.route {
                    case .settings:
                        SettingsPanel(store: store, updateChecker: updateChecker, navigation: navigation)
                    case .configEditor:
                        ConfigEditor(store: store, navigation: navigation)
                    case .aiEditor:
                        AIInstructionsEditor(store: store, navigation: navigation)
                    case .pairing:
                        RemoteConnectSheet { _ = navigation.goBack() }
                    case .tailscaleGuide:
                        ScrollView { TailscaleSetupGuide(port: RemoteControlServer.shared.port) }
                    case .changelog:
                        EmptyView()
                    }
                }
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

}

struct SettingsPanel: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updateChecker: UpdateChecker
    @ObservedObject var navigation: SettingsNavigationState

    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @State private var launchAtLoginNeedsApproval = LaunchAtLogin.requiresApproval
    @State private var launchAtLoginError: String?
    @ObservedObject private var remoteServer = RemoteControlServer.shared
    @State private var copiedCommand: String?
    private let reachabilityTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private var channelSubtitle: String {
        if updateChecker.isSwitchingCask { return "Moving your Homebrew install to the other cask…" }
        if updateChecker.caskSwitchError != nil { return "Could not switch channels. See details below." }
        return updateChecker.channel == .beta ? "Includes pre-releases for early testing." : "Stable releases only."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("General").id("general")
                generalContent
                sectionHeader("Remote Control").id("remote-control")
                remoteControlCard
                sectionHeader("Appearance").id("appearance")
                appearanceContent
                sectionHeader("Notifications").id("notifications")
                notificationsContent
                sectionHeader("Permissions").id("permissions")
                permissionsCard
                sectionHeader("Updates").id("updates")
                updatesContent
                sectionHeader("Advanced").id("advanced")
                advancedContent
            }
            .scrollTargetLayout()
            .font(.system(size: 13))
        }
        .scrollPosition(id: $navigation.scrollAnchor, anchor: .top)
        .onAppear(perform: resyncLaunchAtLoginFromSystem)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            resyncLaunchAtLoginFromSystem()
        }
    }

    private func navigationRow(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentSurface()
    }

    @ViewBuilder
    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                cardLabel(
                    icon: "power",
                    iconColor: .secondary,
                    title: "Launch at login",
                    subtitle: "Start Toki automatically after you sign in."
                )
                Spacer(minLength: 8)
                Toggle("", isOn: launchAtLoginBinding)
                    .accessibilityLabel("Launch at login")
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if launchAtLoginNeedsApproval {
                HStack(spacing: 4) {
                    Text("Needs approval in System Settings > General > Login Items.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("Open") {
                        LaunchAtLogin.openSystemSettings()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.blue)
                    .pointerOnHover()
                }
                .padding(.leading, 26)
            }

            if let launchAtLoginError {
                Text(launchAtLoginError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.leading, 26)
            }
        }
        .padding(8)
        .settingsCard()
        .id("launch-at-login")
    }

    @ViewBuilder
    private var appearanceContent: some View {
        menuBarCard.id("menu-bar")

        if NotchWindowController.isSupported {
            notchModeRow.id("notch")
        }

        railModeRow.id("rail")

        if pinnableProviders.contains(where: { !quotaWindowLabels(for: $0).isEmpty }) {
            quotaWindowCard.id("quota-window")
        }

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                cardLabel(
                    icon: "sparkles",
                    iconColor: .purple,
                    title: "Show AI insight",
                    subtitle: "Show the insight card at the top of the main panel."
                )
                Spacer(minLength: 8)
                Button {
                    navigation.openAIEditor()
                } label: {
                    Image(systemName: "pencil")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Edit AI instructions")
                .accessibilityLabel("Edit AI instructions")
                Toggle("", isOn: binding(\.aiInsightEnabled))
                    .accessibilityLabel("Show AI insight")
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(8)

        }
        .settingsCard()
        .id("ai-insight")

        HStack(spacing: 8) {
            cardLabel(
                icon: "bolt.ring.closed",
                iconColor: .blue,
                title: "Show quota rings",
                subtitle: "Display provider availability rings in the Accounts panel."
            )
            Spacer(minLength: 8)
            Toggle("", isOn: binding(\.quotaRingsEnabled))
                .accessibilityLabel("Show quota rings")
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(8)
        .settingsCard()
        .id("quota-rings")
    }

    @ViewBuilder
    private var notificationsContent: some View {
        HStack(spacing: 8) {
            cardLabel(
                icon: "bell",
                iconColor: .secondary,
                title: "Notifications",
                subtitle: "Show low-quota and session warnings."
            )
            Spacer(minLength: 8)
            Toggle("", isOn: binding(\.notificationsEnabled))
                .accessibilityLabel("Notifications")
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(8)
        .settingsCard()
        .id("notifications-enabled")

        HStack(spacing: 8) {
            cardLabel(
                icon: "moon",
                iconColor: .secondary,
                title: "Pause Toki notifications",
                subtitle: "Silence notifications until you turn it back off."
            )
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { store.preferences.dndEnabled },
                set: { store.setDND($0) }
            ))
            .accessibilityLabel("Pause Toki notifications")
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(8)
        .settingsCard()
        .id("notifications-paused")

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                cardLabel(
                    icon: "speedometer",
                    iconColor: .secondary,
                    title: "Low quota threshold",
                    subtitle: "Warn when a provider's remaining quota falls below this."
                )
                Spacer(minLength: 8)
                Text(percentText(store.preferences.lowQuotaThreshold))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
            }
            Slider(value: binding(\.lowQuotaThreshold), in: 0.05...0.50, step: 0.05)
                .accessibilityLabel("Low quota threshold")
                .accessibilityValue(percentText(store.preferences.lowQuotaThreshold))
                .padding(.leading, 26)
        }
        .padding(8)
        .settingsCard()
        .id("low-quota-threshold")

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                cardLabel(
                    icon: "hourglass",
                    iconColor: .secondary,
                    title: "Session warning",
                    subtitle: "Warn when the active session's quota falls below this."
                )
                Spacer(minLength: 8)
                Text(percentText(store.preferences.sessionWarningThreshold))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
            }
            Slider(value: binding(\.sessionWarningThreshold), in: 0.05...0.40, step: 0.05)
                .accessibilityLabel("Session warning threshold")
                .accessibilityValue(percentText(store.preferences.sessionWarningThreshold))
                .padding(.leading, 26)
        }
        .padding(8)
        .settingsCard()
        .id("session-warning")

        steppedSetting(
            icon: "timer", title: "Cooldown",
            explanation: "Minimum time between repeat notifications.",
            value: "\(store.preferences.notificationCooldownMinutes)m"
        ) {
            Stepper("Notification cooldown", value: intBinding(\.notificationCooldownMinutes), in: 5...360, step: 5)
                .labelsHidden()
                .accessibilityValue("\(store.preferences.notificationCooldownMinutes) minutes")
        }
        .padding(8)
        .settingsCard()
        .id("notification-cooldown")
    }

    @ViewBuilder
    private var updatesContent: some View {
        HStack(spacing: 8) {
            cardLabel(
                icon: "arrow.triangle.2.circlepath",
                iconColor: .secondary,
                title: "App updates",
                subtitle: appUpdatesStatus
            )
            Spacer(minLength: 8)
            Button {
                updateChecker.checkNow()
            } label: {
                ZStack {
                    Text("Check now")
                        .opacity(updateChecker.isChecking ? 0 : 1)
                    if updateChecker.isChecking {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Checking for updates")
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(updateChecker.isChecking)
            .pointerOnHover()
        }
        .padding(8)
        .settingsCard()
        .id("check-updates")

        HStack(spacing: 8) {
            cardLabel(
                icon: "hammer",
                iconColor: .orange,
                title: "Channel",
                subtitle: channelSubtitle
            )
            Spacer(minLength: 8)
            Picker("Update channel", selection: Binding(
                get: { updateChecker.channel },
                set: { updateChecker.setChannel($0) }
            )) {
                ForEach(UpdateChannel.allCases) { channel in
                    Text(channel.displayName).tag(channel)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .disabled(updateChecker.isSwitchingCask)
            .pointerOnHover()
        }
        .padding(8)
        .settingsCard()
        .id("update-channel")

        if let error = updateChecker.caskSwitchError {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 26)
                .padding(8)
                .id("channel-error")
        }
        if let update = updateChecker.availableUpdate {
            UpdateAvailableBanner(update: update, updateChecker: updateChecker)
                .id("available-update")
        }

        navigationRow("What's New", icon: "sparkles") { navigation.openChangelog() }
            .id("changelog")
    }

    @ViewBuilder
    private var advancedContent: some View {
        steppedSetting(
            icon: "clock.arrow.circlepath", title: "History retention",
            explanation: "Days of usage history kept for the heatmap.",
            value: "\(store.preferences.historyRetentionDays)d"
        ) {
            Stepper("History retention", value: intBinding(\.historyRetentionDays), in: 1...60, step: 1)
                .labelsHidden()
                .accessibilityValue("\(store.preferences.historyRetentionDays) days")
        }
        .padding(8)
        .settingsCard()
        .id("history-retention")
        navigationRow("Edit config.json", icon: "curlybraces") { navigation.openConfigEditor() }
            .id("config-editor")
        HStack(spacing: 8) {
            advancedButton("Send debug report", icon: "paperclip") { DiagnosticsReporter.presentSharePicker() }
            advancedButton("Logs", icon: "folder") { DiagnosticsReporter.openLogFolder() }
        }
    }

    // Status line shown as the App updates card's subtitle.
    private var appUpdatesStatus: String {
        if updateChecker.isChecking { return "Checking GitHub…" }
        if let message = updateChecker.checkMessage { return message }
        if updateChecker.lastCheckedAt != nil { return "Checked." }
        return "Checks automatically every 5 minutes."
    }

    // Only for external resync (view appearing, app regaining focus) - also clears any
    // stale error, since those are exactly the moments the user might have fixed things
    // outside the app (e.g. approved in System Settings) and an old failure message left
    // over from before would now be misleading. Not used by the toggle's own binding
    // below, which sets launchAtLoginError itself and would have it immediately wiped.
    private func resyncLaunchAtLoginFromSystem() {
        refreshLaunchAtLoginState()
        launchAtLoginError = nil
    }

    private func refreshLaunchAtLoginState() {
        launchAtLoginEnabled = LaunchAtLogin.isEnabled
        launchAtLoginNeedsApproval = LaunchAtLogin.requiresApproval
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginEnabled },
            set: { newValue in
                do {
                    try LaunchAtLogin.setEnabled(newValue)
                    launchAtLoginError = nil
                } catch {
                    launchAtLoginError = "Could not \(newValue ? "enable" : "disable") launch at login: \(error.localizedDescription)"
                }
                refreshLaunchAtLoginState()
            }
        )
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { store.preferences[keyPath: keyPath] },
            set: { value in
                var next = store.preferences
                next[keyPath: keyPath] = value
                store.updatePreferences(next)
            }
        )
    }

    // Mode (what is shown) and density (how much room it takes) are separate axes, so every
    // mode can be run at every density. Pinning only appears when it has something to do.
    @ViewBuilder
    private var menuBarCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                cardLabel(
                    icon: "menubar.rectangle",
                    iconColor: .secondary,
                    title: "Menu bar",
                    subtitle: store.preferences.menuBarMode.detail
                )
                Spacer(minLength: 8)
                Picker("Menu bar", selection: binding(\.menuBarMode)) {
                    ForEach(MenuBarDisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .pointerOnHover()
            }
            .padding(8)

            if store.preferences.menuBarMode == .pinned {
                pinnedProvidersRow
            }

            // Logo-only draws no numbers, so there is no density for it to change.
            if store.preferences.menuBarMode != .logoOnly {
                HStack(spacing: 8) {
                    Text("Size")
                        .font(.system(size: 11))
                        .padding(.leading, 26)
                    Spacer(minLength: 8)
                    // No fixedSize here, unlike the notch row below: three density names are
                    // wider than the card can spare, and a segmented picker held at its
                    // intrinsic width squeezes the label beside it down to nothing.
                    Picker("Size", selection: binding(\.menuBarDensity)) {
                        ForEach(MenuBarDensity.allCases) { density in
                            Text(density.label).tag(density)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .help("Comfortable and Compact fit 3 providers; Compact drops the percent sign. Stacked fits 2, on two rows")
                }
                .padding(8)
                .padding(.bottom, 4)
            }
        }
    }

    private var quotaWindowCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardLabel(
                icon: "clock",
                iconColor: .secondary,
                title: "Quota window",
                subtitle: "Menu bar, quota rail, and quota overview."
            )
            .padding(8)

            ForEach(pinnableProviders, id: \.self) { provider in
                let windows = quotaWindowLabels(for: provider)
                if !windows.isEmpty {
                    HStack(spacing: 8) {
                        Text(provider.displayName)
                            .padding(.leading, 26)
                        Spacer(minLength: 8)
                        if windows.count > 1 {
                            Picker("\(provider.displayName) quota window", selection: Binding(
                                get: {
                                    let selected = store.preferences.quotaDisplayWindows[provider.rawValue] ?? ""
                                    return windows.contains(selected) ? selected : ""
                                },
                                set: { selected in
                                    var next = store.preferences
                                    next.quotaDisplayWindows[provider.rawValue] = selected.isEmpty ? nil : selected
                                    store.updatePreferences(next)
                                }
                            )) {
                                Text("Auto").tag("")
                                ForEach(windows, id: \.self) { Text($0).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .controlSize(.small)
                            .fixedSize()
                            .help("Auto shows the available limit with the least quota remaining.")
                        } else {
                            Text(windows[0])
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 11))
                    .padding(8)
                }
            }
        }
    }

    private func quotaWindowLabels(for provider: Provider) -> [String] {
        let snapshot = store.snapshots.first { $0.provider == provider && $0.switchTarget == nil && !$0.isError }
            ?? store.snapshots.first { $0.provider == provider && !$0.isError }
        return [snapshot?.primaryWindow, snapshot?.secondaryWindow].compactMap { $0?.label }
            .reduce(into: []) { labels, label in
                if !labels.contains(label) { labels.append(label) }
            }
    }

    // Driven off connected accounts rather than the full Provider list, so the choices are
    // ones that can actually show a number.
    private var pinnableProviders: [Provider] {
        var seen: Set<Provider> = []
        return store.snapshots.filter { !$0.isError }.map(\.provider).filter { seen.insert($0).inserted }
    }

    /// The arithmetic behind the chips lives in `menuBarPinState` so the counts this panel
    /// promises can be checked against what the menu bar actually draws.
    private var pinState: MenuBarPinState {
        menuBarPinState(
            pinned: store.preferences.menuBarPinnedProviders,
            connected: pinnableProviders,
            density: store.preferences.menuBarDensity
        )
    }

    private var pinCap: Int { pinState.cap }
    private var overflowPins: [Provider] { pinState.overflow }

    @ViewBuilder
    private var pinnedProvidersRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if pinnableProviders.isEmpty {
                Text("Connect an account to pick what the menu bar pins.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(pinnableProviders, id: \.self) { provider in
                        pinToggle(for: provider)
                    }
                }

                if !overflowPins.isEmpty {
                    // Reachable by switching density with pins already set, so it names what
                    // is being dropped instead of silently shortening the readout.
                    exposureNote(
                        "\(store.preferences.menuBarDensity.label) fits \(pinCap). "
                        + "\(listedNames(overflowPins)) \(overflowPins.count == 1 ? "is" : "are") pinned but hidden. "
                        + "unpin, or switch to Comfortable.",
                        level: .warning
                    )
                } else {
                    Text(!pinState.canPinMore
                         ? "\(store.preferences.menuBarDensity.label) fits \(pinCap). Unpin one to swap in another."
                         : "Shows up to \(pinCap), in the order you pin them. Pin nothing and Toki falls back to Smart.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .padding(.leading, 26)
    }

    private func pinToggle(for provider: Provider) -> some View {
        let pins = store.preferences.menuBarPinnedProviders
        let isPinned = pins.contains(provider)
        // Blocked rather than allowed-and-truncated: a pin that silently never appears is the
        // thing that made the old cap feel broken. Unpinning is always allowed, so the user is
        // never stuck, and an over-cap selection carried in from a density change stays
        // editable.
        let isBlocked = !isPinned && !pinState.canPinMore
        let isHidden = overflowPins.contains(provider)

        return Button {
            var next = store.preferences
            if let index = next.menuBarPinnedProviders.firstIndex(of: provider) {
                next.menuBarPinnedProviders.remove(at: index)
            } else {
                next.menuBarPinnedProviders.append(provider)
            }
            store.updatePreferences(next)
        } label: {
            HStack(spacing: 5) {
                ProviderLogo(provider: provider, size: 11)
                Text(provider.displayName)
                    .font(.system(size: 11, weight: isPinned ? .medium : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isHidden {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(pinFill(isPinned: isPinned, isHidden: isHidden), in: Capsule())
            .overlay(
                Capsule().strokeBorder(pinStroke(isPinned: isPinned, isHidden: isHidden), lineWidth: 1)
            )
            .opacity(isBlocked ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isBlocked)
        .pointerOnHover()
        .help(pinHelp(isPinned: isPinned, isBlocked: isBlocked, isHidden: isHidden))
        .accessibilityLabel(
            "\(provider.displayName)"
            + (isPinned ? ", pinned" : "")
            + (isHidden ? ", hidden past the \(pinCap) this density fits" : "")
            + (isBlocked ? ", unavailable until you unpin one" : "")
        )
    }

    private func pinFill(isPinned: Bool, isHidden: Bool) -> Color {
        guard isPinned else { return Color.secondary.opacity(0.08) }
        return (isHidden ? Color.orange : Color.accentColor).opacity(0.18)
    }

    private func pinStroke(isPinned: Bool, isHidden: Bool) -> Color {
        guard isPinned else { return .clear }
        return (isHidden ? Color.orange : Color.accentColor).opacity(0.55)
    }

    private func pinHelp(isPinned: Bool, isBlocked: Bool, isHidden: Bool) -> String {
        let density = store.preferences.menuBarDensity.label
        if isHidden { return "Pinned, but \(density) only fits \(pinCap) — this one is not drawn" }
        if isBlocked { return "\(density) fits \(pinCap). Unpin one first" }
        return isPinned ? "Pinned to the menu bar" : "Pin to the menu bar"
    }

    // No isSupported gate, unlike the notch row: the rail anchors to the screen edge, so it
    // works on any display.
    @ViewBuilder
    private var railModeRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text("Quota rail")
                            .font(.system(size: 13, weight: .medium))
                        betaBadge
                    }
                    Text("Quota rings down the screen edge. Details are also available in Accounts.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: binding(\.railModeEnabled))
                .accessibilityLabel("Quota rail")
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(8)
        .settingsCard()
        .help("Shows a ring per provider beside the menu bar, on any display")
        .pointerOnHover()
    }

    @ViewBuilder
    private var notchModeRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "macbook")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, alignment: .center)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text("Live in the notch")
                                .font(.system(size: 13, weight: .medium))
                            betaBadge
                        }
                        Text(store.preferences.notchModeEnabled
                             ? "Quota stays beside the notch. Open Accounts for details."
                             : "Move Toki into the notch, Dynamic Island style.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Toggle("", isOn: binding(\.notchModeEnabled))
                    .accessibilityLabel("Live in the notch")
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(8)

            if store.preferences.notchModeEnabled {
                Divider()
                    .padding(.leading, 34)
                HStack(spacing: 8) {
                    Text("Rests")
                        .font(.system(size: 11))
                        .padding(.leading, 26)
                    Spacer(minLength: 8)
                    Picker("Rests", selection: binding(\.notchPlacement)) {
                        ForEach(NotchPlacement.allCases) { placement in
                            Text(placement.label).tag(placement)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .help("Hanging drops below the notch; Sideways sits in the menu bar beside it")
                }
                .padding(8)
            }
        }
        .settingsCard()
        .help("Replaces the menu bar item with a panel that hangs from the display notch")
        .pointerOnHover()
    }

    @ViewBuilder
    private var remoteControlCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                cardLabel(
                    icon: "arcade.stick",
                    iconColor: .teal,
                    title: "Remote Control Server",
                    subtitle: "Run a local server to check on and reply to your agents from your phone."
                )
                Link(destination: remoteControlGuideURL) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("How Remote Control works, and what to watch out for")
                .accessibilityLabel("Remote Control guide")
                .pointerOnHover()
                Spacer(minLength: 8)
                Text(remoteServer.isRunning ? "Running" : "Off")
                    .font(.system(size: 11))
                    .foregroundStyle(remoteServer.isRunning ? Color.green : Color.secondary)
            }

            sectionHeader("1. Connection method").id("remote-method")

            Picker("Reach", selection: reachBinding) {
                Text("On my network").tag(ReachMode.network)
                Text("From anywhere").tag(ReachMode.anywhere)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)

            Text(reachBinding.wrappedValue == .network
                ? "Your phone connects over Wi-Fi on the same network. No setup."
                : "Reach this Mac from any network over HTTPS. Tailscale is recommended: it stays off the public internet.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if reachBinding.wrappedValue == .anywhere || remoteServer.companionAppMode == .hosted {
                Button("Tailscale setup guide") { navigation.openTailscaleGuide() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Host").foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                    Picker("Host", selection: $remoteServer.hostMode) {
                        ForEach(remoteServer.availableHostModes) { mode in
                            Text(mode.label.replacingOccurrences(of: " (Recommended)", with: "")).tag(mode)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("Tailscale is recommended for access from other networks.")
                }
                if remoteServer.hostMode == .custom {
                    GridRow {
                        Text("Address").foregroundStyle(.secondary)
                        // The running server only accepts the host it was launched with.
                        TextField("host or IP", text: $remoteServer.customHost)
                            .textFieldStyle(.roundedBorder)
                            .disabled(remoteServer.isRunning)
                            .help(remoteServer.isRunning
                                ? "Stop Remote Control to change the custom host"
                                : "The host your phone will use to reach this Mac")
                    }
                }
                if remoteServer.hostMode == .tailscale, remoteServer.tailscaleDNSName == nil {
                    GridRow(alignment: .top) {
                        Text("Address").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            if let diagnostic = remoteServer.tailscaleStatusDiagnostic,
                               !remoteServer.hasUsableTailscaleHost {
                                Text(diagnostic)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            TextField("your-mac.tailnet.ts.net", text: $remoteServer.manualTailscaleHost)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                            Text("Enter your Mac's Tailscale name to build a Connect link.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                GridRow {
                    Text("App").foregroundStyle(.secondary)
                    Picker("App", selection: $remoteServer.companionAppMode) {
                        ForEach(RemoteControlServer.CompanionAppMode.allCases) { mode in
                            Text(mode.label.replacingOccurrences(of: " (Recommended)", with: "")).tag(mode)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("Same as host is recommended: the interface is served by this Mac.")
                }
                GridRow {
                    Text("Session").foregroundStyle(.secondary)
                    Picker("Session lifetime", selection: $remoteServer.sessionLifetime) {
                        ForEach(RemoteControlServer.SessionLifetime.allCases) { lifetime in
                            Text(lifetime.label.replacingOccurrences(of: " (Recommended)", with: "")).tag(lifetime)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(remoteServer.isRunning)
                    .help(remoteServer.isRunning
                        ? "Stop Remote Control to change the session lifetime"
                        : "How long a verified device stays connected. 12 hours is recommended.")
                }
            }
            .font(.system(size: 11))
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)

            if remoteServer.hostMode == .tunnel {
                exposureNote(
                    "A quick tunnel puts this Mac behind an address anyone on the internet can reach. Your link and code still gate it, but Tailscale keeps it off the public internet entirely.",
                    level: .warning
                )
            }

            if remoteServer.companionAppMode == .hosted {
                exposureNote(
                    "Toki RC only serves the interface, and agent data travels directly to this Mac over your tailnet. It is still code loaded from a web server, so \"Same as host\" is safer: it serves the same app from this Mac and involves no third party.",
                    level: .info
                )
            }

            sectionHeader("2. Readiness").id("remote-readiness")
            if !remoteServer.isRunning {
                Text("Start the server to check reachability. No device can connect while it is off.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if remoteServer.connectURL != nil,
                      remoteServer.hostMode != .tailscale, remoteServer.companionAppMode != .hosted {
                Label("Ready to connect", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            }

            // A hand-typed host counts: the Mac App Store build of Tailscale ships no usable CLI,
            // so `tailscale status` reads nothing and the DNS name is entered by hand - which is
            // exactly when someone needs to be told HTTPS isn't up yet.
            if remoteServer.isRunning, remoteServer.hasUsableTailscaleHost,
               remoteServer.companionAppMode == .hosted || remoteServer.hostMode == .tailscale {
                tailscaleReadinessRow
            }

            if remoteServer.isRunning, remoteServer.connectURL == nil {
                Text(connectHint)
                    .font(.system(size: 11))
                    .foregroundStyle(remoteServer.hostMode == .localNetwork ? .orange : .secondary)
            }

            if let error = remoteServer.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            remoteConnectionActions.id("remote-connect")
            pairedDevicesSection
            if remoteServer.isRunning {
                Divider()
                Button("Stop Remote Control", role: .destructive) { remoteServer.stop() }
                Text("Stopping disconnects every device and invalidates all pairing links.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .scrollTargetLayout()
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .settingsCard()
        .onAppear { remoteServer.refreshTailscaleStatus() }
        .onReceive(reachabilityTimer) { _ in
            if remoteServer.isRunning,
               remoteServer.companionAppMode == .hosted || remoteServer.hostMode == .tailscale {
                remoteServer.refreshTailscaleStatus()
            }
        }
    }

    private var remoteConnectionActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("3. Connect device")
            HStack(spacing: 8) {
                if remoteServer.isRunning {
                    Button { navigation.openPairing() } label: {
                        Label("Connect device", systemImage: "qrcode")
                    }
                    .disabled(remoteServer.connectURL == nil)
                    .help(remoteServer.connectURL == nil ? connectHint : "Show the connection link and verification code")
                    Spacer(minLength: 0)
                } else {
                    Button("Start server") { remoteServer.start() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func copyCommandButton(_ command: String, label: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            copiedCommand = command
        } label: {
            Label(copiedCommand == command ? "Copied" : label, systemImage: copiedCommand == command ? "checkmark" : "doc.on.doc")
        }
        .controlSize(.small)
        .fixedSize()
        .help(command)
        .accessibilityLabel("Copy \(command)")
        .pointerOnHover()
    }

    // A string literal per state rather than nested ternaries inside the Text, so each state's
    // wording is readable and stays formatted (the backticks are markdown to Text).
    private var readinessMessage: LocalizedStringKey {
        // An unreadable status is not evidence serve is off; it now says what it couldn't read.
        if let problem = remoteServer.serveStatusProblem {
            return LocalizedStringKey(problem + " Serve may well be running - this is Toki failing to check, not Tailscale failing to serve.")
        }
        switch remoteServer.tailscaleServeReady {
        case .some(true):
            return "Reachable from your phone."
        case .some(false):
            if remoteServer.isEnablingServe {
                return "Turning on HTTPS access with `tailscale serve`…"
            }
            if remoteServer.tailscaleServeConflict {
                return "Tailscale already serves another app on HTTPS 443. Enabling here will replace it."
            }
            return "`tailscale serve` isn't running on 443, so your phone can't reach this Mac yet."
        case nil:
            return "Checking whether your phone can reach this Mac…"
        }
    }

    @ViewBuilder
    private var tailscaleReadinessRow: some View {
        let ready = remoteServer.tailscaleServeReady
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: ready == true ? "checkmark.circle.fill"
                    : (ready == false || remoteServer.serveStatusProblem != nil) ? "exclamationmark.triangle.fill" : "ellipsis.circle")
                    .foregroundStyle(ready == true ? Color.green
                        : (ready == false || remoteServer.serveStatusProblem != nil) ? Color.orange : Color.secondary)
                Text(readinessMessage)
                    .foregroundStyle((ready == false || remoteServer.serveStatusProblem != nil) && !remoteServer.isEnablingServe ? Color.orange : Color.secondary)
            }
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)

            if ready == false || remoteServer.serveStatusProblem != nil {
                if remoteServer.tailscaleCLIAvailable == false {
                    // Nothing to click: with no CLI Toki cannot run serve at all, so hand over the
                    // exact command instead of a button that would only fail.
                    HStack(spacing: 8) {
                        copyCommandButton(remoteServer.tailscaleServeCommand, label: "Copy serve command")
                        Text("Toki can't find the tailscale command, so run this on the Mac yourself.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    HStack(spacing: 8) {
                        Button {
                            remoteServer.enableTailscaleServe()
                        } label: {
                            if remoteServer.isEnablingServe {
                                HStack(spacing: 5) {
                                    ProgressView().controlSize(.small).scaleEffect(0.7)
                                    Text("Enabling…")
                                }
                            } else {
                                Text(remoteServer.tailscaleServeConflict ? "Replace and enable HTTPS" : "Enable HTTPS access")
                            }
                        }
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(remoteServer.isEnablingServe)
                        .help("Run tailscale serve so your phone can reach this Mac over HTTPS")
                        .pointerOnHover()

                        Text("or set it up by hand with the Tailscale setup guide.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                // Toki declined to run serve itself; saying so beats a warning that looks like nothing happened.
                if remoteServer.serveSetupFailure == nil, let skipped = remoteServer.autoServeSkipped {
                    Text(skipped)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let failure = remoteServer.serveSetupFailure {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(failure.message)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        if let remedy = failure.remedy {
                            HStack(spacing: 6) {
                                Text(remedy)
                                    .font(.system(size: 11).monospaced())
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                copyCommandButton(remedy, label: "Copy")
                            }
                        }
                    }
                }
            }
        }
    }

    private var reachBinding: Binding<ReachMode> {
        Binding(
            get: {
                switch remoteServer.hostMode {
                case .tailscale, .tunnel: return .anywhere
                default: return .network
                }
            },
            set: { mode in
                switch mode {
                case .network:
                    remoteServer.hostMode = RemoteControlServer.localNetworkIP() != nil ? .localNetwork : .localhost
                    remoteServer.companionAppMode = .sameHost
                case .anywhere:
                    let modes = remoteServer.availableHostModes
                    if modes.contains(.tailscale) {
                        remoteServer.hostMode = .tailscale
                        remoteServer.companionAppMode = .sameHost
                    } else if modes.contains(.tunnel) {
                        remoteServer.hostMode = .tunnel
                        remoteServer.companionAppMode = .sameHost
                    }
                }
            }
        )
    }

    private var connectHint: String {
        if remoteServer.token == nil { return "Starting the server…" }
        if remoteServer.companionAppMode == .hosted {
            return "Toki RC needs a Tailscale DNS host. Use the Tailscale setup guide to turn on MagicDNS and HTTPS Serve."
        }
        if remoteServer.companionAppMode == .localNetwork {
            return "No local network address found. Try Localhost or Same as host."
        }
        switch remoteServer.hostMode {
        case .custom: return "Enter a host or IP to get a connect link."
        case .localNetwork: return "No local network address found. Try Localhost or Custom."
        case .tailscale: return "No Tailscale DNS name found. Make sure Tailscale is running and MagicDNS is enabled."
        case .tunnel:
            return remoteServer.tunnelError ?? "Starting a Cloudflare tunnel… this can take a few seconds."
        case .localhost: return "Preparing the connect link…"
        }
    }

    private func cardLabel(icon: String, iconColor: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 18, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private enum ExposureLevel {
        case info
        case warning
    }

    private func exposureNote(_ text: String, level: ExposureLevel) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: level == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(level == .warning ? Color.orange : Color.secondary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Every phone currently holding a session, so a device you no longer recognise can be cut off
    // without stopping the server on everyone else.
    @ViewBuilder
    private var pairedDevicesSection: some View {
        if remoteServer.isRunning, !remoteServer.pairedDevices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Paired devices")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                ForEach(remoteServer.pairedDevices) { device in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "iphone")
                            .font(.system(size: 12))
                            .foregroundStyle(.teal)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.name)
                                .font(.system(size: 11, weight: .medium))
                            Text(Self.deviceDetail(device))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button("Revoke", role: .destructive) {
                            remoteServer.revoke(device)
                        }
                        .controlSize(.small)
                        .fixedSize()
                        .help("End this device's session; it returns to the verification screen")
                        .pointerOnHover()
                    }
                }
            }
        }
    }

    // The address is best effort and says so. Behind `tailscale serve` or `cloudflared` the peer
    // is the proxy on this Mac, not the phone, and no header is trustworthy enough to claim
    // otherwise. The id is what actually names the session.
    static func deviceDetail(_ device: RemoteControlServer.PairedDevice) -> String {
        let address = device.proxied ? "via proxy" : device.ip
        return "\(device.id) · \(address) · seen \(relativeTime(device.seen)) · expires \(relativeTime(device.expires))"
    }

    private static func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // The same checklist onboarding shows, kept permanently: a permission can be revoked in
    // System Settings long after setup, and this is where you find out that it was.
    private var permissionsCard: some View {
        SetupChecklistView(store: store, showsHeader: false)
            .padding(8)
            .settingsCard()
    }

    private var betaBadge: some View {
        Text("Beta")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private func steppedSetting<Control: View>(
        icon: String,
        title: String,
        explanation: String,
        value: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 8) {
            cardLabel(icon: icon, iconColor: .secondary, title: title, subtitle: explanation)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
            control()
        }
    }

    private func advancedButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .pointerOnHover()
    }

    private func intBinding(_ keyPath: WritableKeyPath<AppPreferences, Int>) -> Binding<Int> {
        Binding(
            get: { store.preferences[keyPath: keyPath] },
            set: { value in
                var next = store.preferences
                next[keyPath: keyPath] = value
                store.updatePreferences(next)
            }
        )
    }
}

private extension View {
    func settingsCard() -> some View {
        overlay(alignment: .bottom) {
            Divider()
                .padding(.leading, 34)
        }
    }
}

// One-time Tailscale setup so the hosted Toki RC interface can reach this Mac over HTTPS.
// The hosted page is served over HTTPS and browsers block it from calling a plain-HTTP LAN
// address, so a tailnet HTTPS host is required for the connect-from-anywhere path.
private struct TailscaleSetupGuide: View {
    let port: Int
    @State private var copied = false

    private var serveCommand: String { "tailscale serve --bg http://127.0.0.1:\(port)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Connect from anywhere with Tailscale")
                    .font(.system(size: 13, weight: .semibold))
                Text("Tailscale gives this Mac a private HTTPS address your phone can reach from any network. It is a one-time setup.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            step(1, "Install Tailscale on this Mac and sign in.") {
                guideLink("Download Tailscale", "https://tailscale.com/download/mac")
            }
            step(2, "In the admin console, turn on MagicDNS, then enable HTTPS Certificates.") {
                guideLink("Open DNS settings", "https://login.tailscale.com/admin/dns")
            }
            step(3, "Give Toki an HTTPS address on your tailnet. Run this in Terminal:") {
                commandRow
            }
            step(4, "Install Tailscale on your phone and sign into the same account.") {
                guideLink("Get the mobile app", "https://tailscale.com/download")
            }
            step(5, "Back here, set Host to Tailscale and App to Toki RC, then open Connect.") {
                EmptyView()
            }

            Divider()

            Text("Your agent data never touches Toki RC. It travels directly between your phone and this Mac over your tailnet.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                guideLink("Enabling HTTPS", "https://tailscale.com/kb/1153/enabling-https")
                guideLink("tailscale serve", "https://tailscale.com/kb/1242/tailscale-serve")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func step<Accessory: View>(
        _ number: Int,
        _ text: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 17, height: 17)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(text)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                accessory()
            }
        }
    }

    private var commandRow: some View {
        HStack(spacing: 6) {
            Text(serveCommand)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(.vertical, 5)
                .padding(.horizontal, 7)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                .fixedSize(horizontal: false, vertical: true)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(serveCommand, forType: .string)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 13, height: 13)
                    .contentShape(Rectangle())
            }
            .functionalControlStyle()
            .help(copied ? "Copied" : "Copy command")
            .accessibilityLabel("Copy the tailscale serve command")
            .pointerOnHover()
        }
    }

    private func guideLink(_ label: String, _ urlString: String) -> some View {
        Link(destination: URL(string: urlString)!) {
            HStack(spacing: 3) {
                Text(label)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11))
            }
            .font(.system(size: 11, weight: .medium))
        }
        .pointerOnHover()
    }
}
