import AppKit
import ApplicationServices
import CoreServices

/// Where a permission stands, from a check that never puts a dialog up on its own.
enum SetupStepStatus: Equatable, Sendable {
    /// Granted, or done.
    case done
    /// Not granted yet, and asking for it is the step's action.
    case pending
    /// Refused earlier. macOS will not ask again, so the only route left is System Settings.
    case blocked
    /// macOS offers no way to read this one without asking for it.
    case unknown
}

enum SetupStepID: String, CaseIterable, Identifiable {
    case account
    case claudeKeychain
    case notifications
    case automation
    case launchAtLogin
    case accessibility
    case localNetwork

    var id: String { rawValue }
}

/// A first run lists everything Toki will ever ask for, so the whole cost is visible at once and
/// can be granted in one pass. Afterwards the list is a status board and only shows what applies
/// to the Mac right now.
enum SetupChecklistMode {
    case firstRun
    case ongoing
}

/// One row of the setup checklist. Built by `SetupChecklist.steps(from:)` from plain facts, so
/// what the list says for a given machine is testable without a machine.
struct SetupStep: Identifiable, Equatable {
    let kind: SetupStepID
    /// What this row is about when one kind can appear more than once - the bundle id of the
    /// terminal, for the per-app Automation rows.
    let subject: String?
    let title: String
    let detail: String
    let status: SetupStepStatus
    /// nil when there is nothing for Toki to ask for - the row is there to explain, not to act.
    let actionLabel: String?
    /// True when Toki works without it and the row is only worth showing while it is missing.
    let isOptional: Bool
    /// True when pressing the button puts a real macOS request in front of the user. False for
    /// rows that only open System Settings or explain something Toki cannot ask for on its own,
    /// which is what keeps those out of the "ask for everything" pass.
    let isRequestable: Bool
    /// True when an `.unknown` row is still unfinished work, not the benign kind (a closed terminal
    /// Toki can't read) - a required read that failed keeps onboarding from reading as done.
    let blocksCompletion: Bool

    var id: String { subject.map { "\(kind.rawValue).\($0)" } ?? kind.rawValue }

    init(
        kind: SetupStepID,
        subject: String? = nil,
        title: String,
        detail: String,
        status: SetupStepStatus,
        actionLabel: String?,
        isOptional: Bool = false,
        isRequestable: Bool = false,
        blocksCompletion: Bool = false
    ) {
        self.kind = kind
        self.subject = subject
        self.title = title
        self.detail = detail
        self.status = status
        self.actionLabel = actionLabel
        self.isOptional = isOptional
        self.isRequestable = isRequestable
        self.blocksCompletion = blocksCompletion
    }
}

/// What the checklist needs to know about this Mac. Gathered by `SetupChecklist.currentFacts`,
/// which is the only part that touches the system.
struct SetupFacts: Equatable {
    var hasConnectedAccount = false
    /// Whether the user has agreed to Toki reading the Claude Code sign-in out of the Keychain.
    var keychainApproved = false
    /// A Claude Code sign-in was actually read - the row reports this rather than the gate.
    var claudeSignInFound = false
    /// A Claude account exists in config, so failing to read a sign-in is a problem worth naming.
    var claudeAccountConfigured = false
    var notificationsEnabled = true
    /// What macOS says, as opposed to whether Toki's own switch is on. Both matter: Toki can be
    /// set to notify while macOS refuses to show any of it.
    var notificationAuthorization = NotificationAuthorization.notDetermined
    /// Terminals installed on this Mac that Toki types replies into, with where each one stands.
    var automation: [AutomationTarget] = []
    /// Relevant while Toki must inspect another app's UI: a workspace editor for navigation, or
    /// Ghostty while Remote Control is mirroring a bare terminal through its AX text area.
    var workspaceAppRunning = false
    var ghosttyScreenCaptureNeeded = false
    var accessibilityGranted = false
    /// True once Toki has sent the user to the Accessibility pane in this run. A grant made
    /// over there does not reach a process that is already running, so this is what separates
    /// "not asked yet" from "asked, and still not trusted", which need different advice.
    var accessibilityRequested = false
    var remoteControlRunning = false
    var launchAtLoginEnabled = false
}

