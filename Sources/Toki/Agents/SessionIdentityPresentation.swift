import Foundation

/// Uses only discovered session facts. Similar labels are a presentation collision, not
/// evidence that two processes are the same session or safe to navigate interchangeably.
struct SessionIdentityPresentation: Equatable {
    let title: String
    let context: String?
    let detail: String

    init(agent: ActiveAgent, among agents: [ActiveAgent]) {
        let primaryTitle = Self.primaryTitle(agent)
        title = primaryTitle
        context = agent.contextDisplay
        var parts = [Self.hostAndTerminal(agent)]
        let hasCollision = agents.contains {
            $0.id != agent.id && Self.primaryTitle($0) == primaryTitle && $0.contextDisplay == agent.contextDisplay
                && Self.hostAndTerminal($0) == Self.hostAndTerminal(agent)
        }
        if hasCollision {
            // Thread-store IDs are stable negative identifiers, not processes to terminate.
            parts.append(agent.canTerminate ? "PID \(agent.processID)" : "Thread \(String(UInt32(bitPattern: agent.id), radix: 16))")
        }
        detail = parts.joined(separator: " · ")
    }

    private static func primaryTitle(_ agent: ActiveAgent) -> String {
        var unmarked = agent
        unmarked.disambiguator = nil
        return unmarked.title
    }

    private static func hostAndTerminal(_ agent: ActiveAgent) -> String {
        let host = agent.hostApp?.displayName ?? (agent.hasTerminalTarget ? "Terminal" : "Editor or background")
        if let tty = agent.terminalTTY {
            let terminal = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
            return "\(host) · \(terminal)"
        }
        return agent.origin == .threadStore ? "\(host) · In-app thread" : host
    }
}
