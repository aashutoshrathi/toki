import AppKit
import SwiftUI

// The permissions Toki needs, as a list you work through, instead of dialogs that arrive while
// you are doing something else. Nothing here asks macOS for anything until a row's button is
// pressed; the statuses come from checks that never prompt.
struct SetupChecklistView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject private var remoteServer = RemoteControlServer.shared
    /// The onboarding copy introduces itself; the Settings card sits under a heading already.
    var showsHeader = true
    /// Settings keeps the list around permanently; onboarding lets it be put away once done.
    var showsDismiss = false

    @State private var steps: [SetupStep] = []
    @State private var busyStepID: String?
    @State private var notificationTestSent = false

    private var outstanding: [SetupStep] { SetupChecklist.outstanding(steps) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Finish setting up")
                        .font(.system(size: 13, weight: .semibold))
                    Text(outstanding.isEmpty
                        ? "Nothing left to allow. Toki asks for each of these only when you use the feature behind it."
                        : "Toki asks for these one at a time, when you say so - never in the background.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 4) {
                ForEach(steps) { step in
                    row(for: step)
                }
            }

            HStack(spacing: 10) {
                Button("Re-check", action: refresh)
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("Permissions can be changed in System Settings; this reads them again")
                    .pointerOnHover()

                if showsDismiss {
                    Button(outstanding.isEmpty ? "Done" : "Skip for now") {
                        store.completeSetupChecklist()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .pointerOnHover()
                }
            }
        }
        .onAppear(perform: refresh)
        // TCC decisions are made outside Toki, so the list is re-read whenever the app comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        .onChange(of: store.snapshots.count) { refresh() }
        .onChange(of: remoteServer.isRunning) { refresh() }
    }

    private func row(for step: SetupStep) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon(for: step.status))
                .font(.system(size: 12))
                .foregroundStyle(color(for: step.status))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(step.title)
                        .font(.system(size: 11, weight: .semibold))
                    if step.isOptional {
                        Text("optional")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.fill.quaternary, in: Capsule())
                    }
                }
                Text(detailText(for: step))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            if let label = step.actionLabel {
                Button {
                    perform(step)
                } label: {
                    if busyStepID == step.id {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    } else {
                        Text(label)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .disabled(busyStepID != nil)
                .pointerOnHover()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private func detailText(for step: SetupStep) -> String {
        if step.kind == .notifications, notificationTestSent {
            return "Test sent. If nothing appeared, allow Toki under Notifications in System Settings."
        }
        return step.detail
    }

    private func icon(for status: SetupStepStatus) -> String {
        switch status {
        case .done: return "checkmark.circle.fill"
        case .pending: return "circle"
        case .blocked: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private func color(for status: SetupStepStatus) -> Color {
        switch status {
        case .done: return .green
        case .pending: return .secondary
        case .blocked: return .orange
        case .unknown: return .secondary
        }
    }

    private func refresh() {
        steps = SetupChecklist.steps(
            from: SetupChecklist.currentFacts(store: store, remoteControlRunning: remoteServer.isRunning)
        )
    }

    private func perform(_ step: SetupStep) {
        switch step.kind {
        case .account:
            store.rescanProviders()
        case .claudeKeychain:
            // Reading it is what raises the system dialog, so the answer is only remembered after
            // the user has asked for the read here.
            store.approveKeychainReads()
        case .notifications:
            store.sendTestNotification()
            notificationTestSent = true
        case .automation:
            guard let bundleID = step.subject else { return }
            guard step.status != .blocked else {
                SystemPermissions.openPrivacySettings(anchor: "Privacy_Automation")
                return
            }
            busyStepID = step.id
            Task {
                _ = await SystemPermissions.requestAutomation(bundleID: bundleID)
                busyStepID = nil
                refresh()
            }
        case .accessibility:
            SystemPermissions.requestAccessibility()
        case .localNetwork:
            SystemPermissions.openPrivacySettings(anchor: "Privacy_LocalNetwork")
        }
        refresh()
    }
}
