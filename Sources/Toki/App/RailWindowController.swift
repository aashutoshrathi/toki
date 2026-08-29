import AppKit
import SwiftUI

/// Hosts the quota rail: a borderless window docked under the menu bar at the right screen edge.
///
/// Separate from `NotchWindowController` because it anchors to the screen rather than the camera
/// housing, so it needs no `auxiliaryTopArea` and runs on external displays and Macs with no
/// notch. The window mechanics are the same shape: above the menu bar, click-through except
/// where something is actually drawn.
@MainActor
final class RailWindowController {
    private var window: NSWindow?
    private var hostingView: RailHostingView<RailPanel>?
    private let onClick: () -> Void
    private var snapshots: [AccountSnapshot] = []
    private var hoveredID: String?
    private var spaceObserver: NSObjectProtocol?

    init(snapshots: [AccountSnapshot], onClick: @escaping () -> Void) {
        self.snapshots = snapshots
        self.onClick = onClick
        // Full screen takes the menu bar away, and the rail hangs off it, so it would end up
        // floating over the app's own content with nothing to attach to.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.show() }
        }
    }

    /// Explicit rather than a deinit: the observer is not Sendable, so Swift 6 will not let a
    /// nonisolated deinit touch it. The caller drops the rail through here when it turns off.
    func invalidate() {
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
            self.spaceObserver = nil
        }
        hide()
    }

    /// Providers with a quota to draw. Cost-only and detection-only accounts have no ring, and a
    /// rail of empty circles says less than no rail at all.
    private var ringSnapshots: [AccountSnapshot] {
        snapshots.filter { !$0.isError && $0.remainingRatio != nil }
    }

    private static func metrics(for screen: NSScreen?) -> ScreenMetrics? {
        guard let screen else { return nil }
        // safeAreaInsets.top is 0 on a display with no notch, so fall back to the menu bar's own
        // height, which is what the rail actually hangs from.
        let band = screen.safeAreaInsets.top > 0
            ? screen.safeAreaInsets.top
            : screen.frame.maxY - screen.visibleFrame.maxY
        return ScreenMetrics(frame: screen.frame, bandHeight: band)
    }

    /// False in full screen, where the menu bar is gone.
    private var bandIsVisible: Bool {
        guard let screen = NSScreen.main else { return false }
        return screen.visibleFrame.maxY < screen.frame.maxY
    }

    func update(snapshots: [AccountSnapshot]) {
        self.snapshots = snapshots
        if hoveredID != nil, !ringSnapshots.contains(where: { $0.id == hoveredID }) {
            hoveredID = nil
        }
        show()
    }

    @discardableResult
    func show() -> Bool {
        guard bandIsVisible,
              let metrics = Self.metrics(for: NSScreen.main),
              let geometry = RailGeometry.make(screen: metrics, providerCount: ringSnapshots.count) else {
            hide()
            return false
        }

        let window = self.window ?? makeWindow()
        self.window = window
        window.setFrame(geometry.window, display: true)
        render(geometry)
        window.orderFrontRegardless()
        return window.isVisible
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
        hostingView = nil
        hoveredID = nil
    }

    private func render(_ geometry: RailGeometry) {
        let panel = RailPanel(
            snapshots: ringSnapshots,
            geometry: geometry,
            hoveredID: hoveredID,
            onHover: { [weak self] id in
                guard let self, self.hoveredID != id else { return }
                self.hoveredID = id
                self.show()
            },
            onClick: onClick
        )

        if let hostingView {
            hostingView.rootView = panel
        } else if let window {
            let view = RailHostingView(rootView: panel)
            window.contentView = view
            hostingView = view
        }
        // No flip: NSHostingView is isFlipped, so the geometry's top-left space is already the
        // space the rail is drawn in.
        hostingView?.interactiveRect = geometry.rail
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.level = .statusBar + 1
        // No fullScreenAuxiliary: the rail hides in full screen rather than floating over it.
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        return window
    }
}

// The window spans the card's footprint as well as the rail, so without this the empty half
// would swallow clicks meant for whatever is behind it.
private final class RailHostingView<Content: View>: NSHostingView<Content> {
    var interactiveRect: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return interactiveRect.contains(local) ? super.hitTest(point) : nil
    }
}
