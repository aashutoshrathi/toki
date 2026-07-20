import AppKit
import SwiftUI

// Experimental: parks the status readout in the display notch instead of the menu bar.
//
// There is no API for "put my app in the notch" - the notch is simply a region the menu bar
// draws around. What we can do is place a borderless, always-on-top window over that region.
// AppKit describes it via NSScreen.auxiliaryTopLeftArea / auxiliaryTopRightArea: the usable
// menu bar strips either side of the notch. The gap between them is the notch itself, and its
// width is what we size the window to.
//
// Kept behind a preference and labelled experimental because it depends on that geometry
// holding: on a Mac with no notch there is nothing to sit in (auxiliary areas are nil), and
// the window has to be torn down and rebuilt when displays change.
@MainActor
final class NotchWindowController {
    private var window: NSWindow?
    private let onClick: () -> Void
    private var content: MenuBarStatusView

    init(content: MenuBarStatusView, onClick: @escaping () -> Void) {
        self.content = content
        self.onClick = onClick
    }

    /// Whether the main display actually has a notch to render into.
    static var isSupported: Bool {
        notchFrame(for: NSScreen.main) != nil
    }

    // The notch is the gap between the two auxiliary menu bar areas. Both must exist: a
    // display without a notch reports nil, and we must not draw a floating window over the
    // middle of an ordinary menu bar.
    private static func notchFrame(for screen: NSScreen?) -> NSRect? {
        guard let screen,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        let width = right.minX - left.maxX
        guard width > 0 else { return nil }
        return NSRect(
            x: screen.frame.minX + left.maxX,
            y: screen.frame.maxY - screen.safeAreaInsets.top,
            width: width,
            height: max(screen.safeAreaInsets.top, 1)
        )
    }

    func update(content: MenuBarStatusView) {
        self.content = content
        guard let hosting = window?.contentView as? NSHostingView<NotchContent> else { return }
        hosting.rootView = NotchContent(content: content, onClick: onClick)
    }

    func show() {
        guard let frame = Self.notchFrame(for: NSScreen.main) else {
            DiagnosticLogger.shared.record(.warning, component: "notch", code: "no_notch_on_display")
            return
        }

        let window = self.window ?? makeWindow()
        self.window = window
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        // Above the menu bar so the readout isn't clipped by it, and on every Space so the
        // window doesn't vanish when the user switches - including full screen, which is
        // precisely where the notch is most visible.
        window.level = .statusBar + 1
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.contentView = NSHostingView(rootView: NotchContent(content: content, onClick: onClick))
        return window
    }
}

// The notch region is black on every Mac that has one, so the content is pinned to a dark
// appearance rather than following the system theme - the surface it sits on does not change
// with light mode, and inheriting would paint dark text on black in light mode.
private struct NotchContent: View {
    let content: MenuBarStatusView
    let onClick: () -> Void

    var body: some View {
        content
            .environment(\.colorScheme, .dark)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .contentShape(Rectangle())
            .onTapGesture(perform: onClick)
    }
}
