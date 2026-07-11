import SwiftUI

struct HistoryPanel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if store.history.isEmpty {
                    EmptyPanel(systemImage: "chart.line.uptrend.xyaxis", title: "No history yet", detail: "Toki records local quota snapshots after refreshes.")
                } else {
                    ForEach(store.history.prefix(80)) { entry in
                        HStack(alignment: .center, spacing: 8) {
                            ProviderLogo(provider: entry.provider, size: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.accountName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                Text(entry.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(entry.remainingRatio.map(percentText) ?? "--")
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(entry.remainingRatio.map(historyColor) ?? .secondary)
                                Text(entry.primary)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                        )
                    }
                }
            }
            .padding(.trailing, 2)
        }
        .frame(maxHeight: accountListHeight())
    }

    private func historyColor(_ ratio: Double) -> Color {
        if ratio <= 0.15 { return .red }
        if ratio <= 0.40 { return .orange }
        return .primary
    }
}

struct EventPanel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    store.setDND(!store.preferences.dndEnabled)
                } label: {
                    Label(store.preferences.dndEnabled ? "DND On" : "DND Off", systemImage: store.preferences.dndEnabled ? "moon.zzz.fill" : "bell")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Toggle do not disturb")
                .pointerOnHover()

                Spacer()

                Button {
                    store.clearEvents()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .frame(width: 25, height: 25)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .help("Clear event history")
                .accessibilityLabel("Clear event history")
                .pointerOnHover()
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if store.events.isEmpty {
                        EmptyPanel(systemImage: "bell.badge", title: "No events yet", detail: "Low quota, session, switch, and notification events appear here.")
                    } else {
                        ForEach(store.events) { event in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: icon(for: event))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(color(for: event))
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(event.title)
                                            .font(.system(size: 12, weight: .semibold))
                                            .lineLimit(1)
                                        if event.deliveredNotification {
                                            Image(systemName: "bell.fill")
                                                .font(.system(size: 9))
                                                .foregroundStyle(.blue)
                                                .accessibilityHidden(true)
                                        }
                                    }
                                    Text(event.detail)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    Text(event.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                            }
                            .padding(8)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                            )
                        }
                    }
                }
                .padding(.trailing, 2)
            }
        }
        .frame(maxHeight: accountListHeight())
    }

    private func icon(for event: TokiEvent) -> String {
        switch event.kind {
        case .lowQuota: return "exclamationmark.triangle.fill"
        case .recovered: return "checkmark.circle.fill"
        case .switchAccount: return "arrow.triangle.2.circlepath"
        case .session: return "timer"
        case .notification: return event.deliveredNotification ? "bell.fill" : "bell.slash"
        case .refresh: return "arrow.clockwise"
        }
    }

    private func color(for event: TokiEvent) -> Color {
        switch event.kind {
        case .lowQuota: return .orange
        case .recovered: return .green
        case .switchAccount: return .blue
        case .session: return .purple
        case .notification: return event.deliveredNotification ? .blue : .secondary
        case .refresh: return .secondary
        }
    }
}

struct SettingsPanel: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updateChecker: UpdateChecker

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
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

                Button {
                    ConfigLoader.openInDefaultEditor()
                } label: {
                    Label("Open JSON config", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointerOnHover()

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
        .frame(maxHeight: accountListHeight())
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

struct EmptyPanel: View {
    var systemImage: String
    var title: String
    var detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}
