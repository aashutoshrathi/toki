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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
                    .toggleStyle(.switch)

                if launchAtLoginNeedsApproval {
                    HStack(spacing: 4) {
                        Text("Needs approval in System Settings > Login Items.")
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
                }

                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                }

                Toggle("Notifications", isOn: binding(\.notificationsEnabled))
                    .toggleStyle(.switch)

                Toggle("Do not disturb", isOn: Binding(
                    get: { store.preferences.dndEnabled },
                    set: { store.setDND($0) }
                ))
                .toggleStyle(.switch)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Low quota threshold \(percentText(store.preferences.lowQuotaThreshold))")
                        .font(.system(size: 11, weight: .semibold))
                    Slider(value: binding(\.lowQuotaThreshold), in: 0.05...0.50, step: 0.05)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Session warning \(percentText(store.preferences.sessionWarningThreshold))")
                        .font(.system(size: 11, weight: .semibold))
                    Slider(value: binding(\.sessionWarningThreshold), in: 0.05...0.40, step: 0.05)
                }

                Stepper("Cooldown \(store.preferences.notificationCooldownMinutes)m", value: intBinding(\.notificationCooldownMinutes), in: 5...360, step: 5)

                Stepper("History \(store.preferences.historyRetentionDays)d", value: intBinding(\.historyRetentionDays), in: 1...60, step: 1)

                Picker("Menu bar", selection: binding(\.menuBarMode)) {
                    ForEach(MenuBarDisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                if store.isAIInsightAvailable {
                    Divider()
                    AIInstructionsEditor(store: store)
                }

                Divider()

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("App updates")
                            .font(.system(size: 11, weight: .semibold))
                        if updateChecker.isChecking {
                            Text("Checking GitHub…")
                                .foregroundStyle(.secondary)
                        } else if let message = updateChecker.checkMessage {
                            Text(message)
                                .foregroundStyle(.secondary)
                        } else if let date = updateChecker.lastCheckedAt {
                            HStack(spacing: 3) {
                                Text("Checked")
                                Text(date, style: .relative)
                            }
                            .foregroundStyle(.secondary)
                        } else {
                            Text("Checks automatically every 6 hours")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 10))

                    Spacer()

                    Button {
                        updateChecker.checkNow()
                    } label: {
                        if updateChecker.isChecking {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Check now")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(updateChecker.isChecking)
                    .pointerOnHover()
                }

                Divider()

                ConfigEditor(store: store)

                HStack(spacing: 8) {
                    Button {
                        DiagnosticsReporter.presentSharePicker()
                    } label: {
                        Label("Send debug report", systemImage: "paperclip")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .pointerOnHover()

                    Button {
                        DiagnosticsReporter.openLogFolder()
                    } label: {
                        Label("Logs", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerOnHover()
                }
            }
            .font(.system(size: 12))
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )
        }
        .frame(maxHeight: .infinity)
        .onAppear(perform: refreshLaunchAtLoginState)
        // SMAppService's status can change out from under this view - e.g. the user
        // clicks "Open" above, approves the item in System Settings, then switches back
        // to Toki. Refresh on foreground so the toggle/note don't go stale until the next
        // manual flip.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLaunchAtLoginState()
        }
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
