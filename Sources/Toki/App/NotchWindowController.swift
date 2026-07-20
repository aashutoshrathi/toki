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
    private var hostingView: NSHostingView<NotchPanel>?
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

    private static func geometry(for screen: NSScreen?) -> Geometry? {
        guard let screen,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }

        // Already global coordinates - re-adding the screen origin would double-count it on a
        // secondary display.
        let notchWidth = right.minX - left.maxX
        guard notchWidth > 0 else { return nil }

        let bandTop = screen.frame.maxY
        let bandBottom = bandTop - screen.safeAreaInsets.top
        let notch = NSRect(x: left.maxX, y: bandBottom, width: notchWidth, height: screen.safeAreaInsets.top)

        let collapsedHeight: CGFloat = 26
        let collapsed = NSRect(
            x: notch.minX,
            y: bandBottom - collapsedHeight,
            width: notchWidth,
            height: collapsedHeight
        )

        // Expanded is centred on the notch so the growth reads as symmetric.
        let expandedWidth = min(max(notchWidth * 2.2, 380), screen.frame.width - 40)
        let expandedHeight: CGFloat = 108
        let expanded = NSRect(
            x: notch.midX - expandedWidth / 2,
            y: bandBottom - expandedHeight,
            width: expandedWidth,
            height: expandedHeight
        )
        return Geometry(notch: notch, collapsed: collapsed, expanded: expanded)
    }

    func update(content: MenuBarStatusView) {
        self.content = content
        render()
    }

    @discardableResult
    func show() -> Bool {
        guard let geometry = Self.geometry(for: NSScreen.main) else {
            DiagnosticLogger.shared.record(.warning, component: "notch", code: "no_notch_on_display")
            return false
        }

        let window = self.window ?? makeWindow()
        self.window = window
        window.setFrame(isExpanded ? geometry.expanded : geometry.collapsed, display: true)
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
        let panel = NotchPanel(
            content: content,
            isExpanded: isExpanded,
            notchWidth: Self.geometry(for: NSScreen.main)?.notch.width ?? 180,
            onClick: onClick
        )
        if let hostingView {
            hostingView.rootView = panel
        } else if let window {
            let view = NSHostingView(rootView: panel)
            window.contentView = view
            hostingView = view
        }
    }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded, let window, let geometry = Self.geometry(for: NSScreen.main) else { return }
        isExpanded = expanded
        render()
        // Animating the frame rather than snapping is most of what makes this read as one
        // surface growing instead of a second window appearing.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(expanded ? geometry.expanded : geometry.collapsed, display: true)
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NotchWindow(
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
        window.onHoverChange = { [weak self] hovering in
            self?.setExpanded(hovering)
        }
        return window
    }
}

// Tracks pointer enter/exit for the whole panel. A tracking area on the window's content view
// is used rather than SwiftUI's .onHover because the window itself has to resize in response,
// and that has to be driven from AppKit.
private final class NotchWindow: NSWindow {
    var onHoverChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        refreshTrackingArea()
    }

    private func refreshTrackingArea() {
        guard let contentView else { return }
        if let trackingArea { contentView.removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: contentView.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        contentView.addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

// Pinned to a dark appearance rather than following the system theme: the surface this sits
// against is the black camera housing, which does not change with light mode, so inheriting
// would paint dark text on black.
private struct NotchPanel: View {
    let content: MenuBarStatusView
    let isExpanded: Bool
    let notchWidth: CGFloat
    let onClick: () -> Void

    var body: some View {
        VStack(spacing: isExpanded ? 8 : 0) {
            content
                .frame(height: 22)
            if isExpanded {
                Text("Click to open Toki")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, isExpanded ? 14 : 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        // Only the bottom corners are rounded. Square top corners keep the panel flush with
        // the housing above it, which is what makes the two read as one shape rather than a
        // floating rectangle parked under the notch.
        .clipShape(NotchShape(cornerRadius: isExpanded ? 16 : 10))
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onTapGesture(perform: onClick)
    }
}

private struct NotchShape: Shape {
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
