import Foundation

extension UsageStore {
    func refreshActiveAgents() {
        // Serialize scans: a slow scan must not overlap the next tick, or two detached
        // tasks would race the scanner's PID cache. isScanningAgents is MainActor-isolated.
        guard !isScanningAgents else { return }
        isScanningAgents = true
        Task {
            activeAgents = await ActiveAgentScanner.scan()
            isScanningAgents = false
        }
    }

    // Drops the row immediately for a responsive feel, then reconciles with a real scan
    // shortly after in case the signal didn't actually take effect (e.g. no permission).
    func terminateAgent(_ agent: ActiveAgent) {
        ActiveAgentTerminator.terminate(agent)
        activeAgents.removeAll { $0.id == agent.id }
        Task {
            try? await Task.sleep(for: .seconds(1))
            refreshActiveAgents()
        }
    }
}
