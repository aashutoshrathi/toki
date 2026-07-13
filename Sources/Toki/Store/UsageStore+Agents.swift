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
}
