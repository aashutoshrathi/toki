import ServiceManagement

// Thin wrapper over SMAppService.mainApp - the modern (macOS 13+) way for an app to
// register itself as a login item without a separate helper target. Deliberately has no
// stored/persisted preference: SMAppService's own registration status is the single
// source of truth, so the Settings toggle can't drift out of sync with what System
// Settings > General > Login Items actually shows (e.g. if the user removes it there).
enum LaunchAtLogin {
    // .requiresApproval counts as enabled: the item IS registered, just pending a flip in
    // System Settings > Login Items. Treating it as disabled would snap the toggle back
    // off right after the user turned it on, contradicting the "Needs approval" note
    // shown alongside it.
    static var isEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    // macOS sometimes requires the user to flip a switch in System Settings > Login
    // Items before a freshly-registered item actually runs at login - register()
    // succeeds either way, so the UI needs to check this separately to explain why
    // the toggle is on but login-launching isn't active yet.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        let status = SMAppService.mainApp.status
        if enabled {
            guard status != .enabled, status != .requiresApproval else { return }
            try SMAppService.mainApp.register()
        } else {
            guard status != .notRegistered else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
