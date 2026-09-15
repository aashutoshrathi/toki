import UserNotifications
import XCTest
@testable import Toki

// Toki used to assert that notifications were authorized without asking macOS anything, so a
// build that could not deliver at all still reported that it had. These cover the status the
// checklist now reads and the wording it shows for each one.
final class NotificationAuthorizationTests: XCTestCase {
    func testProvisionalStillCountsAsReachingTheUser() {
        // Provisional delivers quietly to Notification Centre, which is still delivery.
        XCTAssertEqual(NotificationDelivery.mapped(.provisional), .authorized)
        XCTAssertEqual(NotificationDelivery.mapped(.authorized), .authorized)
    }

    func testDeniedAndUndeterminedStayApart() {
        // They lead to different rows: one can still be asked, the other only opens Settings.
        XCTAssertEqual(NotificationDelivery.mapped(.denied), .denied)
        XCTAssertEqual(NotificationDelivery.mapped(.notDetermined), .notDetermined)
    }

    func testOnlyAuthorizedAllowsDelivery() {
        XCTAssertTrue(NotificationAuthorization.authorized.allowsDelivery)
        XCTAssertFalse(NotificationAuthorization.denied.allowsDelivery)
        XCTAssertFalse(NotificationAuthorization.notDetermined.allowsDelivery)
        XCTAssertFalse(NotificationAuthorization.unavailable("no bundle").allowsDelivery)
    }

    func testEveryBlockedStateSaysWhy() {
        XCTAssertNil(NotificationAuthorization.authorized.deliveryBlocker)
        for state: NotificationAuthorization in [.denied, .notDetermined, .unavailable("no bundle")] {
            XCTAssertFalse(state.deliveryBlocker?.isEmpty ?? true, "\(state) must explain itself")
        }
    }

    func testUnavailableCarriesItsOwnReasonThrough() {
        XCTAssertEqual(
            NotificationAuthorization.unavailable("no bundle").deliveryBlocker,
            "no bundle"
        )
    }

    // The test runner carries a bundle identifier but is not an .app, so it traps exactly the
    // way `swift run Toki` does. Checking the identifier alone was not enough, which is what
    // this test found.
    func testBuildThatIsNotAnAppReportsItselfUnavailable() {
        XCTAssertNotEqual(Bundle.main.bundleURL.pathExtension, "app",
                          "precondition: the test binary is not an app bundle")
        XCTAssertNotNil(NotificationDelivery.unavailableReason)
    }

    func testStatusIsUnavailableRatherThanTrappingWhenUnbundled() async {
        let status = await NotificationDelivery.authorizationStatus()
        guard case .unavailable = status else {
            return XCTFail("an unbundled build must report unavailable, got \(status)")
        }
    }

    func testDeliveryRefusesInsteadOfClaimingSuccessWhenUnbundled() async {
        let failure = await NotificationDelivery.deliver(title: "t", body: "b")
        XCTAssertNotNil(failure, "delivery that cannot happen must not report success")
    }
}

// The checklist row that reports all of the above.
final class NotificationChecklistStepTests: XCTestCase {
    private func step(enabled: Bool, authorization: NotificationAuthorization) -> SetupStep {
        var facts = SetupFacts()
        facts.notificationsEnabled = enabled
        facts.notificationAuthorization = authorization
        let steps = SetupChecklist.steps(from: facts)
        return steps.first { $0.kind == .notifications }!
    }

    func testUnaskedRowCanStillAsk() {
        let row = step(enabled: true, authorization: .notDetermined)
        XCTAssertEqual(row.status, .pending)
        XCTAssertTrue(row.isRequestable)
        XCTAssertEqual(row.actionLabel, "Allow")
    }

    func testGrantedRowReadsAsDone() {
        let row = step(enabled: true, authorization: .authorized)
        XCTAssertEqual(row.status, .done)
    }

