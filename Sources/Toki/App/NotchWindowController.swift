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

    init(content: MenuBarStatusView, onClick: @escaping () -> Void) {
        self.content = content
        self.onClick = onClick
    }

    static var isSupported: Bool {
        geometry(for: NSScreen.main) != nil
    }

    /// The anchor the popover should attach to, so it opens under the panel rather than at the
    /// screen corner - the status item is hidden in this mode and cannot anchor anything.
    var anchorView: NSView? { window?.contentView }

    private struct Geometry {
        let notch: NSRect
        let collapsed: NSRect
        let expanded: NSRect
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
    private static func geometry(for screen: NSScreen?) -> Geometry? {
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

        // Height below the band, on top of which the band's own height is added so the window
        // reaches the screen edge.
        let collapsedDrop: CGFloat = 24
        let collapsed = NSRect(
            x: notch.minX,
            y: screenTop - bandHeight - collapsedDrop,
            width: notchWidth,
            height: bandHeight + collapsedDrop
        )

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

    // The window is always the EXPANDED size and never resizes; only the pill inside it grows.
    //
    // Resizing the window on hover is a feedback loop: changing the frame re-lays-out the
    // tracking area, which emits spurious exit/enter events, which toggle the expansion, which
    // resizes again - the panel visibly shook. Holding the frame fixed removes the loop
    // entirely, and hit testing is narrowed to the pill so the transparent remainder does not
    // swallow clicks meant for whatever is underneath.
    @discardableResult
    func show() -> Bool {
        guard let geometry = Self.geometry(for: NSScreen.main) else {
            DiagnosticLogger.shared.record(.warning, component: "notch", code: "no_notch_on_display")
            return false
        }

        let window = self.window ?? makeWindow()
        self.window = window
        window.setFrame(geometry.expanded, display: true)
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
        guard let geometry = Self.geometry(for: NSScreen.main) else { return }
        let panel = NotchPanel(
            content: content,
            isExpanded: isExpanded,
            bandHeight: Self.bandHeight,
            collapsedWidth: geometry.notch.width,
            collapsedHeight: geometry.collapsed.height,
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
        let bounds = geometry.expanded
        let width = isExpanded ? bounds.width : geometry.notch.width
        let height = isExpanded ? bounds.height : geometry.collapsed.height
        // View coordinates are bottom-left origin, and the pill is anchored to the top.
        hostingView.interactiveRect = CGRect(
            x: (bounds.width - width) / 2,
            y: bounds.height - height,
            width: width,
            height: height
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
    /// Height of the menu bar band. The top of the window sits behind the camera housing, so
    /// content has to start below this or hardware would hide it.
    let bandHeight: CGFloat
    let collapsedWidth: CGFloat
    let collapsedHeight: CGFloat
    let onClick: () -> Void
    let onHoverChange: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            pill
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        .padding(.top, bandHeight)
        .padding(.horizontal, isExpanded ? 14 : 6)
        .frame(
            maxWidth: isExpanded ? .infinity : collapsedWidth,
            minHeight: isExpanded ? nil : collapsedHeight,
            alignment: .top
        )
        .background(Color.black)
        // Square top corners: the top edge is flush with the screen edge, behind the housing,
        // so rounding it would carve a visible gap out of the black beside the hardware and
        // break the continuity that makes this read as one shape with the notch.
        .clipShape(BottomRoundedShape(cornerRadius: isExpanded ? 18 : 12))
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onHover(perform: onHoverChange)
        .onTapGesture(perform: onClick)
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: isExpanded)
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
