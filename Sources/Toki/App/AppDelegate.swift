import AppKit
import SwiftUI

final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

func popoverStatusFrameIsUsable(
    _ candidate: NSRect,
    screenFrames: [NSRect],
    activationPoint: NSPoint?,
    lastKnownFrame: NSRect?
) -> Bool {
    guard candidate.width > 0, candidate.height > 0,
          let candidateScreen = screenFrames.first(where: { $0.intersects(candidate) }) else {
        return false
    }

    if let activationPoint {
        guard candidateScreen.contains(activationPoint) else { return false }
        // The action came from this button, so its settled horizontal bounds must remain under
        // the click. During an auto-hide reveal AppKit can briefly report a far-left frame on the
        // correct display; checking the display alone cannot distinguish that transient frame.
        return activationPoint.x >= candidate.minX - 12 && activationPoint.x <= candidate.maxX + 12
    }

    // Non-pointer activation has no click to validate against. Retain the old jump guard only
    // within one display; moving the active menu bar to another display is a legitimate jump.
    if let lastKnownFrame,
       let lastScreen = screenFrames.first(where: { $0.intersects(lastKnownFrame) }),
       lastScreen == candidateScreen,
       abs(candidate.midX - lastKnownFrame.midX) > 200 {
        return false
    }
    return true
}

