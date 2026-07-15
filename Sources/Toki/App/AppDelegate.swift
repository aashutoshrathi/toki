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
            // pulled out of the overflow ("hidden items") menu - and NSPopover occasionally
            // falls back to the screen origin, showing up at the top-left corner instead of
            // under the icon. Deferring one runloop tick lets the button's frame settle first.
            DispatchQueue.main.async { [weak self] in
                guard let self, let button = self.statusItem.button else { return }
                let anchorRect = button.bounds.isEmpty
                    ? NSRect(x: 0, y: 0, width: self.statusItem.length, height: NSStatusBar.system.thickness)
                    : button.bounds
                self.popover.show(relativeTo: anchorRect, of: button, preferredEdge: .minY)
                self.popover.contentViewController?.view.window?.makeKey()
            }
            store.refresh(keepsExistingSnapshots: true, minimumRefreshInterval: 60)
            store.refreshActiveAgents()
            store.rescanProvidersIfNeeded()
        }
    }
}
