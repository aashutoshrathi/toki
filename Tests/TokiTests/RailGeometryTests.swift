import XCTest
@testable import Toki

// The rail anchors to the screen edge rather than the camera housing, so its layout is
// arithmetic on the screen frame and can be checked against machines this one is not.
final class RailGeometryTests: XCTestCase {
    private func screen(width: CGFloat = 1512, height: CGFloat = 982, band: CGFloat = 38) -> ScreenMetrics {
        ScreenMetrics(frame: NSRect(x: 0, y: 0, width: width, height: height), bandHeight: band)
    }

    func testNothingConnectedDrawsNoRail() {
        XCTAssertNil(RailGeometry.make(screen: screen(), providerCount: 0))
    }

    func testRailHangsBelowTheBandAtTheRightEdge() {
        let g = RailGeometry.make(screen: screen(), providerCount: 2)!
        // Top of the window sits exactly where the menu bar band ends.
        XCTAssertEqual(g.window.maxY, 982 - 38, accuracy: 0.001)
        // Flush to the border rather than inset from it, so the rail reads as part of the
        // display's edge the way the concept draws it - and never past it.
        XCTAssertEqual(g.window.maxX, 1512, accuracy: 0.001)
    }

    // The tail has to travel with the row, or a card pushed away from centre to stay on screen
    // would point at the wrong ring.
    func testTheTailFollowsTheRowNotTheCard() {
        let g = RailGeometry.make(screen: screen(), providerCount: 4)!
        let first = g.rowCentreY(0)
        let second = g.rowCentreY(1)
        XCTAssertEqual(second - first, RailGeometry.rowPitch(), accuracy: 0.001)
        for row in 0..<4 {
            let card = g.card(forRow: row, height: 90)
            let tail = g.rowCentreY(row) - card.minY
            XCTAssertGreaterThanOrEqual(tail, 0, "row \(row) tail sat above the card")
            XCTAssertLessThanOrEqual(tail, card.height, "row \(row) tail sat below the card")
        }
    }

    func testTheRailGrowsWithEachProvider() {
        let two = RailGeometry.make(screen: screen(), providerCount: 2)!
        let three = RailGeometry.make(screen: screen(), providerCount: 3)!
        XCTAssertEqual(three.window.height - two.window.height, RailGeometry.rowPitch(), accuracy: 0.001)
    }

    // The rail hangs into the screen, so an unbounded one would run down the whole edge.
    func testProvidersPastTheCapCollapseIntoACount() {
        let g = RailGeometry.make(screen: screen(), providerCount: 7)!
        XCTAssertEqual(g.drawnCount, RailGeometry.maxRows)
        XCTAssertEqual(g.overflowCount, 7 - RailGeometry.maxRows)
    }

    func testExactlyTheCapNeedsNoOverflowRow() {
        let g = RailGeometry.make(screen: screen(), providerCount: RailGeometry.maxRows)!
        XCTAssertEqual(g.overflowCount, 0)
        XCTAssertEqual(RailGeometry.rowCount(providerCount: RailGeometry.maxRows), RailGeometry.maxRows)
    }

    // One past the cap costs two rows, not one: four rings plus the "+N" chip.
    func testTheOverflowChipTakesARowOfItsOwn() {
        XCTAssertEqual(RailGeometry.rowCount(providerCount: RailGeometry.maxRows + 1), RailGeometry.maxRows + 1)
        XCTAssertEqual(RailGeometry.rowCount(providerCount: 99), RailGeometry.maxRows + 1)
    }

    // The window spans the card as well, so hovering never resizes it - the notch panel shook
    // when it did that, because resizing relaid its tracking area.
    func testTheWindowLeavesRoomForTheCardBesideTheRail() {
        let g = RailGeometry.make(screen: screen(), providerCount: 3)!
        XCTAssertEqual(g.window.width, g.rail.width + RailGeometry.cardWidth + RailGeometry.cardGap, accuracy: 0.001)
        XCTAssertEqual(g.rail.minX, RailGeometry.cardWidth + RailGeometry.cardGap, accuracy: 0.001)
    }

    func testTheCardLinesUpWithTheRowBeingHovered() {
        let g = RailGeometry.make(screen: screen(), providerCount: 4)!
        let top = g.card(forRow: 0, height: 90)
        let lower = g.card(forRow: 2, height: 90)
        XCTAssertLessThan(top.minY, lower.minY, "a lower row's card sits lower")
        XCTAssertEqual(top.width, RailGeometry.cardWidth)
    }

    // A card centred on the last row would otherwise hang off the bottom of the window and be
    // clipped away.
    func testTheCardStaysInsideTheWindowOnTheEndRows() {
        let g = RailGeometry.make(screen: screen(), providerCount: 4)!
        for row in 0..<4 {
            let card = g.card(forRow: row, height: 90)
            XCTAssertGreaterThanOrEqual(card.minY, 0, "row \(row) card ran off the top")
            XCTAssertLessThanOrEqual(card.maxY, g.window.height + 0.001, "row \(row) card ran off the bottom")
        }
    }

    // No dependence on auxiliaryTopArea, which is what lets the rail work on a display with no
    // notch and on external monitors.
    func testItLaysOutOnADisplayWithNoNotchBand() {
        let external = ScreenMetrics(frame: NSRect(x: 1512, y: 0, width: 2560, height: 1440), bandHeight: 24)
        let g = RailGeometry.make(screen: external, providerCount: 3)!
        XCTAssertEqual(g.window.maxY, 1440 - 24, accuracy: 0.001)
        XCTAssertGreaterThan(g.window.minX, 1512, "it belongs on the external display, not the built-in")
    }
}