struct AutomationTarget: Equatable, Identifiable, Sendable {
    let name: String
    let bundleID: String
    let status: SetupStepStatus

    var id: String { bundleID }
}

// Toki asks for a handful of unrelated permissions, and until now each one arrived as a side
// effect of something else: the Keychain dialog on first opening the menu, Automation the first
// time you clicked an agent, Local Network when Remote Control started. This turns them into a
// list you can read, where nothing is asked for until you ask for it.
enum SetupChecklist {
    // Pure: every fact comes in, no probing happens here, so the wording and the ordering can be
    // tested without granting anything.
    static func steps(from facts: SetupFacts, mode: SetupChecklistMode = .ongoing) -> [SetupStep] {
        var steps: [SetupStep] = []
        let isFirstRun = mode == .firstRun

        steps.append(SetupStep(
            kind: .account,
            title: "Connect an account",
            detail: facts.hasConnectedAccount
                ? "Toki is reading usage from your coding agents."
                : "Sign in to a supported agent, or connect one Toki already found.",
            status: facts.hasConnectedAccount ? .done : .pending,
            actionLabel: facts.hasConnectedAccount ? nil : "Scan again"
        ))

        // Reading the sign-in Claude Code stored puts up the system's Keychain dialog, so on a
        // fresh install Toki waits to be told to look rather than doing it while you open a menu.
        // Once allowed, the row reports what the read produced, not just that the gate is open.
        if !facts.keychainApproved {
            steps.append(SetupStep(
                kind: .claudeKeychain,
                title: "Read your Claude Code sign-in",
                detail: "Claude Code keeps its token in your Keychain, and macOS asks you to allow Toki once. Without it, Claude Code quota can't be shown.",
                status: .pending,
                actionLabel: "Allow",
                isRequestable: true
            ))
        } else if facts.claudeSignInFound {
            steps.append(SetupStep(
                kind: .claudeKeychain,
                title: "Read your Claude Code sign-in",
                detail: "Toki is reading the token Claude Code stored in your Keychain.",
                status: .done,
                actionLabel: nil
            ))
        } else if facts.claudeAccountConfigured || isFirstRun {
            // Allowed but nothing read back (a denied dialog, or a Claude Code never signed in):
            // worth another look rather than a row claiming everything is fine.
            steps.append(SetupStep(
                kind: .claudeKeychain,
                title: "Read your Claude Code sign-in",
                detail: "Toki couldn't read a Claude Code sign-in. If macOS asked and the answer was Deny, try again and choose Always Allow; if Claude Code isn't signed in, run /login there first.",
                status: .unknown,
                actionLabel: "Try again",
                isRequestable: true,
                blocksCompletion: facts.claudeAccountConfigured
            ))
        }

        steps.append(notificationStep(facts))

        // Only for terminals actually installed: an Automation row for an app that isn't here
        // asks for a permission that can never be used.
        for target in facts.automation {
            steps.append(SetupStep(
                kind: .automation,
                subject: target.bundleID,
                title: "Control \(target.name)",
                detail: automationDetail(for: target),
                status: target.status,
                actionLabel: target.status == .done ? nil : (target.status == .blocked ? "Open Settings" : "Allow"),
                isOptional: true,
                // `.unknown` means the app is closed and macOS won't say; asking launches it and finds out.
                isRequestable: target.status == .pending || target.status == .unknown
            ))
        }

        // On a first run this is listed whether or not an editor is open right now: the point is
        // to show the whole cost up front, not to wait until the click that needs it.
        if !facts.accessibilityGranted,
           isFirstRun || facts.workspaceAppRunning || facts.ghosttyScreenCaptureNeeded {
            steps.append(accessibilityStep(facts))
        }

        if isFirstRun || facts.remoteControlRunning {
            steps.append(SetupStep(
                kind: .localNetwork,
                title: "Local network",
                // The one permission Toki cannot bring forward: macOS asks when the server first
                // answers a device, so there is nothing to request here, only something to expect.
                detail: facts.remoteControlRunning
                    ? "Remote Control answers your phone over the network, which macOS asks about the first time. Without it the phone can't reach this Mac."
                    : "Answering agents from your phone needs this, and macOS asks for it when you turn Remote Control on - not now.",
                status: facts.remoteControlRunning ? .unknown : .done,
                actionLabel: facts.remoteControlRunning ? "Open Settings" : nil,
                isOptional: true
            ))
        }

        // Not a permission, but the other half of a fresh install actually working: a menu bar app
        // that isn't running tracks nothing.
        if isFirstRun {
            steps.append(SetupStep(
                kind: .launchAtLogin,
                title: "Start Toki when you sign in",
                detail: facts.launchAtLoginEnabled
                    ? "Toki starts with your Mac, so quota and agents are tracked without opening it."
                    : "Toki only tracks usage while it is running. Starting it at login means nothing is missed.",
                status: facts.launchAtLoginEnabled ? .done : .pending,
                actionLabel: facts.launchAtLoginEnabled ? nil : "Turn on",
                isOptional: true,
                isRequestable: !facts.launchAtLoginEnabled
            ))
        }

        return steps
    }

