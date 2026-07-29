import AppKit
import SwiftUI

// Full-page settings/config view opened from the header gear (no longer a bottom tab).
struct ConfigPage: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updateChecker: UpdateChecker
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        // Fill the whole 25x25 so the entire button surface is the hit
                        // target, not just the glyph. contentShape makes the padded area tappable.
                        .frame(width: 25, height: 25)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Back")
                .accessibilityLabel("Back")
                .pointerOnHover()
                Text("Settings")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            SettingsPanel(store: store, updateChecker: updateChecker)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct SettingsPanel: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updateChecker: UpdateChecker

    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @State private var launchAtLoginNeedsApproval = LaunchAtLogin.requiresApproval
    @State private var launchAtLoginError: String?
    @State private var isEditingPrompt = false

    @ObservedObject private var remoteServer = RemoteControlServer.shared
    @State private var showingConnect = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
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
                            isEditingPrompt.toggle()
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(isEditingPrompt ? Color.purple : Color.secondary)
                                .frame(width: 24, height: 24)
                                .background(
                                    (isEditingPrompt ? Color.purple : Color.primary).opacity(isEditingPrompt ? 0.16 : 0.06),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("Edit the AI prompt")
                        .accessibilityLabel("Edit the AI prompt")
                        .pointerOnHover()
                        Toggle("", isOn: binding(\.aiInsightEnabled))
                            .accessibilityLabel("Show AI insight")
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    .padding(8)

                    if isEditingPrompt {
                        AIInstructionsEditor(store: store)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                    }
                }
                .settingsCard()

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

                remoteControlCard

                sectionHeader("General")

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
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            Button("Open") {
                                LaunchAtLogin.openSystemSettings()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.blue)
                            .pointerOnHover()
                        }
                        .padding(.leading, 26)
                    }

                    if let launchAtLoginError {
                        Text(launchAtLoginError)
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                            .padding(.leading, 26)
                    }
                }
                .padding(8)
                .settingsCard()

                HStack(spacing: 8) {
                    cardLabel(
                        icon: "menubar.rectangle",
                        iconColor: .secondary,
                        title: "Menu bar",
                        subtitle: "What the menu bar item shows at a glance."
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
                .settingsCard()

                // Sits directly under the menu bar picker: it decides where the readout lives,
                // so it belongs with the other placement settings rather than below the
                // notification thresholds it had nothing to do with.
                if NotchWindowController.isSupported {
                    notchModeRow
                }

                sectionHeader("Notifications")

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

                HStack(spacing: 8) {
                    cardLabel(
                        icon: "moon",
                        iconColor: .secondary,
                        title: "Do not disturb",
                        subtitle: "Silence notifications until you turn it back off."
                    )
                    Spacer(minLength: 8)
                    Toggle("", isOn: Binding(
                        get: { store.preferences.dndEnabled },
                        set: { store.setDND($0) }
                    ))
                    .accessibilityLabel("Do not disturb")
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                .padding(8)
                .settingsCard()

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
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    Slider(value: binding(\.lowQuotaThreshold), in: 0.05...0.50, step: 0.05)
                }
                .padding(8)
                .settingsCard()

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
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    Slider(value: binding(\.sessionWarningThreshold), in: 0.05...0.40, step: 0.05)
                }
                .padding(8)
                .settingsCard()

                VStack(spacing: 10) {
                    steppedSetting(
                        icon: "timer",
                        title: "Cooldown",
                        explanation: "Minimum time between repeat notifications.",
                        value: "\(store.preferences.notificationCooldownMinutes)m"
                    ) {
                        Stepper("", value: intBinding(\.notificationCooldownMinutes), in: 5...360, step: 5)
                            .labelsHidden()
                    }
                    Divider()
                    steppedSetting(
                        icon: "clock.arrow.circlepath",
                        title: "History",
                        explanation: "Days of usage history kept for the heatmap.",
                        value: "\(store.preferences.historyRetentionDays)d"
                    ) {
                        Stepper("", value: intBinding(\.historyRetentionDays), in: 1...60, step: 1)
                            .labelsHidden()
                    }
                }
                .padding(8)
                .settingsCard()

                sectionHeader("Updates")

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

                HStack(spacing: 8) {
                    cardLabel(
                        icon: "hammer",
                        iconColor: .orange,
                        title: "Channel",
                        subtitle: updateChecker.channel == .beta
                            ? "Includes pre-releases for early testing."
                            : "Stable releases only."
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
                    .pointerOnHover()
                }
                .padding(8)
                .settingsCard()

                if let update = updateChecker.availableUpdate {
                    UpdateAvailableBanner(update: update, updateChecker: updateChecker)
                }

                sectionHeader("Advanced")

                ConfigEditor(store: store)

                HStack(spacing: 8) {
                    advancedButton("Send debug report", icon: "paperclip") {
                        DiagnosticsReporter.presentSharePicker()
                    }
                    advancedButton("Logs", icon: "folder") {
                        DiagnosticsReporter.openLogFolder()
                    }
                }
            }
            .font(.system(size: 12))
            .padding(8)
        }
        .frame(maxHeight: .infinity)
        .onAppear(perform: resyncLaunchAtLoginFromSystem)
        // SMAppService's status can change out from under this view - e.g. the user
        // clicks "Open" above, approves the item in System Settings, then switches back
        // to Toki. Refresh on foreground so the toggle/note don't go stale until the next
        // manual flip.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            resyncLaunchAtLoginFromSystem()
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

    @ViewBuilder
    private var notchModeRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "macbook")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, alignment: .center)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text("Live in the notch")
                                .font(.system(size: 12, weight: .semibold))
                            Text("BETA")
                                .font(.system(size: 8, weight: .heavy))
                                .tracking(0.4)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    LinearGradient(
                                        colors: [Color(red: 0.45, green: 0.35, blue: 0.95),
                                                 Color(red: 0.85, green: 0.35, blue: 0.65)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ),
                                    in: Capsule()
                                )
                        }
                        Text(store.preferences.notchModeEnabled
                             ? "Toki is hanging out up there. Hover it for more."
                             : "Move Toki into the notch, Dynamic Island style.")
                            .font(.system(size: 9))
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
                    .padding(.horizontal, 8)
                HStack(spacing: 8) {
                    Text("Rests")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.leading, 26)
                    Spacer(minLength: 8)
                    Picker("Rests", selection: binding(\.notchPlacement)) {
                        ForEach(NotchPlacement.allCases) { placement in
                            Text(placement.label).tag(placement)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                cardLabel(
                    icon: "antenna.radiowaves.left.and.right",
                    iconColor: .teal,
                    title: "Remote Control Server",
                    subtitle: "Run a local server to check on and reply to your agents from your phone."
                )
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { remoteServer.isRunning },
                    set: { $0 ? remoteServer.start() : remoteServer.stop() }
                ))
                .accessibilityLabel("Remote Control Server")
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            HStack(spacing: 8) {
                Text("Host")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Picker("", selection: $remoteServer.hostMode) {
                    ForEach(remoteServer.availableHostModes) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                if remoteServer.hostMode == .custom {
                    TextField("host or IP", text: $remoteServer.customHost)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            HStack(spacing: 8) {
                Text("App")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Picker("", selection: $remoteServer.companionAppMode) {
                    ForEach(RemoteControlServer.CompanionAppMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                Spacer(minLength: 0)
                if remoteServer.isRunning, remoteServer.connectURL != nil {
                    Button {
                        showingConnect = true
                    } label: {
                        Label("Connect", systemImage: "qrcode")
                    }
                    .controlSize(.small)
                    .pointerOnHover()
                }
                if remoteServer.isRunning {
                    Button("Stop", role: .destructive) {
                        remoteServer.stop()
                    }
                    .controlSize(.small)
                    .help("Stop Remote Control and invalidate every connected session")
                    .pointerOnHover()
                }
            }
            .padding(.horizontal, 4)

            if remoteServer.companionAppMode == .hosted {
                Text("Toki RC only serves the interface. Agent data stays on this Mac and travels directly over your tailnet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }

            if remoteServer.isRunning, remoteServer.connectURL == nil {
                Text(connectHint)
                    .font(.system(size: 11))
                    .foregroundStyle(remoteServer.hostMode == .localNetwork ? .orange : .secondary)
                    .padding(.horizontal, 4)
            }

            if let error = remoteServer.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
        .padding(8)
        .settingsCard()
        .sheet(isPresented: $showingConnect) {
            RemoteConnectSheet()
        }
    }

    private var connectHint: String {
        if remoteServer.token == nil { return "Starting the server…" }
        if remoteServer.companionAppMode == .hosted {
            return "Toki RC requires a Tailscale DNS host with HTTPS Serve enabled."
        }
        if remoteServer.companionAppMode == .localNetwork {
            return "No local network address found. Try Localhost or Same as host."
        }
        switch remoteServer.hostMode {
        case .custom: return "Enter a host or IP to get a connect link."
        case .localNetwork: return "No local network address found. Try Localhost or Custom."
        case .tailscale: return "No Tailscale DNS name found. Make sure Tailscale is running and MagicDNS is enabled."
        case .localhost: return "Preparing the connect link…"
        }
    }

    private func cardLabel(icon: String, iconColor: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 18, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
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
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            control()
        }
    }

    private func advancedButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
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
