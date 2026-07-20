import AppKit
import SwiftUI

// Experimental Dynamic Island style panel at the display notch.
//
// The gap between auxiliaryTopLeftArea and auxiliaryTopRightArea is the camera housing - no
// pixels behind it, so a window placed there is invisible rather than misplaced. The panel
// draws in the band beside and below the housing instead.
@MainActor
final class NotchWindowController {
    private var window: NSWindow?
    private var hostingView: NotchHostingView<NotchPanel>?
    private let onClick: () -> Void
    private var entries: [MenuBarStatusEntry]
    private var awaitingInput: Int
    private var isExpanded = false
    private var placement: NotchPlacement
    /// Measured, not guessed: a fixed width truncated once a third provider appeared.
    private var contentWidth: CGFloat

    init(entries: [MenuBarStatusEntry], awaitingInput: Int, contentWidth: CGFloat, placement: NotchPlacement, onClick: @escaping () -> Void) {
        self.entries = entries
        self.awaitingInput = awaitingInput
        self.contentWidth = contentWidth
        self.placement = placement
        self.onClick = onClick
    }

    static var isSupported: Bool {
        geometry(for: NSScreen.main, placement: .hanging, contentWidth: 0) != nil
    }

    /// The status item is hidden in this mode, so the panel anchors the popover.
    var anchorView: NSView? { window?.contentView }

    /// The pill's rect, not the window's - the pill can rest off to one side of the notch.
    var anchorRect: CGRect {
        guard let geometry = Self.geometry(for: NSScreen.main, placement: placement, contentWidth: contentWidth),
              window?.contentView != nil else { return .zero }
        // No flip: NSHostingView is isFlipped, so this is already the space the pill is drawn in.
        return geometry.pillInView(expanded: isExpanded)
    }

    private struct Geometry {
        let notch: NSRect
        let collapsed: NSRect
        let expanded: NSRect
        /// Union of both states: the window is held at this size so it never resizes.
        var window: NSRect { collapsed.union(expanded) }

        /// Where the pill sits inside the window, in SwiftUI's top-left origin space.
        func pillInView(expanded isExpanded: Bool) -> CGRect {
            let rect = isExpanded ? expanded : collapsed
            return CGRect(
                x: rect.minX - window.minX,
                y: window.maxY - rect.maxY,
                width: rect.width,
                height: rect.height
            )
        }
    }

    // The window starts at the screen top and extends down past the band. Drawing only below
    // the band leaves two separate black shapes with the menu bar line between them, which
    // reads as a second notch rather than as the real one expanding.
    private static func geometry(for screen: NSScreen?, placement: NotchPlacement, contentWidth: CGFloat) -> Geometry? {
        guard let screen,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }

        // Already global coordinates - re-adding the screen origin would double-count it on a
        // secondary display.
        let notchWidth = right.minX - left.maxX
        guard notchWidth > 0 else { return nil }

        let screenTop = screen.frame.maxY
        let bandHeight = screen.safeAreaInsets.top
        let notch = NSRect(x: left.maxX, y: screenTop - bandHeight, width: notchWidth, height: bandHeight)

        // Sideways rests in the band beside the housing - real display, unlike the housing
        // itself. Right side, where menu bar extras live and the hidden status item was.
        let collapsed: NSRect
        switch placement {
        case .sideways:
            // Sized to the measured readout plus breathing room, and clamped so it can never
            // run off the display or overlap the housing.
            let width = min(max(contentWidth + 20, 90), right.width)
            collapsed = NSRect(x: notch.maxX, y: screenTop - bandHeight, width: width, height: bandHeight)
        case .around:
            // Wraps the housing; the gap matches its width so the halves read as one strip.
            // Sized for the larger half: the split rounds up, so 3 entries divide 2/1.
            let side = min(max(contentWidth * 0.68 + 16, 70), min(left.width, right.width))
            collapsed = NSRect(
                x: notch.minX - side,
                y: screenTop - bandHeight,
                width: notchWidth + side * 2,
                height: bandHeight
            )
        case .hanging:
            // Matches the housing's width and drops below it, so the two read as one shape.
            let drop: CGFloat = 24
            collapsed = NSRect(
                x: notch.minX,
                y: screenTop - bandHeight - drop,
                width: notchWidth,
                height: bandHeight + drop
            )
        }