    // Accessibility is granted in System Settings, not in a dialog Toki can wait on, and macOS
    // only hands the new trust to a process when it starts. So a user who has just ticked the
    // box comes back to a row still reading "Allow", which looks like the grant did not take.
    // Once Toki has sent someone over there, the row says what is actually needed instead.
    private static func accessibilityStep(_ facts: SetupFacts) -> SetupStep {
        guard facts.accessibilityRequested else {
            return SetupStep(
                kind: .accessibility,
                title: "Accessibility",
                detail: accessibilityDetail(facts),
                status: .pending,
                actionLabel: "Allow",
                isOptional: true,
                isRequestable: true
            )
        }

        return SetupStep(
            kind: .accessibility,
            title: "Accessibility",
            detail: "If you have ticked Toki under Privacy & Security › Accessibility, restart it to pick that up: macOS only hands the new trust to Toki when it starts. Toki is ad-hoc signed until it has a Developer ID, and macOS ties the tick to that signature, so an update can drop it and need ticking again.",
            status: .pending,
            actionLabel: "Restart Toki",
            isOptional: true
        )
    }

    private static func accessibilityDetail(_ facts: SetupFacts) -> String {
        if facts.workspaceAppRunning && facts.ghosttyScreenCaptureNeeded {
            return "Used to raise the right VS Code window and to mirror a bare Ghostty terminal in Remote Control."
        }
        if facts.ghosttyScreenCaptureNeeded {
            return "Used to mirror a bare Ghostty terminal in Remote Control. Sending replies only needs Ghostty Automation permission."
        }
        if facts.workspaceAppRunning {
            return "Only used to raise the right VS Code window when you click an agent running in it."
        }
        return "Used for exact VS Code window navigation and bare Ghostty screen mirroring. Skip it if you need neither."
    }

    // Two independent switches: Toki's own preference, and what macOS has been told. The row
    // used to report only the first and always sat at `.unknown`, which is how a build that
    // could not deliver anything still looked like it might be fine.
    private static func notificationStep(_ facts: SetupFacts) -> SetupStep {
        guard facts.notificationsEnabled else {
            return SetupStep(
                kind: .notifications,
                title: "Notifications",
                detail: "Turned off in Toki, so nothing is delivered and macOS is never asked.",
                status: .done,
                actionLabel: nil
            )
        }

        switch facts.notificationAuthorization {
        case .authorized:
            return SetupStep(
                kind: .notifications,
                title: "Notifications",
                detail: "macOS is letting Toki through. You will hear about low quota and agents waiting on you.",
                status: .done,
                actionLabel: "Send a test",
                isRequestable: true
            )
        case .notDetermined:
            return SetupStep(
                kind: .notifications,
                title: "Notifications",
                detail: "Toki tells you when quota runs low or an agent is waiting on you. macOS has not been asked yet.",
                status: .pending,
                actionLabel: "Allow",
                isRequestable: true
            )
        case .denied:
            // macOS will not ask twice, so the only route left is System Settings.
            return SetupStep(
                kind: .notifications,
                title: "Notifications",
                detail: "macOS is set to not allow notifications from Toki, so low-quota and agent warnings will not appear. Turn them on under Notifications in System Settings.",
                status: .blocked,
                actionLabel: "Open Settings"
            )
        case .unavailable(let reason):
            return SetupStep(
                kind: .notifications,
                title: "Notifications",
                detail: reason,
                status: .unknown,
                actionLabel: nil
            )
        }
    }

