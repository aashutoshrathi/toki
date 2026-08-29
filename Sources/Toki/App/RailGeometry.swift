import Foundation

/// Where the rail and its hover card sit, worked out from plain numbers so the layout can be
/// checked without a screen.
///
/// Unlike the notch panel this anchors to the screen edge rather than the camera housing, so
/// it needs no `auxiliaryTopArea` and works on external displays and Macs with no notch.
struct RailGeometry: Equatable {
    /// The window, in screen coordinates. Wide enough to hold the card as well as the rail, so
    /// hovering never resizes it - the notch panel had to relayout its tracking area when it
    /// did that, which made it shake.
    let window: NSRect
    /// The rail itself, in the hosting view's top-left origin space.
    let rail: CGRect
    /// How many providers the rail draws before collapsing the rest into a count.
    let drawnCount: Int
    /// Providers beyond `drawnCount`, shown as "+N".
    let overflowCount: Int

    static let ringDiameter: CGFloat = 26
    static let rowSpacing: CGFloat = 4
    static let railPadding: CGFloat = 7
    static let cardWidth: CGFloat = 236
    static let cardGap: CGFloat = 8
    /// Rows past this are collapsed. The rail hangs into the screen, so an unbounded one would
    /// run down the whole edge on a machine with many accounts connected.
    static let maxRows = 4

    /// Height of one row: the ring plus the percentage printed under it.
    static let rowHeight: CGFloat = ringDiameter + 12

    static func rowPitch() -> CGFloat { rowHeight + rowSpacing }

    /// Total rows drawn, counting the overflow chip as one.
    static func rowCount(providerCount: Int) -> Int {
        providerCount <= maxRows ? providerCount : maxRows + 1
    }

    /// nil when there is nothing to draw, which is what keeps an empty rail off the screen.
    static func make(screen: ScreenMetrics, providerCount: Int) -> RailGeometry? {
        guard providerCount > 0 else { return nil }

        let drawn = min(providerCount, maxRows)
        let overflow = providerCount - drawn
        let rows = rowCount(providerCount: providerCount)

        let railWidth = ringDiameter + railPadding * 2
        let railHeight = CGFloat(rows) * rowHeight + CGFloat(max(rows - 1, 0)) * rowSpacing + railPadding * 2

        // Tucked under the menu bar band at the right edge, inset so it does not sit flush
        // against the screen border.
        let edgeInset: CGFloat = 8
        let railX = screen.frame.maxX - edgeInset - railWidth
        let railTop = screen.frame.maxY - screen.bandHeight

        // The window also spans the card's footprint to the left, so the card can be drawn
        // without the window growing on hover.
        let windowX = railX - cardWidth - cardGap
        let windowWidth = railWidth + cardWidth + cardGap
        let window = NSRect(
            x: windowX,
            y: railTop - railHeight,
            width: windowWidth,
            height: railHeight
        )

        return RailGeometry(
            window: window,
            rail: CGRect(x: cardWidth + cardGap, y: 0, width: railWidth, height: railHeight),
            drawnCount: drawn,
            overflowCount: overflow
        )
    }

    /// The card's frame for a hovered row, in the same top-left space as `rail`. Kept inside the
    /// window vertically, so hovering the bottom row does not push it off the edge.
    func card(forRow index: Int, height: CGFloat) -> CGRect {
        let rowTop = Self.railPadding + CGFloat(index) * Self.rowPitch()
        let centred = rowTop + Self.rowHeight / 2 - height / 2
        let clamped = min(max(centred, 0), max(window.height - height, 0))
        return CGRect(x: 0, y: clamped, width: Self.cardWidth, height: height)
    }
}

/// The parts of an NSScreen the rail actually depends on, split out so the geometry can be
/// exercised against sizes no machine here has.
struct ScreenMetrics: Equatable {
    let frame: NSRect
    /// Height of the menu bar band. The rail hangs below it rather than inside it.
    let bandHeight: CGFloat

    init(frame: NSRect, bandHeight: CGFloat) {
        self.frame = frame
        self.bandHeight = bandHeight
    }
}
