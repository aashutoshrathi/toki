import AppKit
import SwiftUI

private enum SettingsAnchor: Hashable {
    case remoteControl
}

// Top-level "where can my phone reach this Mac" choice, mapped onto the underlying host/app modes.
private enum ReachMode: Hashable {
    case network
    case anywhere
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
    @State private var advancedExpanded = false
    @State private var showingTailscaleGuide = false
    private let reachabilityTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("Remote Control")

                    remoteControlCard
                        .id(SettingsAnchor.remoteControl)

                    sectionHeader("Permissions")

                    permissionsCard

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

                menuBarCard

                // Sits directly under the menu bar picker: it decides where the readout lives,
                // so it belongs with the other placement settings rather than below the
                // notification thresholds it had nothing to do with.
                if NotchWindowController.isSupported {
                    notchModeRow
                }

                sectionHeader("Layout")

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
                Divider()
                    .padding(.leading, 34)
                pinnedProvidersRow
            }

            // Logo-only draws no numbers, so there is no density for it to change.
            if store.preferences.menuBarMode != .logoOnly {
                Divider()
                    .padding(.leading, 34)
                HStack(spacing: 8) {
                    Text("Size")
                        .font(.system(size: 11, weight: .semibold))
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
                    .help("Compact shrinks the text and drops the percent sign; Stacked puts two providers on two rows")
                }
                .padding(8)
            }
        }
        .settingsCard()
    }

    // Driven off connected accounts rather than the full Provider list, so the choices are
    // ones that can actually show a number.
    private var pinnableProviders: [Provider] {
        var seen: Set<Provider> = []
        return store.snapshots.filter { !$0.isError }.map(\.provider).filter { seen.insert($0).inserted }
    }

    @ViewBuilder
    private var pinnedProvidersRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if pinnableProviders.isEmpty {
                Text("Connect an account to pick what the menu bar pins.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(pinnableProviders, id: \.self) { provider in
                        pinToggle(for: provider)
                    }
                }
                Text("Shows up to three, in the order you pin them. Pin nothing and Toki falls back to Smart.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .padding(.leading, 18)
    }

    private func pinToggle(for provider: Provider) -> some View {
        let isPinned = store.preferences.menuBarPinnedProviders.contains(provider)
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
                    .font(.system(size: 10, weight: isPinned ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isPinned ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08), in: Capsule())
            .overlay(
                Capsule().strokeBorder(isPinned ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .pointerOnHover()
        .accessibilityLabel("\(provider.displayName)\(isPinned ? ", pinned" : "")")
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
                    .padding(.leading, 34)
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
    // Roomier than the other cards on purpose: it is the tallest one in the panel, stacking a
    // toggle, two pickers, an explanation, a disclosure, and up to three advisory notes, and
    // at the shared 8pt rhythm those ran together into a wall.
    private var remoteControlCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                cardLabel(
                    icon: "antenna.radiowaves.left.and.right",
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
                Toggle("", isOn: Binding(
                    get: { remoteServer.isRunning },
                    set: { $0 ? remoteServer.start() : remoteServer.stop() }
                ))
                .accessibilityLabel("Remote Control Server")
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            Picker("Reach", selection: reachBinding) {
                Text("On my network").tag(ReachMode.network)
                Text("From anywhere").tag(ReachMode.anywhere)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .padding(.horizontal, 4)

            Text(reachBinding.wrappedValue == .network
                ? "Your phone connects over Wi-Fi on the same network. No setup."
                : "Reach this Mac from any network over HTTPS. Tailscale is recommended: it stays off the public internet.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 8) {
                advancedHeader
                if advancedExpanded {
                VStack(alignment: .leading, spacing: 8) {
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
                            // The server is told which custom host to answer to when it launches,
                            // so editing this while running would hand out a Connect link for a
                            // name the running server rejects.
                            TextField("host or IP", text: $remoteServer.customHost)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)
                                .disabled(remoteServer.isRunning)
                                .help(remoteServer.isRunning
                                    ? "Stop Remote Control to change the custom host"
                                    : "The host your phone will use to reach this Mac")
                        }
                        Spacer(minLength: 0)
                    }

                    if remoteServer.hostMode == .tailscale, remoteServer.tailscaleDNSName == nil {
                        VStack(alignment: .leading, spacing: 4) {
                            if let diagnostic = remoteServer.tailscaleStatusDiagnostic,
                               !remoteServer.hasUsableTailscaleHost {
                                Text(diagnostic)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            TextField("your-mac.tailnet.ts.net", text: $remoteServer.manualTailscaleHost)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)
                                .autocorrectionDisabled()
                            Text("Enter your Mac's Tailscale name to build a Connect link.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.leading, 56)
                    }

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
                }
                .padding(.top, 6)
                }
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

            pairedDevicesSection

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
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
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

    private func copyCommandButton(_ command: String, label: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        } label: {
            Label(label, systemImage: "doc.on.doc")
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
                            .font(.system(size: 10))
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

                        Text("or set it up by hand with the guide next to Host.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                // Toki declined to run serve itself; saying so beats a warning that looks like nothing happened.
                if remoteServer.serveSetupFailure == nil, let skipped = remoteServer.autoServeSkipped {
                    Text(skipped)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let failure = remoteServer.serveSetupFailure {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(failure.message)
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        if let remedy = failure.remedy {
                            HStack(spacing: 6) {
                                Text(remedy)
                                    .font(.system(size: 10).monospaced())
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
        .padding(.horizontal, 4)
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
            return "Toki RC needs a Tailscale DNS host. Use the setup guide next to Host to turn on MagicDNS and HTTPS Serve."
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

    private enum ExposureLevel {
        case info
        case warning
    }

    private func exposureNote(_ text: String, level: ExposureLevel) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: level == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(level == .warning ? Color.orange : Color.secondary)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    // Every phone currently holding a session, so a device you no longer recognise can be cut off
    // without stopping the server on everyone else.
    @ViewBuilder
    private var pairedDevicesSection: some View {
        if remoteServer.isRunning, !remoteServer.pairedDevices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Paired devices")
                    .font(.system(size: 10, weight: .semibold))
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
                                .font(.system(size: 9))
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
            .padding(.horizontal, 4)
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
        SetupChecklistView(store: store, showsHeader: false, collapsible: true)
            .padding(8)
            .settingsCard()
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

    private var advancedHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { advancedExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(advancedExpanded ? 90 : 0))
                Text("Advanced")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
