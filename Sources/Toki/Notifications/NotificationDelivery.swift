import Foundation
import UserNotifications

/// What macOS says about notifications for this app, read rather than assumed.
enum NotificationAuthorization: Equatable, Sendable {
    case authorized
    case denied
    case notDetermined
    /// The API cannot be used in this build at all, with the reason. Not a user decision, so it
    /// is kept distinct from `denied` - there is nothing to grant and nowhere to send someone.
    case unavailable(String)

    var allowsDelivery: Bool { self == .authorized }

    /// Why a notification cannot be handed over right now, or nil when it can.
    var deliveryBlocker: String? {
        switch self {
        case .authorized: return nil
        case .denied: return "macOS is set to not allow notifications from Toki. Allow it under System Settings › Notifications."
        case .notDetermined: return "macOS has not been asked about notifications yet."
        case .unavailable(let reason): return reason
        }
    }
}

/// The one place that talks to UserNotifications.
///
/// `UNUserNotificationCenter.current()` traps unless the executable is a real .app. Guarding on
/// that first is what makes the API safe to call from any build, and lets one that cannot
/// deliver say so instead of reporting success it never had.
enum NotificationDelivery {
    static var unavailableReason: String? {
        // Both conditions: `swift run Toki` has no bundle identifier, and the test runner has
        // one but is not an .app. Either alone lets through a case that traps with
        // "bundleProxyForCurrentProcess is nil".
        guard Bundle.main.bundleIdentifier != nil,
              Bundle.main.bundleURL.pathExtension == "app" else {
            return "This build has no app bundle, so macOS has nothing to attribute a notification to. Run Toki from Toki.app."
        }
        return nil
    }

    /// Reads the current status without prompting, so a checklist can show it before anything
    /// is asked for.
    static func authorizationStatus() async -> NotificationAuthorization {
        if let unavailableReason { return .unavailable(unavailableReason) }
        return mapped(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
    }

    /// Puts macOS's own prompt up while the status is undetermined, and reports where that
    /// left things. Once denied, macOS will not ask again, so this reads back as `denied`
    /// rather than prompting a second time.
    static func requestAuthorization() async -> NotificationAuthorization {
        if let unavailableReason { return .unavailable(unavailableReason) }
        // The granted flag is ignored in favour of reading the settings back: a request made
        // while already denied resolves false without that meaning anything changed.
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        return await authorizationStatus()
    }

    /// Hands a notification to macOS. Returns nil on success, or why it could not be handed
    /// over. Whether macOS then draws it on screen is its own decision and not observable.
    static func deliver(title: String, body: String) async -> String? {
        let status = await authorizationStatus()
        if let blocker = status.deliveryBlocker { return blocker }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func mapped(_ status: UNAuthorizationStatus) -> NotificationAuthorization {
        switch status {
        // Provisional delivers quietly to Notification Centre, which still counts as reaching
        // the user; ephemeral is an App Clip state Toki cannot be in, mapped for completeness.
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }
}
