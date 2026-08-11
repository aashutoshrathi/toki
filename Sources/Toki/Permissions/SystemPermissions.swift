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

    var id: String { subject.map { "\(kind.rawValue).\($0)" } ?? kind.rawValue }

    init(
        kind: SetupStepID,
        subject: String? = nil,
        title: String,
        detail: String,
        status: SetupStepStatus,
        actionLabel: String?,
        isOptional: Bool = false,
        isRequestable: Bool = false
    ) {
        self.kind = kind
        self.subject = subject
        self.title = title
        self.detail = detail
        self.status = status
        self.actionLabel = actionLabel
        self.isOptional = isOptional
        self.isRequestable = isRequestable
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
    /// Terminals installed on this Mac that Toki types replies into, with where each one stands.
    var automation: [AutomationTarget] = []
    /// Only relevant while an editor whose windows Toki raises is running.
    var workspaceAppRunning = false
    var accessibilityGranted = false
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
        // Once it is allowed the row reports what the read actually produced: saying "done" purely
        // because the gate is open claimed success for a dialog that may have been refused.
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
            // Allowed, but nothing came back. A refused Keychain dialog looks exactly like this,
            // and so does a Claude Code that was never signed in - both are worth another look
            // rather than a row claiming everything is fine.
            steps.append(SetupStep(
                kind: .claudeKeychain,
                title: "Read your Claude Code sign-in",
                detail: "Toki couldn't read a Claude Code sign-in. If macOS asked and the answer was Deny, try again and choose Always Allow; if Claude Code isn't signed in, run /login there first.",
                status: .unknown,
                actionLabel: "Try again",
                isRequestable: true
            ))
        }

        steps.append(SetupStep(
            kind: .notifications,
            title: "Notifications",
            detail: facts.notificationsEnabled
                ? "Toki tells you when quota runs low or an agent is waiting on you. macOS asks the first time one is sent."
                : "Turned off in Toki, so nothing is delivered and macOS is never asked.",
            status: facts.notificationsEnabled ? .unknown : .done,
            actionLabel: facts.notificationsEnabled ? "Send a test" : nil,
            isRequestable: facts.notificationsEnabled
        ))

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
                // `.unknown` means the app is closed and macOS would not say; asking is still the
                // way to find out, and asking launches it.
                isRequestable: target.status == .pending || target.status == .unknown
            ))
        }

        // On a first run this is listed whether or not an editor is open right now: the point is
        // to show the whole cost up front, not to wait until the click that needs it.
        if !facts.accessibilityGranted, isFirstRun || facts.workspaceAppRunning {
            steps.append(SetupStep(
                kind: .accessibility,
                title: "Accessibility",
                detail: facts.workspaceAppRunning
                    ? "Only used to raise the right VS Code window when you click an agent running in it."
                    : "Only used to raise the right VS Code window when you click an agent running in one. Skip it if you work in a terminal.",
                status: .pending,
                actionLabel: "Allow",
                isOptional: true,
                isRequestable: true
            ))
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
        steps.filter { $0.status == .pending || $0.status == .blocked }
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

    // Terminals Toki scripts to focus a tab and deliver a reply. Only these two are scripted, so
    // only these two are worth an Automation row.
    private static let scriptedTerminals = [
        (name: "iTerm", bundleID: "com.googlecode.iterm2"),
        (name: "Terminal", bundleID: "com.apple.Terminal")
    ]

    /// Editors whose windows Toki raises through the accessibility API.
    private static let workspaceApps = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.visualstudio.code.oss",
        "com.vscodium"
    ]

    @MainActor
    static func currentFacts(store: UsageStore, remoteControlRunning: Bool) async -> SetupFacts {
        var facts = SetupFacts()
        facts.hasConnectedAccount = !store.snapshots.isEmpty
        // What the scan actually does, not just the stored answer: once onboarding is over the
        // read happens regardless, and a row reading "pending" for something already working
        // would be a lie with a button attached.
        facts.keychainApproved = store.allowsKeychainReads
        facts.claudeAccountConfigured = store.snapshots.contains { $0.provider.isClaudeAccount }
        // What the read produced, from either route: a connected account or a live detection.
        facts.claudeSignInFound = facts.claudeAccountConfigured
            || store.detectedProviders.contains { $0.provider.isClaudeAccount }
        facts.notificationsEnabled = store.preferences.notificationsEnabled
        // Off the main actor: this is a TCC lookup per terminal, and the list is rebuilt every
        // time the app becomes active - which is exactly when TCC is least likely to answer fast.
        facts.automation = await SystemPermissions.automationStatuses(for: SystemPermissions.installed(scriptedTerminals))
        facts.accessibilityGranted = SystemPermissions.accessibilityGranted
        facts.workspaceAppRunning = SystemPermissions.isRunning(anyOf: workspaceApps)
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
        // The app is not running, so macOS will not say. Reporting "not granted yet" there was
        // wrong for every terminal that happened to be closed - including ones already allowed -
        // and it is the state most terminals are in when the checklist is read.
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

    @MainActor
    static func openPrivacySettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}
