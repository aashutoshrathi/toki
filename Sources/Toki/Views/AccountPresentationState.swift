import SwiftUI

enum AccountDetailTab: String, CaseIterable, Identifiable {
    case usage = "Usage"
    case sessions = "Sessions"
    var id: String { rawValue }
}

/// App-session presentation state belongs outside the transient popover view hierarchy.
/// Recreating a tab must not discard a disclosure, a selected detail view, or its scroll position.
@MainActor
final class AccountPresentationState: ObservableObject {
    @Published var expandedAccountIDs: Set<String> = []
    @Published var detailTabs: [String: AccountDetailTab] = [:]
    @Published var expandedAccountDetails: Set<String> = []
    @Published var quotaOverviewExpanded = true
    @Published var agentsScrollID: Int32?
    @Published private(set) var agentOrder: [Int32] = []

    func detailTab(for snapshot: AccountSnapshot) -> AccountDetailTab {
        detailTabs[snapshot.id] ?? (snapshot.isAgentDetectionOnly ? .sessions : .usage)
    }

    func reconcileAgents(_ agents: [ActiveAgent]) {
        let live = Set(agents.map(\.id))
        let existing = agentOrder.filter { live.contains($0) }
        let known = Set(existing)
        let updated = existing + agents.map(\.id).filter { !known.contains($0) }
        if updated != agentOrder { agentOrder = updated }
    }

    func orderedAgents(_ agents: [ActiveAgent], needsInput: Bool) -> [ActiveAgent] {
        let positions = Dictionary(uniqueKeysWithValues: agentOrder.enumerated().map { ($1, $0) })
        return agents.filter { $0.needsInput == needsInput }.sorted {
            let left = positions[$0.id] ?? Int.max
            let right = positions[$1.id] ?? Int.max
            return left == right ? $0.id < $1.id : left < right
        }
    }
}
