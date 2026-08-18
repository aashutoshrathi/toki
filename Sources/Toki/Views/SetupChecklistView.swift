import AppKit
import SwiftUI

// The permissions Toki needs, as a list you work through, instead of dialogs that arrive while
// you are doing something else. Nothing here asks macOS for anything until a button is pressed;
// the statuses come from checks that never prompt.
//
// A first run lists everything Toki will ever ask for - including the ones that don't apply yet -
// and can request them all in one pass, so a fresh install ends up working rather than working
// once you have discovered each feature and answered its dialog.
struct SetupChecklistView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject private var remoteServer = RemoteControlServer.shared
    var mode: SetupChecklistMode = .ongoing
    /// The onboarding copy introduces itself; the Settings card sits under a heading already.
    var showsHeader = true
    /// Settings keeps the list around permanently; onboarding lets it be put away once done.
    var showsDismiss = false
    /// The Settings card folds the whole list behind a one-line summary until it is opened.
    var collapsible = false

    @State private var steps: [SetupStep] = []
    @State private var expanded = false
    @State private var busyStepID: String?
    @State private var requestingAll = false
    @State private var currentRequest: String?
    @State private var notificationTestSent = false
    @State private var launchAtLoginError: String?

    private var outstanding: [SetupStep] { SetupChecklist.outstanding(steps) }
    private var requestable: [SetupStep] { SetupChecklist.requestOrder(steps) }
    private var grantedCount: Int { steps.filter { $0.status == .done }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if collapsible {
                collapsibleHeader
            } else if showsHeader {
                header
            }

            if !collapsible || expanded {
                VStack(spacing: 4) {
                    ForEach(steps) { step in
                        row(for: step)
                    }
                }

                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.system(size: 9))
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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Permissions")
                .font(.system(size: 13, weight: .semibold))
            Text(headerDetail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var collapsibleHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(width: 18, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Permissions")
                        .font(.system(size: 12, weight: .semibold))
                    Text(collapsedSummary)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if !outstanding.isEmpty {
                    Text("\(outstanding.count) to allow")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerOnHover()
    }

    private var collapsedSummary: String {
        guard !steps.isEmpty else { return "Checking what Toki has been granted…" }
        return "\(grantedCount) of \(steps.count) granted — what Toki asks macOS for, and why."
    }

    private var headerDetail: LocalizedStringKey {
        if requestingAll {
            return "Answer each dialog as it appears. Refusing one only turns off what it was for."
        }
        if requestable.isEmpty {
            return "Nothing left to allow. Everything Toki asks macOS for is listed here, with what it is used for."
        }
        return "Everything Toki asks macOS for, and why. Grant them now, or one at a time as you use the features - nothing is requested until you press a button."
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            if mode == .firstRun, !requestable.isEmpty {
                Button(action: requestEverything) {
                    if requestingAll {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                            Text(currentRequest.map { "Asking: \($0)" } ?? "Asking…")
                        }
                    } else {
                        Label("Allow all \(requestable.count)", systemImage: "checkmark.shield")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(requestingAll || busyStepID != nil)
                .help("Ask for each permission in turn, one dialog at a time")
                .pointerOnHover()
            }

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
                .disabled(requestingAll)
                .pointerOnHover()
            }
        }
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
                    if busyStepID == step.id {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    } else {
                        Text(label)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .disabled(busyStepID != nil || requestingAll)
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
        Task {
            let facts = await SetupChecklist.currentFacts(store: store, remoteControlRunning: remoteServer.isRunning)
            steps = SetupChecklist.steps(from: facts, mode: mode)
        }
    }

    // Awaiting the refresh matters inside the "allow all" pass: each request has to see the list
    // as it stands after the previous answer, or a permission granted along the way gets asked
    // for twice.
    private func refreshAndWait() async {
        let facts = await SetupChecklist.currentFacts(store: store, remoteControlRunning: remoteServer.isRunning)
        steps = SetupChecklist.steps(from: facts, mode: mode)
    }

    // One dialog at a time, in an order that ends with the one that sends you to System Settings.
    // The list is rebuilt between requests so anything answered along the way drops out.
    private func requestEverything() {
        guard !requestingAll else { return }
        requestingAll = true
        Task {
            var handled: Set<String> = []
            while let next = SetupChecklist.requestOrder(steps).first(where: { !handled.contains($0.id) }) {
                handled.insert(next.id)
                currentRequest = next.title
                await request(next)
                await refreshAndWait()
            }
            currentRequest = nil
            requestingAll = false
        }
    }

    private func perform(_ step: SetupStep) {
        // Rows that only open System Settings act immediately; a real request goes through the
        // same path as the "allow all" pass so the two can't drift apart.
        guard step.isRequestable else {
            switch step.kind {
            case .account: store.rescanProviders()
            case .automation: SystemPermissions.openPrivacySettings(anchor: "Privacy_Automation")
            case .localNetwork: SystemPermissions.openPrivacySettings(anchor: "Privacy_LocalNetwork")
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
            // Delivery returns immediately and macOS decides for itself when to put its own
            // notification prompt on screen, so unlike the others this one cannot be sequenced -
            // it may land alongside the next dialog. Bringing it forward at all is the point.
            store.sendTestNotification()
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
        case .account, .localNetwork:
            break
        }
    }
}
