import AppKit
import SwiftUI

final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var statusHostingView: PassthroughHostingView<MenuBarStatusView>?
    private let popover = NSPopover()
    private let store = UsageStore()
    private let updateChecker = UpdateChecker()

    func applicationDidFinishLaunching(_ notification: Notification) {
        DiagnosticLogger.shared.record(.info, component: "app", code: "launched", detail: "version=\(appVersion)")
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItem(entries: menuBarPlaceholderEntries())
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        popover.behavior = .transient
        popover.contentSize = NSSize(width: popoverWidth(), height: popoverHeight())
        popover.contentViewController = NSHostingController(
            rootView: MenuContentView(store: store, updateChecker: updateChecker)
        )
        popover.delegate = self

        updateChecker.startAutomaticChecks()

        Task { @MainActor in
            for await entries in store.$statusEntries.values {
                updateStatusItem(entries: entries.isEmpty ? menuBarPlaceholderEntries() : entries)
            }
        }
    }

    private func updateStatusItem(entries: [MenuBarStatusEntry]) {
        guard let button = statusItem.button else { return }
        let content = MenuBarStatusView(entries: entries)
        let hostingView: PassthroughHostingView<MenuBarStatusView>
        if let existing = statusHostingView {
            existing.rootView = content
            hostingView = existing
        } else {
            hostingView = PassthroughHostingView(rootView: content)
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            hostingView.appearance = NSApp.effectiveAppearance
            button.addSubview(hostingView)
            statusHostingView = hostingView
        }

        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        let width = max(54, ceil(fittingSize.width) + 6)
        statusItem.length = width
        statusItem.button?.title = ""
        statusItem.button?.image = nil
        hostingView.frame = NSRect(x: 3, y: 0, width: width - 6, height: button.bounds.height)
    }

    @objc private func togglePopover() {
        guard statusItem.button != nil else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Anchoring immediately on the click can race the status bar's own layout pass -
            // e.g. right after updateStatusItem resizes the button, or when the item was just
            // pulled out of the overflow ("hidden items") menu, or when the menu bar is set to
            // auto-hide and is still sliding into view - and NSPopover falls back to the screen
            // origin, showing up at the top-left corner instead of under the icon. Deferring and,
            // if needed, retrying until the button actually has a valid on-screen position lets
            // the status item settle first.
            presentPopover(retriesRemaining: 6)
            store.refresh(keepsExistingSnapshots: true, minimumRefreshInterval: 60)
            store.refreshActiveAgents()
            store.rescanProviders()
        }
    }

    // Shows the popover only once the status item's button reports a real position on a screen.
    // While the menu bar is hidden/animating the button exists (so bounds are non-empty) but its
    // window isn't placed on any screen yet, which is exactly when NSPopover would pin to the
    // top-left. We back off a few runloop ticks waiting for that to resolve, then fall back to a
    // synthetic anchor rather than never opening.
    private func presentPopover(retriesRemaining: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            if self.hasValidScreenPosition(button) || retriesRemaining <= 0 {
                let anchorRect = button.bounds.isEmpty
                    ? NSRect(x: 0, y: 0, width: self.statusItem.length, height: NSStatusBar.system.thickness)
                    : button.bounds
                self.popover.show(relativeTo: anchorRect, of: button, preferredEdge: .minY)
                self.popover.contentViewController?.view.window?.makeKey()
            } else {
                // 40ms is long enough to let a menu-bar reveal animation advance without the
                // click feeling laggy across the handful of retries.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                    self?.presentPopover(retriesRemaining: retriesRemaining - 1)
                }
            }
        }
    }

    // The button's local `bounds` stay non-empty even when its window is off-screen, so checking
    // bounds alone (the old guard) never caught the hidden-menu-bar case. Convert to screen
    // coordinates and require the result to actually land on a connected display.
    private func hasValidScreenPosition(_ button: NSStatusBarButton) -> Bool {
        guard !button.bounds.isEmpty, let window = button.window else { return false }
        let screenRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard screenRect.width > 0, screenRect.height > 0 else { return false }
        return NSScreen.screens.contains { $0.frame.intersects(screenRect) }
    }
}