    private static func automationDetail(for target: AutomationTarget) -> String {
        switch target.status {
        case .blocked:
            return "Refused earlier, so replies can't reach agents running in \(target.name). Allow Toki under Privacy & Security › Automation."
        case .unknown:
            return "\(target.name) isn't running, so macOS won't say yet. Allow opens it and asks."
        default:
            return "Lets Toki jump to an agent's tab, and type your replies from Remote Control into it."
        }
    }

    /// Steps still worth acting on - what the badge counts.
    static func outstanding(_ steps: [SetupStep]) -> [SetupStep] {
        steps.filter {
            $0.status == .pending || $0.status == .blocked || ($0.status == .unknown && $0.blocksCompletion)
        }
    }

    // What "allow everything" actually runs, in the order it runs them. Each request is a dialog,
    // so they go one at a time; Accessibility is last because answering it means leaving for
    // System Settings, and coming back to three more dialogs would be worse than finding them.
    static func requestOrder(_ steps: [SetupStep]) -> [SetupStep] {
        let rank: [SetupStepID: Int] = [
            .claudeKeychain: 0,
            .notifications: 1,
            .automation: 2,
            .launchAtLogin: 3,
            .accessibility: 4
        ]
        // `.unknown` counts: notifications can't be read back, and skipping them would leave the
        // one prompt this pass exists to bring forward for the first low-quota warning instead.
        // Swift's sort isn't stable, so the original position breaks ties - two terminals must
        // not swap places between two renders of the same list.
        return steps
            .filter { $0.isRequestable && ($0.status == .pending || $0.status == .unknown) }
            .enumerated()
            .sorted { left, right in
                let leftRank = rank[left.element.kind] ?? 99
                let rightRank = rank[right.element.kind] ?? 99
                return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
            }
            .map(\.element)
    }

    // Terminals Toki scripts to focus a tab and deliver a reply.
    private static let scriptedTerminals = [
        (name: HostApp.iTerm.displayName, bundleID: HostApp.iTerm.bundleID),
        (name: HostApp.ghostty.displayName, bundleID: HostApp.ghostty.bundleID),
        (name: HostApp.terminal.displayName, bundleID: HostApp.terminal.bundleID)
    ]

    /// Editors whose windows Toki raises through the accessibility API.
    private static let workspaceApps = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.visualstudio.code.oss",
        "com.vscodium"
    ]

    @MainActor
    static func currentFacts(
        store: UsageStore,
        remoteControlRunning: Bool,
        accessibilityRequested: Bool = false
    ) async -> SetupFacts {
        var facts = SetupFacts()
        facts.hasConnectedAccount = !store.snapshots.isEmpty
        // What the scan actually does, not just the stored answer: once onboarding is over the
        // read happens regardless, and a row reading "pending" for something already working
        // would be a lie with a button attached.
        facts.keychainApproved = store.allowsKeychainReads
        facts.claudeAccountConfigured = store.snapshots.contains { $0.provider.isClaudeAccount }
        // A read that produced something, from either route: a non-error account snapshot or a live
        // detection. An error snapshot falls through to the retry row instead of claiming success.
        facts.claudeSignInFound = store.snapshots.contains { $0.provider.isClaudeAccount && !$0.isError }
            || store.detectedProviders.contains { $0.provider.isClaudeAccount }
        facts.notificationsEnabled = store.preferences.notificationsEnabled
        facts.notificationAuthorization = await NotificationDelivery.authorizationStatus()
        // Off the main actor: this is a TCC lookup per terminal, and the list is rebuilt every
        // time the app becomes active - which is exactly when TCC is least likely to answer fast.
        facts.automation = await SystemPermissions.automationStatuses(for: SystemPermissions.installed(scriptedTerminals))
        facts.accessibilityGranted = SystemPermissions.accessibilityGranted
        facts.accessibilityRequested = accessibilityRequested
        facts.workspaceAppRunning = SystemPermissions.isRunning(anyOf: workspaceApps)
        facts.ghosttyScreenCaptureNeeded = remoteControlRunning
            && SystemPermissions.isRunning(anyOf: [HostApp.ghostty.bundleID])
        facts.remoteControlRunning = remoteControlRunning
        facts.launchAtLoginEnabled = LaunchAtLogin.isEnabled
        return facts
    }
}