    // macOS does not ask twice, so offering to request again would be a button that does nothing.
    func testDeniedRowOffersSettingsRatherThanAnotherRequest() {
        let row = step(enabled: true, authorization: .denied)
        XCTAssertEqual(row.status, .blocked)
        XCTAssertFalse(row.isRequestable)
        XCTAssertEqual(row.actionLabel, "Open Settings")
    }

    // A denied permission is real outstanding work; it used to sit at .unknown and count as nothing.
    func testDeniedRowCountsAsOutstanding() {
        var facts = SetupFacts()
        facts.notificationAuthorization = .denied
        let outstanding = SetupChecklist.outstanding(SetupChecklist.steps(from: facts))
        XCTAssertTrue(outstanding.contains { $0.kind == .notifications })
    }

    // Nothing to grant and nowhere to send anyone, so the row explains instead of acting.
    func testUnavailableRowHasNoActionAtAll() {
        let row = step(enabled: true, authorization: .unavailable("no app bundle"))
        XCTAssertNil(row.actionLabel)
        XCTAssertFalse(row.isRequestable)
        XCTAssertEqual(row.detail, "no app bundle")
    }

    // Toki's own switch is off, so macOS is never asked and there is nothing outstanding.
    func testTokisOwnSwitchBeingOffSettlesTheRow() {
        let row = step(enabled: false, authorization: .denied)
        XCTAssertEqual(row.status, .done)
        XCTAssertNil(row.actionLabel)
    }

    // The pass exists to bring dialogs forward; an unasked notification permission is one.
    func testUnaskedRowJoinsTheAllowAllPass() {
        var facts = SetupFacts()
        facts.notificationAuthorization = .notDetermined
        let order = SetupChecklist.requestOrder(SetupChecklist.steps(from: facts))
        XCTAssertTrue(order.contains { $0.kind == .notifications })
    }

    func testDeniedRowIsLeftOutOfTheAllowAllPass() {
        var facts = SetupFacts()
        facts.notificationAuthorization = .denied
        let order = SetupChecklist.requestOrder(SetupChecklist.steps(from: facts))
        XCTAssertFalse(order.contains { $0.kind == .notifications })
    }
}

// Accessibility is granted in System Settings rather than a dialog, and macOS only hands the
// new trust to a process when it starts, so a user who has just ticked the box comes back to a
// row that still says "Allow" and reads as if nothing happened.
final class AccessibilityStepTests: XCTestCase {
    private func step(requested: Bool, granted: Bool = false) -> SetupStep? {
        var facts = SetupFacts()
        facts.accessibilityGranted = granted
        facts.accessibilityRequested = requested
        facts.workspaceAppRunning = true
        return SetupChecklist.steps(from: facts).first { $0.kind == .accessibility }
    }

    func testUnaskedRowOffersToAsk() {
        let row = step(requested: false)
        XCTAssertEqual(row?.actionLabel, "Allow")
        XCTAssertEqual(row?.isRequestable, true)
    }

    // Asking again would just reopen a pane the user has already been to.
    func testRowOffersARestartOnceItHasSentTheUserToSettings() {
        let row = step(requested: true)
        XCTAssertEqual(row?.actionLabel, "Restart Toki")
        XCTAssertEqual(row?.isRequestable, false)
    }

    func testTheRestartRowExplainsWhyTheTickDidNotTake() {
        let detail = step(requested: true)?.detail ?? ""
        XCTAssertTrue(detail.contains("restart"), "the row has to say what the button is for")
    }

    // Requesting twice in the "allow all" pass would open System Settings a second time.
    func testARequestedRowDropsOutOfTheAllowAllPass() {
        var facts = SetupFacts()
        facts.accessibilityRequested = true
        facts.workspaceAppRunning = true
        let order = SetupChecklist.requestOrder(SetupChecklist.steps(from: facts))
        XCTAssertFalse(order.contains { $0.kind == .accessibility })
    }

    // Granted is granted: the row goes away whether or not it was asked for in this run.
    func testAGrantedPermissionShowsNoRowEitherWay() {
        XCTAssertNil(step(requested: true, granted: true))
        XCTAssertNil(step(requested: false, granted: true))
    }
}
