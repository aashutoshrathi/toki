import AppKit
import SwiftUI

// Experimental: a Dynamic Island style panel hanging off the display notch.
//
// The notch itself is not a drawing surface. The gap between NSScreen's
// auxiliaryTopLeftArea and auxiliaryTopRightArea is the camera housing - physical hardware
// with no pixels behind it - so a window placed there is not clipped or mispositioned, it is
// simply invisible. The illusion works the way it does on iPhone: draw in the display area
// *immediately below* the housing, in black, with only the bottom corners rounded, so the
// panel reads as the notch having grown downward.
//
// Collapsed it matches the housing's width exactly, which is what sells the join. On hover it
// expands wider and taller to show detail, then settles back.
@MainActor
final class NotchWindowController {
    private var window: NSWindow?
    private var hostingView: NotchHostingView<NotchPanel>?
    private let onClick: () -> Void
    private var content: MenuBarStatusView
    private var isExpanded = false
    private var placement: NotchPlacement

    init(content: MenuBarStatusView, placement: NotchPlacement, onClick: @escaping () -> Void) {
        self.content = content
        self.placement = placement
        self.onClick = onClick
    }

    static var isSupported: Bool {
        geometry(for: NSScreen.main, placement: .hanging) != nil
    }

    /// The anchor the popover should attach to, so it opens under the panel rather than at the
    /// screen corner - the status item is hidden in this mode and cannot anchor anything.
    var anchorView: NSView? { window?.contentView }

    /// The pill's own rect within that view. Anchoring to the whole window would centre the
    /// popover on the notch, but the resting pill sits off to one side of it, so the popover
    /// would open away from what was actually clicked.
    var anchorRect: CGRect {
        guard let geometry = Self.geometry(for: NSScreen.main, placement: placement), let contentView = window?.contentView else { return .zero }
        let inView = geometry.pillInView(expanded: isExpanded)
        // NSView is bottom-left origin; the layout above is top-left.
        return CGRect(
            x: inView.minX,
            y: contentView.bounds.height - inView.maxY,
            width: inView.width,
            height: inView.height
        )
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

    // The window starts at the very top of the screen and extends DOWN past the menu bar band,
    // rather than starting below the band.
    //
    // Drawing only below the band produces two separate black shapes with the menu bar line
    // between them - it reads as a second notch bolted underneath the real one, not as the
    // notch expanding. The housing is opaque hardware, so the part of the window behind it is
    // simply never seen; what matters is that the black is continuous either side of it. When
    // collapsed the window is exactly the housing's width, so only the strip below shows and
    // the two read as one shape. When expanded it grows wider than the housing and its upper
    // portion covers the band on both sides, which is what makes the island look like it grew
    // out of the notch rather than appearing beneath it.
    private static func geometry(for screen: NSScreen?, placement: NotchPlacement) -> Geometry? {
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

        // At rest the pill sits IN the band, flush against the right edge of the housing, so
        // the black reads as the notch simply being wider rather than as something hanging
        // below it. The band either side of the housing is real display - only the housing
        // itself has no pixels - so this is the one part of "the notch area" that is usable.
        //
        // Right side specifically: on a notched Mac the menu bar extras start there, and in
        // this mode Toki's own status item is hidden, so it is broadly reclaiming its own space
        // rather than covering an app's menus on the left.
        let collapsed: NSRect
        switch placement {
        case .sideways:
            collapsed = NSRect(x: notch.maxX, y: screenTop - bandHeight, width: 108, height: bandHeight)
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

    func update(content: MenuBarStatusView) {
        self.content = content
        render()
    }

    /// Switching placement moves the resting pill, which changes the window's footprint, so the
    /// frame is recomputed rather than only the content redrawn.
    func update(placement: NotchPlacement) {
        guard placement != self.placement else { return }
        self.placement = placement
        show()
    }

    // The window is always the EXPANDED size and never resizes; only the pill inside it grows.
    //
    // Resizing the window on hover is a feedback loop: changing the frame re-lays-out the
    // tracking area, which emits spurious exit/enter events, which toggle the expansion, which
    // resizes again - the panel visibly shook. Holding the frame fixed removes the loop
    // entirely, and hit testing is narrowed to the pill so the transparent remainder does not
    // swallow clicks meant for whatever is underneath.
    @discardableResult
    func show() -> Bool {
        guard let geometry = Self.geometry(for: NSScreen.main, placement: placement) else {
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
        guard let geometry = Self.geometry(for: NSScreen.main, placement: placement) else { return }
        let panel = NotchPanel(
            content: content,
            isExpanded: isExpanded,
            placement: placement,
            bandHeight: Self.bandHeight,
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

    // Hit testing is limited to the pill, so the transparent area around it stays click-through.
    private func updateInteractiveRect(geometry: Geometry) {
        guard let hostingView else { return }
        let inView = geometry.pillInView(expanded: isExpanded)
        // View coordinates are bottom-left origin; the layout above is top-left.
        hostingView.interactiveRect = CGRect(
            x: inView.minX,
            y: geometry.window.height - inView.maxY,
            width: inView.width,
            height: inView.height
        )
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
        // Above the menu bar so the panel is not clipped by it, and present on every Space -
        // including full screen, which is where the notch is most visible.
        window.level = .statusBar + 1
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        return window
    }
}

// Passes through clicks that land outside the pill. Without this the window's full expanded
// footprint would swallow events over the menu bar and desktop even while collapsed.
private final class NotchHostingView<Content: View>: NSHostingView<Content> {
    var interactiveRect: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return interactiveRect.contains(local) ? super.hitTest(point) : nil
    }
}

// Pinned to a dark appearance rather than following the system theme: the surface this sits
// against is the black camera housing, which does not change with light mode, so inheriting
// would paint dark text on black.
private struct NotchPanel: View {
    let content: MenuBarStatusView
    let isExpanded: Bool
    let placement: NotchPlacement
    /// Height of the menu bar band. Anything drawn in the band's own vertical range and inside
    /// the housing's x range is behind hardware, so content has to clear it.
    let bandHeight: CGFloat
    /// Where the pill goes inside the window, top-left origin, already computed for the
    /// current placement and expansion.
    let pillRect: CGRect
    let onClick: () -> Void
    let onHoverChange: (Bool) -> Void

    /// Sideways rests inside the band, so its content is centred in the band rather than pushed
    /// below it - it sits beside the housing, not under it.
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

    private var pill: some View {
        VStack(spacing: isExpanded ? 6 : 0) {
            content
                .frame(height: 22)
            if isExpanded {
                Text("Click to open Toki")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.top, clearsHousing ? bandHeight : 0)
        .padding(.horizontal, isExpanded ? 14 : 6)
        // The hint sat flush against the rounded bottom edge, which cramped it against the
        // curve. Only applies when expanded - collapsed has no second line to space away.
        .padding(.bottom, isExpanded ? 12 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: clearsHousing ? .top : .center)
        .background(Color.black)
        // Square top corners: the top edge is flush with the screen edge, behind the housing,
        // so rounding it would carve a visible gap out of the black beside the hardware and
        // break the continuity that makes this read as one shape with the notch.
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