        let expandedDrop: CGFloat = 84
        let expandedWidth = min(max(notchWidth * 2.1, 360), screen.frame.width - 40)
        let expanded = NSRect(
            x: notch.midX - expandedWidth / 2,
            y: screenTop - bandHeight - expandedDrop,
            width: expandedWidth,
            height: bandHeight + expandedDrop
        )
        return Geometry(notch: notch, collapsed: collapsed, expanded: expanded)
    }

    /// Height of the menu bar band, so the panel can keep its content clear of the hardware.
    private static var bandHeight: CGFloat {
        NSScreen.main?.safeAreaInsets.top ?? 32
    }

    func update(entries: [MenuBarStatusEntry], awaitingInput: Int, contentWidth: CGFloat) {
        self.entries = entries
        self.awaitingInput = awaitingInput
        // Width moves the pill's edges, so recompute the frame.
        let resized = abs(contentWidth - self.contentWidth) > 0.5
        self.contentWidth = contentWidth
        if resized, window != nil {
            show()
        } else {
            render()
        }
    }

    /// Placement changes the window's footprint, so the frame is recomputed.
    func update(placement: NotchPlacement) {
        guard placement != self.placement else { return }
        self.placement = placement
        show()
    }

    // The frame never changes on hover; only the pill inside animates. Resizing the window
    // re-laid the tracking area, which emitted spurious enter/exit events and made it shake.
    @discardableResult
    func show() -> Bool {
        guard let geometry = Self.geometry(for: NSScreen.main, placement: placement, contentWidth: contentWidth) else {
            DiagnosticLogger.shared.record(.warning, component: "notch", code: "no_notch_on_display")
            return false
        }

        let window = self.window ?? makeWindow()
        self.window = window
        window.setFrame(geometry.window, display: true)
        render()
        window.orderFrontRegardless()
        return window.isVisible
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
        hostingView = nil
        isExpanded = false
    }

    private func render() {
        guard let geometry = Self.geometry(for: NSScreen.main, placement: placement, contentWidth: contentWidth) else { return }
        let panel = NotchPanel(
            entries: entries,
            awaitingInput: awaitingInput,
            isExpanded: isExpanded,
            placement: placement,
            bandHeight: Self.bandHeight,
            notchWidth: geometry.notch.width,
            pillRect: geometry.pillInView(expanded: isExpanded),
            onClick: onClick,
            onHoverChange: { [weak self] hovering in self?.setExpanded(hovering) }
        )
        if let hostingView {
            hostingView.rootView = panel
        } else if let window {
            let view = NotchHostingView(rootView: panel)
            window.contentView = view
            hostingView = view
        }
        updateInteractiveRect(geometry: geometry)
    }

    // Limited to the pill so the transparent remainder stays click-through.
    private func updateInteractiveRect(geometry: Geometry) {
        guard let hostingView else { return }
        // No flip: NSHostingView is isFlipped. Flipping put the hit region in the mirror
        // position, so clicks over the pill were rejected while hover still worked.
        hostingView.interactiveRect = geometry.pillInView(expanded: isExpanded)
    }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        render()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        // Above the menu bar, and on every Space including full screen.
        window.level = .statusBar + 1
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        return window
    }
}

// Without this the full expanded footprint swallows clicks meant for the menu bar or desktop.
private final class NotchHostingView<Content: View>: NSHostingView<Content> {
    var interactiveRect: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return interactiveRect.contains(local) ? super.hitTest(point) : nil
    }
}

// Pinned dark: it sits against the black housing, which doesn't follow the system theme.
private struct NotchPanel: View {
    let entries: [MenuBarStatusEntry]
    let awaitingInput: Int
    let isExpanded: Bool
    let placement: NotchPlacement
    /// Content inside the housing's x range and the band's y range is behind hardware.
    let bandHeight: CGFloat
    /// Width of the camera housing, used to leave a matching gap when straddling it.
    let notchWidth: CGFloat
    /// Where the pill goes inside the window, top-left origin, already computed for the
    /// current placement and expansion.
    let pillRect: CGRect
    let onClick: () -> Void
    let onHoverChange: (Bool) -> Void

    /// Sideways sits beside the housing, so its content centres in the band.
    private var clearsHousing: Bool { isExpanded || placement == .hanging }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            pill
                .frame(width: pillRect.width, height: pillRect.height, alignment: .top)
                .offset(x: pillRect.minX, y: pillRect.minY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: isExpanded)
    }

    /// Around splits the readout across both bands; the badge goes right.
    private var straddles: Bool { placement == .around && !isExpanded }

    private var splitPoint: Int { (entries.count + 1) / 2 }

    @ViewBuilder
    private var readout: some View {
        if straddles {
            HStack(spacing: 0) {
                MenuBarStatusView(entries: Array(entries.prefix(splitPoint)))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                // Matches the housing width; nothing renders here.
                Color.clear.frame(width: notchWidth)
                MenuBarStatusView(entries: Array(entries.dropFirst(splitPoint)), awaitingInput: awaitingInput)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            MenuBarStatusView(entries: entries, awaitingInput: awaitingInput)
        }
    }

    private var pill: some View {
        VStack(spacing: isExpanded ? 6 : 0) {
            readout
                .frame(height: 22)
            if isExpanded {
                Text("Click to open Toki")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.top, clearsHousing ? bandHeight : 0)
        .padding(.horizontal, isExpanded ? 14 : 6)
        // Only when expanded; collapsed has no second line.
        .padding(.bottom, isExpanded ? 12 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: clearsHousing ? .top : .center)
        .background(Color.black)
        // Square top corners: the top edge is behind the housing, so rounding shows a gap.
        .clipShape(BottomRoundedShape(cornerRadius: isExpanded ? 18 : 12))
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onHover(perform: onHoverChange)
        .onTapGesture(perform: onClick)
        .pointerOnHover()
    }
}

private struct BottomRoundedShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - cornerRadius))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY),
                control: CGPoint(x: rect.minX, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius),
                control: CGPoint(x: rect.maxX, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.closeSubpath()
        }
    }
}
