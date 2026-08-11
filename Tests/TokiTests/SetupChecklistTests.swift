import XCTest
@testable import Toki

// The checklist's job is to ask for a permission only when it is both needed and useful on this
// machine, and to say where each one stands without having asked for it.
final class SetupChecklistTests: XCTestCase {
    private func steps(_ facts: SetupFacts) -> [SetupStep] {
        SetupChecklist.steps(from: facts)
    }

    private func step(_ kind: SetupStepID, in facts: SetupFacts) -> SetupStep? {
        steps(facts).first { $0.kind == kind }
    }

    func testAFreshMachineIsAskedToConnectAnAccountAndApproveTheKeychain() {
        let facts = SetupFacts()
        XCTAssertEqual(step(.account, in: facts)?.status, .pending)
        XCTAssertEqual(step(.claudeKeychain, in: facts)?.status, .pending)
        XCTAssertEqual(step(.claudeKeychain, in: facts)?.actionLabel, "Allow")
    }

    func testTheKeychainRowDisappearsOnceApprovedAndNoClaudeAccountIsThere() {
        var facts = SetupFacts()
        facts.keychainApproved = true
        facts.claudeCodeDetected = false
        XCTAssertNil(step(.claudeKeychain, in: facts))
    }

    func testAnApprovedKeychainStillExplainsItselfWhileClaudeIsConnected() {
        var facts = SetupFacts()
        facts.keychainApproved = true
        facts.claudeCodeDetected = true
        XCTAssertEqual(step(.claudeKeychain, in: facts)?.status, .done)
        XCTAssertNil(step(.claudeKeychain, in: facts)?.actionLabel)
    }

    // Nothing is delivered while Toki's own switch is off, so macOS is never asked and there is
    // nothing outstanding to chase.
    func testNotificationsTurnedOffInTokiAreNotAPendingPermission() {
        var facts = SetupFacts()
        facts.notificationsEnabled = false
        XCTAssertEqual(step(.notifications, in: facts)?.status, .done)
        XCTAssertNil(step(.notifications, in: facts)?.actionLabel)
    }

    func testOnlyInstalledTerminalsGetAnAutomationRow() {
        var facts = SetupFacts()
        XCTAssertNil(step(.automation, in: facts))

        facts.automation = [AutomationTarget(name: "iTerm", bundleID: "com.googlecode.iterm2", status: .pending)]
        XCTAssertEqual(step(.automation, in: facts)?.title, "Control iTerm")
    }

    // Two rows of one kind still have to be two rows to SwiftUI.
    func testEachTerminalIsItsOwnRow() {
        var facts = SetupFacts()
        facts.automation = [
            AutomationTarget(name: "iTerm", bundleID: "com.googlecode.iterm2", status: .pending),
            AutomationTarget(name: "Terminal", bundleID: "com.apple.Terminal", status: .done)
        ]
        let ids = steps(facts).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    // macOS never re-asks after a refusal, so offering "Allow" again would do nothing.
    func testARefusedPermissionSendsYouToSystemSettingsInsteadOfAskingAgain() {
        var facts = SetupFacts()
        facts.automation = [AutomationTarget(name: "Terminal", bundleID: "com.apple.Terminal", status: .blocked)]
        XCTAssertEqual(step(.automation, in: facts)?.actionLabel, "Open Settings")
    }

    func testAccessibilityIsOnlyRaisedWhileAnEditorThatNeedsItIsRunning() {
        var facts = SetupFacts()
        facts.workspaceAppRunning = false
        XCTAssertNil(step(.accessibility, in: facts))

        facts.workspaceAppRunning = true
        XCTAssertEqual(step(.accessibility, in: facts)?.status, .pending)

        facts.accessibilityGranted = true
        XCTAssertNil(step(.accessibility, in: facts))
    }

    func testLocalNetworkIsOnlyRaisedWhileRemoteControlIsRunning() {
        var facts = SetupFacts()
        XCTAssertNil(step(.localNetwork, in: facts))

        facts.remoteControlRunning = true
        XCTAssertEqual(step(.localNetwork, in: facts)?.status, .unknown)
    }

    // What the "still to do" count is built from: a permission macOS won't let us read isn't
    // something to chase, and neither is one that's already granted.
    func testOnlyPendingAndRefusedStepsCountAsOutstanding() {
        var facts = SetupFacts()
        facts.hasConnectedAccount = true
        facts.keychainApproved = true
        facts.remoteControlRunning = true
        facts.automation = [
            AutomationTarget(name: "iTerm", bundleID: "com.googlecode.iterm2", status: .done),
            AutomationTarget(name: "Terminal", bundleID: "com.apple.Terminal", status: .blocked)
        ]
        let outstanding = SetupChecklist.outstanding(steps(facts))
        XCTAssertEqual(outstanding.map(\.kind), [.automation])
    }

    func testEverythingOptionalIsMarkedAsOptional() {
        var facts = SetupFacts()
        facts.workspaceAppRunning = true
        facts.remoteControlRunning = true
        facts.automation = [AutomationTarget(name: "iTerm", bundleID: "com.googlecode.iterm2", status: .pending)]
        let optional = steps(facts).filter(\.isOptional).map(\.kind)
        XCTAssertEqual(Set(optional), [.automation, .accessibility, .localNetwork])
    }
}
