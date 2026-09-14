import Combine
import Foundation

enum TokiTab: String, CaseIterable, Identifiable {
    case accounts = "Accounts"
    case agents = "Agents"
    case analytics = "Analytics"
    case events = "Events"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .accounts: return "person.crop.circle"
        case .agents: return "terminal"
        case .analytics: return "chart.bar.xaxis"
        case .events: return "bell.badge"
        }
    }
}

enum PopoverPage {
    case main
    case settings
    case changelog
}

/// Owned by the app delegate, not a disappearing tab. Navigation and drafts survive the
/// transient popover closing without becoming account configuration or persisted preferences.
@MainActor
final class PopoverPresentationState: ObservableObject {
    @Published var selectedTab: TokiTab = .accounts
    @Published var page: PopoverPage = .main
    @Published var accountScrollID: String?
    @Published private(set) var accountOrder: [String] = []
    @Published var confirmingQuit = false
    @Published var contentHeight = popoverHeight()

    let accounts = AccountPresentationState()
    let analytics = AnalyticsPresentationState()
    let events = EventPresentationState()
    let settings = SettingsNavigationState()

    func select(_ tab: TokiTab) {
        selectedTab = tab
        page = .main
    }

    func openSettings(remoteControl: Bool = false) {
        if remoteControl {
            settings.openRemoteControl()
        } else {
            settings.openSettings()
        }
        page = .settings
    }

    func openConfigEditor() {
        settings.openConfigEditor()
        page = .settings
    }

    /// Returns false only when Escape should dismiss the main popover.
    @discardableResult
    func goBack() -> Bool {
        switch page {
        case .main: return false
        case .settings:
            if !settings.goBack() { page = .main }
        case .changelog:
            page = .main
        }
        return true
    }

    func beginPresentation(snapshots: [AccountSnapshot], agents: [ActiveAgent]) {
        accountOrder = Self.rankedAccountIDs(snapshots: snapshots, agents: agents)
        retainPresentAccounts(snapshots.map(\.id))
    }

    func retainPresentAccounts(_ ids: [String]) {
        accountOrder = Self.reconciledOrder(accountOrder, presentIDs: ids)
        if let accountScrollID, !ids.contains(accountScrollID) { self.accountScrollID = nil }
    }

    nonisolated static func reconciledOrder(_ previous: [String], presentIDs: [String]) -> [String] {
        let present = Set(presentIDs)
        var seen = Set<String>()
        return (previous.filter { present.contains($0) } + presentIDs).filter { seen.insert($0).inserted }
    }

    nonisolated static func rankedAccountIDs(snapshots: [AccountSnapshot], agents: [ActiveAgent]) -> [String] {
        func priority(_ snapshot: AccountSnapshot) -> Int {
            if snapshot.isError { return 2 }
            return snapshot.remainingRatio.map { $0 <= 0 ? 1 : 0 } ?? 0
        }
        func activity(_ snapshot: AccountSnapshot) -> Date {
            let latest = agents.filter { $0.provider == snapshot.provider }.compactMap(\.lastActivity).max()
            return [latest, snapshot.lastActivity].compactMap { $0 }.max() ?? .distantPast
        }
        return snapshots.enumerated().sorted { lhs, rhs in
            let a = lhs.element, b = rhs.element
            if priority(a) != priority(b) { return priority(a) < priority(b) }
            if activity(a) != activity(b) { return activity(a) > activity(b) }
            return lhs.offset < rhs.offset
        }.map(\.element.id)
    }
}
