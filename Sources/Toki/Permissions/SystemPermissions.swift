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
    case accessibility
    case localNetwork

    var id: String { rawValue }
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

    var id: String { subject.map { "\(kind.rawValue).\($0)" } ?? kind.rawValue }

    init(
        kind: SetupStepID,
        subject: String? = nil,
        title: String,
        detail: String,
        status: SetupStepStatus,
        actionLabel: String?,
        isOptional: Bool = false
    ) {
        self.kind = kind
        self.subject = subject
        self.title = title
        self.detail = detail
        self.status = status
        self.actionLabel = actionLabel
        self.isOptional = isOptional
    }
}

/// What the checklist needs to know about this Mac. Gathered by `SetupChecklist.currentFacts`,
/// which is the only part that touches the system.
struct SetupFacts: Equatable {
    var hasConnectedAccount = false
    /// Whether the user has agreed to Toki reading the Claude Code sign-in out of the Keychain.
    var keychainApproved = false
    var claudeCodeDetected = false
    var notificationsEnabled = true
    /// Terminals installed on this Mac that Toki types replies into, with where each one stands.
    var automation: [AutomationTarget] = []
    /// Only relevant while an editor whose windows Toki raises is running.
    var workspaceAppRunning = false
    var accessibilityGranted = false
    var remoteControlRunning = false
}

struct AutomationTarget: Equatable, Identifiable {
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
    static func steps(from facts: SetupFacts) -> [SetupStep] {
        var steps: [SetupStep] = []

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
        if !facts.keychainApproved || facts.claudeCodeDetected {
            steps.append(SetupStep(
                kind: .claudeKeychain,
                title: "Read your Claude Code sign-in",
                detail: facts.keychainApproved
                    ? "Toki reads the token Claude Code stored in your Keychain to show its quota."
                    : "Claude Code keeps its token in your Keychain. macOS will ask you to allow Toki once.",
                status: facts.keychainApproved ? .done : .pending,
                actionLabel: facts.keychainApproved ? nil : "Allow"
            ))
        }

        steps.append(SetupStep(
            kind: .notifications,
            title: "Notifications",
            detail: facts.notificationsEnabled
                ? "Toki tells you when quota runs low or an agent is waiting. macOS asks the first time one is sent."
                : "Turned off in Toki, so nothing is delivered and macOS is never asked.",
            status: facts.notificationsEnabled ? .unknown : .done,
            actionLabel: facts.notificationsEnabled ? "Send a test" : nil
        ))

        // Only for terminals actually installed: an Automation row for an app that isn't here
        // asks for a permission that can never be used.
        for target in facts.automation {
            steps.append(SetupStep(
                kind: .automation,
                subject: target.bundleID,
                title: "Control \(target.name)",
                detail: target.status == .blocked
                    ? "Refused earlier, so replies can't reach agents running in \(target.name). Allow Toki under Privacy & Security › Automation."
                    : "Lets Toki jump to an agent's tab, and type your replies from Remote Control into it.",
                status: target.status,
                actionLabel: target.status == .done ? nil : (target.status == .blocked ? "Open Settings" : "Allow"),
                isOptional: true
            ))
        }

        if facts.workspaceAppRunning, !facts.accessibilityGranted {
            steps.append(SetupStep(
                kind: .accessibility,
                title: "Accessibility",
                detail: "Only used to raise the right VS Code window when you click an agent running in it.",
                status: .pending,
                actionLabel: "Allow",
                isOptional: true
            ))
        }

        if facts.remoteControlRunning {
            steps.append(SetupStep(
                kind: .localNetwork,
                title: "Local network",
                detail: "Remote Control answers your phone over the network, which macOS asks about the first time. Without it the phone can't reach this Mac.",
                status: .unknown,
                actionLabel: "Open Settings",
                isOptional: true
            ))
        }

        return steps
    }

    /// Steps still worth acting on - what the badge counts.
    static func outstanding(_ steps: [SetupStep]) -> [SetupStep] {
        steps.filter { $0.status == .pending || $0.status == .blocked }
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
    static func currentFacts(store: UsageStore, remoteControlRunning: Bool) -> SetupFacts {
        var facts = SetupFacts()
        facts.hasConnectedAccount = !store.snapshots.isEmpty
        facts.keychainApproved = store.preferences.keychainReadsApproved
        facts.claudeCodeDetected = store.snapshots.contains { $0.provider.isClaudeAccount }
        facts.notificationsEnabled = store.preferences.notificationsEnabled
        facts.automation = SystemPermissions.installed(scriptedTerminals).map {
            AutomationTarget(name: $0.name, bundleID: $0.bundleID, status: SystemPermissions.automationStatus(bundleID: $0.bundleID))
        }
        facts.accessibilityGranted = SystemPermissions.accessibilityGranted
        facts.workspaceAppRunning = SystemPermissions.isRunning(anyOf: workspaceApps)
        facts.remoteControlRunning = remoteControlRunning
        return facts
    }
}

// The probes behind the checklist. Every read here is silent - the prompting versions are the
// `request` calls, which only run when a row's button is pressed.
enum SystemPermissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        // Puts up macOS's own "open Privacy settings" prompt; the app must then be toggled on
        // there by hand, which is why the settings pane is opened alongside it.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        openPrivacySettings(anchor: "Privacy_Accessibility")
    }

    static func installed(_ apps: [(name: String, bundleID: String)]) -> [(name: String, bundleID: String)] {
        apps.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

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

    static func automationStatus(bundleID: String) -> SetupStepStatus {
        let status = automationPermission(bundleID: bundleID, askUserIfNeeded: false)
        if status == noErr { return .done }
        if status == notPermitted { return .blocked }
        if status == wouldRequireConsent || status == targetNotRunning { return .pending }
        return .unknown
    }

    // Asking blocks until the dialog is answered, so it never runs on the main thread. macOS also
    // shows nothing for an app that isn't running, so the target is launched (in the background)
    // before it is asked about.
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

    static func openPrivacySettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}