// The probes behind the checklist. Every read here is silent - the prompting versions are the
// `request` calls, which only run when a row's button is pressed.
enum SystemPermissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    @MainActor
    static func requestAccessibility() {
        // Puts up macOS's own "open Privacy settings" prompt; the app must then be toggled on
        // there by hand, which is why the settings pane is opened alongside it.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        openPrivacySettings(anchor: "Privacy_Accessibility")
    }

    @MainActor
    static func installed(_ apps: [(name: String, bundleID: String)]) -> [(name: String, bundleID: String)] {
        apps.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    @MainActor
    static func isRunning(anyOf bundleIDs: [String]) -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier.map(bundleIDs.contains) ?? false
        }
    }

    // AEDeterminePermissionToAutomateTarget answers without asking when askUserIfNeeded is false,
    // which is what makes a checklist possible: the status can be shown before anything is
    // requested. The result codes are spelled out rather than imported by name so this reads the
    // same whatever the SDK calls them.
    private static let notPermitted: OSStatus = -1743 // errAEEventNotPermitted
    private static let wouldRequireConsent: OSStatus = -1744 // errAEEventWouldRequireUserConsent
    private static let targetNotRunning: OSStatus = -600 // procNotFound
    /// No Apple Event address could be built for that bundle id, so nothing can be asked.
    private static let descriptorUnavailable: OSStatus = -1

    static func automationStatuses(for apps: [(name: String, bundleID: String)]) async -> [AutomationTarget] {
        let requested = apps.map { (name: $0.name, bundleID: $0.bundleID) }
        return await Task.detached(priority: .utility) {
            requested.map {
                AutomationTarget(name: $0.name, bundleID: $0.bundleID, status: automationStatus(bundleID: $0.bundleID))
            }
        }.value
    }

    static func automationStatus(bundleID: String) -> SetupStepStatus {
        let status = automationPermission(bundleID: bundleID, askUserIfNeeded: false)
        if status == noErr { return .done }
        if status == notPermitted { return .blocked }
        if status == wouldRequireConsent { return .pending }
        // The app isn't running, so macOS won't say. "Not granted yet" was wrong for every closed
        // terminal, including ones already allowed, which is most of them when the checklist is read.
        if status == targetNotRunning { return .unknown }
        return .unknown
    }

    // Asking blocks until the dialog is answered, so it never runs on the main thread. macOS also
    // shows nothing for an app that isn't running, so the target is launched (in the background)
    // before it is asked about.
    @MainActor
    static func requestAutomation(bundleID: String) async -> SetupStepStatus {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return .unknown }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return await Task.detached(priority: .userInitiated) {
            let status = automationPermission(bundleID: bundleID, askUserIfNeeded: true)
            if status == noErr { return SetupStepStatus.done }
            if status == notPermitted { return .blocked }
            return status == descriptorUnavailable ? .unknown : .pending
        }.value
    }

    private static func automationPermission(bundleID: String, askUserIfNeeded: Bool) -> OSStatus {
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let target = descriptor.aeDesc else { return descriptorUnavailable }
        // The pointer belongs to the descriptor, which must outlive the call.
        return withExtendedLifetime(descriptor) {
            AEDeterminePermissionToAutomateTarget(target, AEEventClass(typeWildCard), AEEventID(typeWildCard), askUserIfNeeded)
        }
    }

    /// Notifications live in their own Settings pane, not under Privacy & Security.
    @MainActor
    static func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Quits and reopens, which is the only way a process picks up an Accessibility grant made
    /// while it was running. Reopening is handed to a detached shell that waits for this
    /// process to go away first, so the two never overlap and race over the state file.
    @MainActor
    static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    @MainActor
    static func openPrivacySettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}
