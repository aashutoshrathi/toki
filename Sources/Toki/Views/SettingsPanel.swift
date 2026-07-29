import AppKit
import SwiftUI

private enum SettingsAnchor: Hashable {
    case remoteControl
}

// Full-page settings/config view opened from the header gear (no longer a bottom tab).
struct ConfigPage: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updateChecker: UpdateChecker
    var focusRemoteControl = false
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
            SettingsPanel(
                store: store,
                updateChecker: updateChecker,
                focusRemoteControl: focusRemoteControl
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct SettingsPanel: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updateChecker: UpdateChecker
    var focusRemoteControl = false

    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @State private var launchAtLoginNeedsApproval = LaunchAtLogin.requiresApproval
    @State private var launchAtLoginError: String?
    @State private var isEditingPrompt = false

    @ObservedObject private var remoteServer = RemoteControlServer.shared
    @State private var showingConnect = false
    @State private var showingTailscaleGuide = false
    private let reachabilityTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollViewReader { proxy in
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
                        .id(SettingsAnchor.remoteControl)

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
        .onAppear {
            guard focusRemoteControl else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(SettingsAnchor.remoteControl, anchor: .top)
            }
        }
        .onAppear(perform: resyncLaunchAtLoginFromSystem)
        // SMAppService's status can change out from under this view - e.g. the user
        // clicks "Open" above, approves the item in System Settings, then switches back
        // to Toki. Refresh on foreground so the toggle/note don't go stale until the next
        // manual flip.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            resyncLaunchAtLoginFromSystem()
        }
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
                    .frame(width: 48, alignment: .leading)
                Picker("", selection: $remoteServer.hostMode) {
                    ForEach(remoteServer.availableHostModes) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                if remoteServer.hostMode == .tailscale || remoteServer.companionAppMode == .hosted {
                    Button {
                        showingTailscaleGuide = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("How to set up Tailscale so you can connect from anywhere")
                    .accessibilityLabel("Tailscale setup guide")
                    .pointerOnHover()
                    .popover(isPresented: $showingTailscaleGuide, arrowEdge: .bottom) {
                        TailscaleSetupGuide(port: remoteServer.port)
                    }
                }
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
                    .frame(width: 48, alignment: .leading)
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
            }
            .padding(.horizontal, 4)

            HStack(spacing: 8) {
                Text("Session")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
                Picker("", selection: $remoteServer.sessionLifetime) {
                    ForEach(RemoteControlServer.SessionLifetime.allCases) { lifetime in
                        Text(lifetime.label).tag(lifetime)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .disabled(remoteServer.isRunning)
                .help(remoteServer.isRunning
                    ? "Stop Remote Control to change the session lifetime"
                    : "How long a verified device stays connected")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            if remoteServer.isRunning {
                HStack(spacing: 8) {
                    if remoteServer.connectURL != nil {
                        Button {
                            showingConnect = true
                        } label: {
                            Label("Connect", systemImage: "qrcode")
                        }
                        .controlSize(.small)
                        .fixedSize()
                        .pointerOnHover()
                    }

                    Button("Stop", role: .destructive) {
                        remoteServer.stop()
                    }
                    .controlSize(.small)
                    .fixedSize()
                    .help("Stop Remote Control and invalidate every connected session")
                    .pointerOnHover()

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
            }

            if remoteServer.companionAppMode == .hosted {
                Text("Toki RC only serves the interface. Agent data stays on this Mac and travels directly over your tailnet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }

            if remoteServer.isRunning, remoteServer.connectURL != nil,
               remoteServer.companionAppMode == .hosted || remoteServer.hostMode == .tailscale {
                tailscaleReadinessRow
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
        .onAppear { remoteServer.refreshTailscaleStatus() }
        .onReceive(reachabilityTimer) { _ in
            if remoteServer.isRunning,
               remoteServer.companionAppMode == .hosted || remoteServer.hostMode == .tailscale {
                remoteServer.refreshTailscaleStatus()
            }
        }
    }

    @ViewBuilder
    private var tailscaleReadinessRow: some View {
        let ready = remoteServer.tailscaleServeReady
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: ready == true ? "checkmark.circle.fill"
                    : ready == false ? "exclamationmark.triangle.fill" : "ellipsis.circle")
                    .foregroundStyle(ready == true ? Color.green
                        : ready == false ? Color.orange : Color.secondary)
                Text(ready == true
                    ? "Reachable from your phone."
                    : ready == false
                        ? "`tailscale serve` isn't running on 443, so your phone can't reach this Mac yet."
                        : "Checking whether your phone can reach this Mac…")
                    .foregroundStyle(ready == false ? Color.orange : Color.secondary)
            }
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)

            if ready == false {
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
                            Text("Enable HTTPS access")
                        }
                    }
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(remoteServer.isEnablingServe)
                    .help("Run tailscale serve so your phone can reach this Mac over HTTPS")
                    .pointerOnHover()

                    Text("or set it up by hand with the guide next to Host.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                if let error = remoteServer.serveSetupError {
                    Text("Couldn't enable it automatically: \(error) You may need to run the command in Terminal (see the guide).")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private var connectHint: String {
        if remoteServer.token == nil { return "Starting the server…" }
        if remoteServer.companionAppMode == .hosted {
            return "Toki RC needs a Tailscale DNS host. Use the setup guide next to Host to turn on MagicDNS and HTTPS Serve."
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

// One-time Tailscale setup so the hosted Toki RC interface can reach this Mac over HTTPS.
// The hosted page is served over HTTPS and browsers block it from calling a plain-HTTP LAN
// address, so a tailnet HTTPS host is required for the connect-from-anywhere path.
private struct TailscaleSetupGuide: View {
    let port: Int

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
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                guideLink("Enabling HTTPS", "https://tailscale.com/kb/1153/enabling-https")
                guideLink("tailscale serve", "https://tailscale.com/kb/1242/tailscale-serve")
            }
        }
        .padding(16)
        .frame(width: 344, alignment: .leading)
    }

    @ViewBuilder
    private func step<Accessory: View>(
        _ number: Int,
        _ text: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold))
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
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .padding(.vertical, 5)
                .padding(.horizontal, 7)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                .fixedSize(horizontal: false, vertical: true)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(serveCommand, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy command")
            .accessibilityLabel("Copy the tailscale serve command")
            .pointerOnHover()
        }
    }

    private func guideLink(_ label: String, _ urlString: String) -> some View {
        Link(destination: URL(string: urlString)!) {
            HStack(spacing: 3) {
                Text(label)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11, weight: .medium))
        }
        .pointerOnHover()
    }
}
