import AppKit
import XCTest
@testable import Toki

final class PopoverPositioningTests: XCTestCase {
    private let primary = NSRect(x: 0, y: 0, width: 1512, height: 982)
    private let secondary = NSRect(x: 1512, y: 120, width: 1920, height: 1080)

    func testCrossDisplayMoveMatchingClickIsAccepted() {
        let previous = NSRect(x: 1300, y: 956, width: 100, height: 24)
        let candidate = NSRect(x: 3200, y: 1174, width: 100, height: 24)

        XCTAssertTrue(popoverStatusFrameIsUsable(
            candidate,
            screenFrames: [primary, secondary],
            activationPoint: NSPoint(x: 3250, y: 1185),
            lastKnownFrame: previous
        ))
    }

    func testFarLeftRevealFrameIsRejectedOnClickedDisplay() {
        let candidate = NSRect(x: 1512, y: 1174, width: 100, height: 24)

        XCTAssertFalse(popoverStatusFrameIsUsable(
            candidate,
            screenFrames: [primary, secondary],
            activationPoint: NSPoint(x: 3250, y: 1185),
            lastKnownFrame: nil
        ))
    }

    func testNegativeDisplayCoordinatesAreAccepted() {
        let leftDisplay = NSRect(x: -1920, y: -160, width: 1920, height: 1080)
        let candidate = NSRect(x: -220, y: 894, width: 100, height: 24)

        XCTAssertTrue(popoverStatusFrameIsUsable(
            candidate,
            screenFrames: [leftDisplay, primary],
            activationPoint: NSPoint(x: -170, y: 905),
            lastKnownFrame: nil
        ))
    }

    func testFallbackPrefersClickOverFrameFromAnotherDisplay() {
        let previous = NSRect(x: 1300, y: 956, width: 100, height: 24)

        XCTAssertEqual(
            popoverFallbackAnchorX(
                on: secondary,
                activationPoint: NSPoint(x: 3250, y: 1185),
                lastKnownFrame: previous
            ),
            3250
        )
    }

    func testFallbackRetainsLastKnownXOnSameDisplayWithoutClick() {
        let previous = NSRect(x: 3200, y: 1174, width: 100, height: 24)

        XCTAssertEqual(
            popoverFallbackAnchorX(
                on: secondary,
                activationPoint: nil,
                lastKnownFrame: previous
            ),
            previous.midX
        )
    }
}
