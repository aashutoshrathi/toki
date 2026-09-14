import AppKit
import SwiftUI

// Status checks never prompt. Required usage access stays separate from optional integrations,
// so a user can connect accounts without being encouraged to grant access for unused features.
struct SetupChecklistPresentation {
    let steps: [SetupStep]
    let hasClaudeAccount: Bool

    func isRequired(_ step: SetupStep) -> Bool {
        if step.kind == .claudeKeychain { return hasClaudeAccount }
        return !step.isOptional && step.kind != .notifications
    }

    var required: [SetupStep] { steps.filter(isRequired) }
    var optional: [SetupStep] { steps.filter { !isRequired($0) } }
    var requiredOutstanding: [SetupStep] { SetupChecklist.outstanding(required) }

    var summary: String {
        if steps.isEmpty { return "Checking access…" }
        if requiredOutstanding.isEmpty { return "Usage access is ready" }
        let count = requiredOutstanding.count
        return "\(count) required \(count == 1 ? "step needs" : "steps need") attention"
    }
}

struct SetupChecklistView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject private var remoteServer = RemoteControlServer.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var mode: SetupChecklistMode = .ongoing
    /// The onboarding copy introduces itself; the Settings card sits under a heading already.
    var showsHeader = true
    /// Settings keeps the list around permanently; onboarding lets it be put away once done.
    var showsDismiss = false
    /// First run folds the list behind a summary so connecting an account stays primary.
    var collapsible = false
    /// False where a section header already names this list, so the row leads with its status.
    var showsCollapsedTitle = true

    @State private var steps: [SetupStep] = []
    @State private var expanded = false
    @State private var busyStepID: String?
    @State private var optionalExpanded = true
    @State private var notificationTestSent = false
    /// Sticky for the life of this view: once Toki has sent someone to the Accessibility pane,
    /// the row keeps offering the restart that makes a grant made over there take effect.
    @State private var accessibilityRequested = false
    @State private var launchAtLoginError: String?

    private var presentation: SetupChecklistPresentation {
        SetupChecklistPresentation(
            steps: steps,
            hasClaudeAccount: store.snapshots.contains { $0.provider.isClaudeAccount }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if collapsible {
                HStack(alignment: .top, spacing: 8) {
                    collapsibleHeader
                    if showsDismiss { dismissButton }
                }
            } else if showsHeader {
                header
            }

            if !collapsible || expanded {
                stepRows

                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                footer
            }
        }
        .onAppear(perform: refresh)
        // TCC decisions are made outside Toki, so the list is re-read whenever the app comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        .onChange(of: store.snapshots.count) { refresh() }
        .onChange(of: remoteServer.isRunning) { refresh() }
        // The "test sent" note answers one press. Leaving it up across a collapse or a
        // notifications toggle left the row describing something that happened minutes ago.
        .onChange(of: expanded) { notificationTestSent = false }
        .onChange(of: store.preferences.notificationsEnabled) { notificationTestSent = false }
    }

    /// A first-run checklist shares the fixed popover with account discovery, so only the rows
    /// scroll; the dismiss action stays alongside its heading.
    @ViewBuilder
    private var stepRows: some View {
        let rows = VStack(alignment: .leading, spacing: 12) {
            if !presentation.required.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Required for usage")
                        .font(.system(size: 13, weight: .semibold))
                    ForEach(presentation.required) { step in
                        row(for: step)
                    }
                }
            }
            if !presentation.optional.isEmpty {
                DisclosureGroup(isExpanded: $optionalExpanded) {
                    VStack(spacing: 4) {
                        ForEach(presentation.optional) { step in
                            row(for: step)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Optional integrations")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Enable access when you use a feature. Usage tracking works without these permissions.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }

        if mode == .firstRun {
            ScrollView(.vertical) { rows }
                .frame(maxHeight: popoverHeight() / 2)
                .scrollBounceBehavior(.basedOnSize)
        } else {
            rows
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Permissions")
                    .font(.system(size: 13, weight: .semibold))
                Text(headerDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Above the list rather than under it: this is the way out of the checklist, and
            // under a list long enough to overflow the popover it was the part that fell off.
            if showsDismiss {
                Spacer(minLength: 8)
                dismissButton
            }
        }
    }

    private var dismissButton: some View {
        Button(presentation.requiredOutstanding.isEmpty ? "Done" : "Skip for now") {
            store.completeSetupChecklist()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .disabled(busyStepID != nil)
        .pointerOnHover()
    }

    private var collapsibleHeader: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 12))
                    .foregroundStyle(presentation.requiredOutstanding.isEmpty ? Color.green : Color.orange)
                    .frame(width: 18, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(showsCollapsedTitle ? "Permissions" : presentation.summary)
                        .font(.system(size: 12, weight: .semibold))
                    Text(showsCollapsedTitle ? presentation.summary : "Optional integrations can be enabled when needed.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerOnHover()
    }

    private var headerDetail: LocalizedStringKey {
        "Required access supports your connected accounts. Optional integrations can be enabled when you use their features. Nothing is requested until you press a button."
    }

    private var footer: some View {
        Button("Re-check", action: refresh)
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .help("Permissions can be changed in System Settings; this reads them again")
            .disabled(busyStepID != nil)
            .pointerOnHover()
    }

    private func row(for step: SetupStep) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon(for: step.status))
                .font(.system(size: 12))
                .foregroundStyle(color(for: step.status))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(step.title)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                Text(detailText(for: step))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 6) {
                // macOS decides whether a notification appears and won't say after the fact, so the only
                // honest follow-up is a way to go and look.
                if step.kind == .notifications, notificationTestSent {
                    Button("Open Settings") {
                        SystemPermissions.openNotificationSettings()
                    }
                    .controlSize(.small)
                    .fixedSize()
                    .pointerOnHover()
                }

                if let label = step.actionLabel {
                    Button {
                        perform(step)
                    } label: {
                        ZStack {
                            Text(label)
                                .opacity(busyStepID == step.id ? 0 : 1)
                            if busyStepID == step.id {
                                ProgressView().controlSize(.small).scaleEffect(0.6)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(busyStepID != nil)
                    .pointerOnHover()
                }
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
        Task { await refreshAndWait() }
    }

    private func refreshAndWait() async {
        let facts = await SetupChecklist.currentFacts(
            store: store,
            remoteControlRunning: remoteServer.isRunning,
            accessibilityRequested: accessibilityRequested
        )
        steps = SetupChecklist.steps(from: facts, mode: mode)
    }

    private func perform(_ step: SetupStep) {
        // macOS cannot repeat a denied request; those rows open the relevant settings pane.
        guard step.isRequestable else {
            switch step.kind {
            case .account: store.rescanProviders()
            case .automation: SystemPermissions.openPrivacySettings(anchor: "Privacy_Automation")
            case .localNetwork: SystemPermissions.openPrivacySettings(anchor: "Privacy_LocalNetwork")
            // Reachable once macOS has been told no: it will not ask again, so the row's only
            // remaining action is to open the pane where that can be undone.
            case .notifications: SystemPermissions.openNotificationSettings()
            // The row only offers this once it has already sent the user to System Settings,
            // so the remaining step is the restart that makes a grant there take effect.
            case .accessibility: SystemPermissions.relaunch()
            default: break
            }
            recheck()
            return
        }
        busyStepID = step.id
        Task {
            await request(step)
            busyStepID = nil
            await refreshAndWait()
            recheck()
        }
    }

    // A grant answered in a system dialog or over in System Settings can land a beat after the
    // button returns, so re-read the list a couple more times rather than showing a stale status
    // until the user thinks to press Re-check.
    private func recheck() {
        Task {
            for delay in [0.6, 1.8] as [Double] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await refreshAndWait()
            }
        }
    }

    private func request(_ step: SetupStep) async {
        switch step.kind {
        case .claudeKeychain:
            // Reading it is what raises the system dialog, so the answer is only remembered once
            // the user has asked for the read here.
            await store.approveKeychainReads()
        case .notifications:
            // Now sequenced like the rest: asking macOS for permission is a real dialog that
            // can be awaited, so it no longer risks landing on top of the next one.
            await store.sendTestNotification()
            notificationTestSent = true
        case .automation:
            guard let bundleID = step.subject else { return }
            _ = await SystemPermissions.requestAutomation(bundleID: bundleID)
        case .launchAtLogin:
            do {
                try LaunchAtLogin.setEnabled(true)
                launchAtLoginError = nil
            } catch {
                launchAtLoginError = "Couldn't turn on Launch at login: \(error.localizedDescription)"
            }
        case .accessibility:
            SystemPermissions.requestAccessibility()
            accessibilityRequested = true
        case .account, .localNetwork:
            break
        }
    }
}
