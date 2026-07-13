import ServiceManagement

// Thin wrapper over SMAppService.mainApp - the modern (macOS 13+) way for an app to
// register itself as a login item without a separate helper target. Deliberately has no
// stored/persisted preference: SMAppService's own registration status is the single
// source of truth, so the Settings toggle can't drift out of sync with what System
// Settings > General > Login Items actually shows (e.g. if the user removes it there).
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    // macOS sometimes requires the user to flip a switch in System Settings > Login
    // Items before a freshly-registered item actually runs at login - register()
    // succeeds either way, so the UI needs to check this separately to explain why
    // the toggle is on but login-launching isn't active yet.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard SMAppService.mainApp.status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard SMAppService.mainApp.status != .notRegistered else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