func popoverFallbackAnchorX(
    on screenFrame: NSRect,
    activationPoint: NSPoint?,
    lastKnownFrame: NSRect?
) -> CGFloat {
    let x: CGFloat
    if let activationPoint, screenFrame.contains(activationPoint) {
        x = activationPoint.x
    } else if let lastKnownFrame,
              screenFrame.contains(NSPoint(x: lastKnownFrame.midX, y: lastKnownFrame.midY)) {
        x = lastKnownFrame.midX
    } else {
        x = screenFrame.midX
    }
    return min(max(x, screenFrame.minX + 1), screenFrame.maxX - 1)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var statusHostingView: PassthroughHostingView<MenuBarStatusView>?
    private let popover = NSPopover()
    private let store = UsageStore()
    private let updateChecker = UpdateChecker()

    func applicationWillTerminate(_ notification: Notification) {
        RemoteControlServer.shared.stop()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DiagnosticLogger.shared.record(.info, component: "app", code: "launched", detail: "version=\(appVersion)")
        NSApp.setActivationPolicy(.accessory)
        installCLISymlink()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItem()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        popover.behavior = .transient
        popover.contentSize = NSSize(width: popoverWidth(), height: popoverHeight())
        let popoverController = NSHostingController(
            rootView: MenuContentView(store: store, updateChecker: updateChecker)
        )
        // Keep AppKit's hosting layer clear so the popover's native material remains visible.
        popoverController.view.wantsLayer = true
        popoverController.view.layer?.backgroundColor = NSColor.clear.cgColor
        popoverController.view.layer?.isOpaque = false
        popover.contentViewController = popoverController
        popover.delegate = self

        updateChecker.startAutomaticChecks()

        // Two independent publishers, so each is cached and the item rebuilt from both.
        Task { @MainActor in
            for await entries in store.$statusEntries.values {
                latestEntries = entries.isEmpty ? menuBarPlaceholderEntries() : entries
                updateStatusItem()
            }
        }

        Task { @MainActor in
            for await agents in store.$activeAgents.values {
                agentsAwaitingInput = agents.filter(\.needsInput).count
                updateStatusItem()
            }
        }

        Task { @MainActor in
            for await preferences in store.$preferences.values {
                notchController?.update(placement: preferences.notchPlacement)
                applyNotchMode(enabled: preferences.notchModeEnabled)
            }
        }
    }

    private var latestEntries: [MenuBarStatusEntry] = menuBarPlaceholderEntries()
    private var agentsAwaitingInput = 0
    private var latestContentWidth: CGFloat = 0
    private var notchController: NotchWindowController?

    // Replaces the status item rather than duplicating it. With no notch the toggle is a
    // no-op, so the app can never end up with no visible surface.
    private func applyNotchMode(enabled: Bool) {
        let active = enabled && NotchWindowController.isSupported
        if active {
            if notchController == nil {
                notchController = NotchWindowController(
                    entries: latestEntries,
                    awaitingInput: agentsAwaitingInput,
                    contentWidth: latestContentWidth,
                    placement: store.preferences.notchPlacement,
                    onClick: { [weak self] in self?.togglePopover() }
                )
            }
            // Only give up the status item once the panel is confirmed on screen.
            if notchController?.show() == true {
                statusItem.isVisible = false
                return
            }
            notchController = nil
            statusItem.isVisible = true
            DiagnosticLogger.shared.record(.warning, component: "notch", code: "fell_back_to_menu_bar")
        } else {
            notchController?.hide()
            notchController = nil
            statusItem.isVisible = true
        }
        updateStatusItem()
    }

    private func installCLISymlink() {
        guard let executableURL = Bundle.main.executableURL else { return }
        let symlinkPath = "/usr/local/bin/toki"
        let symlinkURL = URL(fileURLWithPath: symlinkPath)
        guard (try? symlinkURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: symlinkPath)) != executableURL.path else { return }
        try? FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: executableURL)
        if FileManager.default.fileExists(atPath: symlinkPath) {
            DiagnosticLogger.shared.record(.info, component: "cli", code: "symlink_installed", detail: symlinkPath)
        }
    }

    private func updateStatusItem() {
        let content = MenuBarStatusView(entries: latestEntries, awaitingInput: agentsAwaitingInput)
        guard let button = statusItem.button else { return }
        let hostingView: PassthroughHostingView<MenuBarStatusView>
        if let existing = statusHostingView {
            existing.rootView = content
            hostingView = existing
        } else {
            hostingView = PassthroughHostingView(rootView: content)
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            // `appearance` is deliberately left nil so the view inherits the menu bar's, not
            // the app's - they disagree in full screen, where the bar is dark in light mode.
            button.addSubview(hostingView)
            statusHostingView = hostingView
        }

        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        let width = max(54, ceil(fittingSize.width) + 6)

        // The notch panel shows the same readout, so it reuses this measurement.
        latestContentWidth = ceil(fittingSize.width)
        notchController?.update(
            entries: latestEntries,
            awaitingInput: agentsAwaitingInput,
            contentWidth: latestContentWidth
        )

        // The popover anchors to this button, so resizing while it is open drags it. Content
        // still refreshes; only the geometry waits until the popover closes.
        guard !popover.isShown else {
            hasDeferredStatusResize = hasDeferredStatusResize || width != statusItem.length
            return
        }

        hasDeferredStatusResize = false
        statusItem.length = width
        statusItem.button?.title = ""
        statusItem.button?.image = nil
        hostingView.frame = NSRect(x: 3, y: 0, width: width - 6, height: button.bounds.height)
    }

    private var hasDeferredStatusResize = false

    @objc private func togglePopover() {
        guard statusItem.button != nil else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Anchoring immediately can race the status bar's layout pass, and NSPopover then
            // falls back to the screen corner. Defer and retry until the button has a position.
            presentPopover(retriesRemaining: 6, activationPoint: currentPointerActivationPoint())
            store.refresh(keepsExistingSnapshots: true, minimumRefreshInterval: 60)
            store.refreshActiveAgents()
            store.rescanProviders()
        }
    }

    private func currentPointerActivationPoint() -> NSPoint? {
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp:
            return NSEvent.mouseLocation
        default:
            return nil
        }
    }

    // Waits for the button to report a real on-screen position; falls back to a transient
    // anchor window if it never does (hidden behind the notch, or in the overflow menu).
    private func presentPopover(retriesRemaining: Int, activationPoint: NSPoint?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // In notch mode the status item is hidden, so the panel is the anchor.
            if let controller = self.notchController, let anchor = controller.anchorView, anchor.window != nil {
                // The pill, not the window: it can rest to one side of the notch.
                self.popover.show(relativeTo: controller.anchorRect, of: anchor, preferredEdge: .minY)
                self.configurePopoverBackdrop()
                self.popover.contentViewController?.view.window?.makeKey()
                return
            }
            guard let button = self.statusItem.button else { return }
            if self.hasValidScreenPosition(button, activationPoint: activationPoint) {
                self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                self.configurePopoverBackdrop()
                self.popover.contentViewController?.view.window?.makeKey()
            } else if retriesRemaining > 0 {
                // 40ms is long enough to let a menu-bar reveal animation advance without the
                // click feeling laggy across the handful of retries.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                    self?.presentPopover(
                        retriesRemaining: retriesRemaining - 1,
                        activationPoint: activationPoint
                    )
                }
            } else {
                self.showFallbackPopover(activationPoint: activationPoint)
            }
        }
    }

    // The status item's last settled on-screen frame, used both to reject a bad transient
    // position and to anchor the fallback near the icon rather than the screen's centre.
    private var lastKnownStatusFrame: NSRect?

    // `bounds` stays non-empty even off-screen, so convert and require a real display.
    private func hasValidScreenPosition(_ button: NSStatusBarButton, activationPoint: NSPoint?) -> Bool {
        guard !button.bounds.isEmpty, let window = button.window else { return false }
        let screenRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard popoverStatusFrameIsUsable(
            screenRect,
            screenFrames: NSScreen.screens.map(\.frame),
            activationPoint: activationPoint,
            lastKnownFrame: lastKnownStatusFrame
        ) else { return false }
        lastKnownStatusFrame = screenRect
        return true
    }

    // A 1x1 click-through window parked under the menu bar, used only when the status item
    // has no reachable position.
    private lazy var fallbackAnchorWindow: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: .borderless, backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        window.level = .statusBar
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        return window
    }()

    private func showFallbackPopover(activationPoint: NSPoint?) {
        // Use the original click even if the pointer moved while the status bar was settling.
        let referencePoint = activationPoint ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(referencePoint) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen, let anchorView = fallbackAnchorWindow.contentView else { return }

        // A last-known frame from another display is stale for this click. Clamping its global x
        // into this screen would pin the popover to an unrelated edge.
        let anchorX = popoverFallbackAnchorX(
            on: screen.frame,
            activationPoint: activationPoint,
            lastKnownFrame: lastKnownStatusFrame
        )
        let origin = NSPoint(x: anchorX, y: screen.visibleFrame.maxY - 1)
        fallbackAnchorWindow.setFrame(NSRect(origin: origin, size: NSSize(width: 1, height: 1)), display: false)
        fallbackAnchorWindow.orderFrontRegardless()

        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
        configurePopoverBackdrop()
        popover.contentViewController?.view.window?.makeKey()
        DiagnosticLogger.shared.record(.warning, component: "app", code: "popover_fallback_anchor")
    }

    private func configurePopoverBackdrop() {
        guard let contentView = popover.contentViewController?.view else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.layer?.isOpaque = false

        // The popover's system-owned NSVisualEffectView remains responsible for blur,
        // vibrancy, accessibility contrast, and active/inactive appearance.
        contentView.window?.isOpaque = false
        contentView.window?.backgroundColor = .clear
    }

    // Tear the transient anchor down so it never lingers invisibly.
    func popoverDidClose(_ notification: Notification) {
        fallbackAnchorWindow.orderOut(nil)

        if hasDeferredStatusResize {
            updateStatusItem()
        }
    }
}
