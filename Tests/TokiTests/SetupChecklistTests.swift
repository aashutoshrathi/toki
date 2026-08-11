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

    func testTheKeychainRowDisappearsOnceApprovedAndThereIsNoClaudeToRead() {
        var facts = SetupFacts()
        facts.keychainApproved = true
        facts.claudeSignInFound = false
        facts.claudeAccountConfigured = false
        XCTAssertNil(step(.claudeKeychain, in: facts))
    }

    func testAnApprovedKeychainReadsAsDoneOnlyWhenASignInWasActuallyRead() {
        var facts = SetupFacts()
        facts.keychainApproved = true
        facts.claudeSignInFound = true
        XCTAssertEqual(step(.claudeKeychain, in: facts)?.status, .done)
        XCTAssertNil(step(.claudeKeychain, in: facts)?.actionLabel)
    }

    // A refused Keychain dialog leaves the gate open and the read empty. Reporting that as "done"
    // claimed success for something that never happened and removed the only way to retry.
    func testAConfiguredClaudeAccountWithNoReadableSignInOffersARetry() {
        var facts = SetupFacts()
        facts.keychainApproved = true
        facts.claudeAccountConfigured = true
        facts.claudeSignInFound = false
        XCTAssertEqual(step(.claudeKeychain, in: facts)?.status, .unknown)
        XCTAssertEqual(step(.claudeKeychain, in: facts)?.actionLabel, "Try again")
        XCTAssertTrue(step(.claudeKeychain, in: facts)?.isRequestable ?? false)
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

    // macOS will not answer for an app that is not running, and most terminals are closed when the
    // checklist is read. Calling that "not granted yet" marked already-allowed terminals as
    // outstanding forever; it is unknown, and asking is still how you find out.
    func testAClosedTerminalIsUnknownRatherThanNotGranted() {
        var facts = SetupFacts()
        facts.automation = [AutomationTarget(name: "iTerm", bundleID: "com.googlecode.iterm2", status: .unknown)]
        let row = step(.automation, in: facts)
        XCTAssertEqual(row?.status, .unknown)
        XCTAssertEqual(row?.actionLabel, "Allow")
        XCTAssertTrue(row?.isRequestable ?? false, "asking is what opens it and settles the question")
        // Other rows in a bare fixture are legitimately outstanding; what matters is that a
        // terminal macOS refuses to answer for is not one of them.
        XCTAssertFalse(
            SetupChecklist.outstanding(steps(facts)).contains { $0.kind == .automation },
            "a closed terminal is unknown, not an outstanding chore"
        )
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

    // A fresh install should be able to see the whole cost at once, including the permissions that
    // only matter once you use the feature behind them.
    func testAFirstRunListsEveryPermissionEvenTheOnesThatDoNotApplyYet() {
        var facts = SetupFacts()
        facts.automation = [AutomationTarget(name: "Terminal", bundleID: "com.apple.Terminal", status: .pending)]
        let kinds = SetupChecklist.steps(from: facts, mode: .firstRun).map(\.kind)
        XCTAssertEqual(
            Set(kinds),
            [.account, .claudeKeychain, .notifications, .automation, .accessibility, .localNetwork, .launchAtLogin]
        )
    }

    // Afterwards the same list is a status board, and a row for something that isn't happening is
    // noise rather than information.
    func testTheOngoingListStillOnlyShowsWhatAppliesNow() {
        let kinds = SetupChecklist.steps(from: SetupFacts()).map(\.kind)
        XCTAssertFalse(kinds.contains(.accessibility))
        XCTAssertFalse(kinds.contains(.localNetwork))
        XCTAssertFalse(kinds.contains(.launchAtLogin))
    }

    // Local network is the one Toki cannot bring forward - macOS asks when the server first
    // answers a device - so a first run explains it rather than offering a button that does nothing.
    func testLocalNetworkIsExplainedNotRequestedBeforeRemoteControlIsOn() {
        let step = SetupChecklist.steps(from: SetupFacts(), mode: .firstRun).first { $0.kind == .localNetwork }
        XCTAssertNil(step?.actionLabel)
        XCTAssertFalse(step?.isRequestable ?? true)
    }

    // "Allow all" is one dialog at a time, and the one that sends you to System Settings goes last
    // so the rest are not stacked up behind a trip out of the app.
    func testAskingForEverythingLeavesAccessibilityUntilLast() {
        var facts = SetupFacts()
        facts.automation = [
            AutomationTarget(name: "iTerm", bundleID: "com.googlecode.iterm2", status: .pending),
            AutomationTarget(name: "Terminal", bundleID: "com.apple.Terminal", status: .pending)
        ]
        let order = SetupChecklist.requestOrder(SetupChecklist.steps(from: facts, mode: .firstRun))
        XCTAssertEqual(
            order.map(\.kind),
            [.claudeKeychain, .notifications, .automation, .automation, .launchAtLogin, .accessibility]
        )
        // Two terminals keep the order the list showed them in.
        XCTAssertEqual(order.filter { $0.kind == .automation }.map(\.subject),
                       ["com.googlecode.iterm2", "com.apple.Terminal"])
    }

    func testAlreadyGrantedAndUnaskableStepsAreNotRequestedAgain() {
        var facts = SetupFacts()
        facts.keychainApproved = true
        facts.accessibilityGranted = true
        facts.launchAtLoginEnabled = true
        facts.claudeSignInFound = true
        facts.automation = [AutomationTarget(name: "Terminal", bundleID: "com.apple.Terminal", status: .blocked)]
        let order = SetupChecklist.requestOrder(SetupChecklist.steps(from: facts, mode: .firstRun))
        // Notifications can't be read back, so it stays askable; everything else here is settled,
        // refused (macOS won't ask twice), or not Toki's to ask for.
        XCTAssertEqual(order.map(\.kind), [.notifications])
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
