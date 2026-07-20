import XCTest
@testable import Toki

final class AgentAttentionTests: XCTestCase {
    private let now = Date()
    /// Old enough to clear the quiet period, i.e. the agent has genuinely stopped.
    private var quiet: Date { now.addingTimeInterval(-60) }
    /// Written moments ago - the agent is mid-tool-call, not blocked.
    private var busy: Date { now.addingTimeInterval(-1) }

    private func attention(_ jsonl: String, modified: Date?) -> AgentAttention? {
        AgentSessionResolver.claudeAttention(fromJSONLData: Data(jsonl.utf8), modified: modified, now: now)
    }

    func testUnansweredQuestionSurfacesTheQuestionText() {
        let jsonl = """
        {"message":{"content":[{"type":"tool_use","id":"t1","name":"AskUserQuestion","input":{"questions":[{"question":"Which database?"}]}}]}}
        """
        let result = attention(jsonl, modified: quiet)
        XCTAssertEqual(result?.kind, .question)
        XCTAssertEqual(result?.prompt, "Which database?")
    }

    func testUnansweredToolCallIsAPermissionPrompt() {
        let jsonl = """
        {"message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}
        """
        let result = attention(jsonl, modified: quiet)
        XCTAssertEqual(result?.kind, .permission)
        XCTAssertEqual(result?.prompt, "Allow Bash?")
    }

    func testResolvedToolCallIsNotBlocking() {
        let jsonl = """
        {"message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}
        {"message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]}}
        """
        XCTAssertNil(attention(jsonl, modified: quiet))
    }

    // The core false-positive guard: a tool that is merely executing looks identical on disk
    // to one awaiting permission. Only elapsed quiet time distinguishes them.
    func testRecentlyWrittenSessionIsTreatedAsWorkingNotBlocked() {
        let jsonl = """
        {"message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}
        """
        XCTAssertNil(attention(jsonl, modified: busy))
    }

    func testMissingModificationDateIsNotBlocking() {
        let jsonl = """
        {"message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}
        """
        XCTAssertNil(attention(jsonl, modified: nil))
    }

    func testPlanApprovalIsAQuestion() {
        let jsonl = """
        {"message":{"content":[{"type":"tool_use","id":"t1","name":"ExitPlanMode","input":{}}]}}
        """
        XCTAssertEqual(attention(jsonl, modified: quiet)?.kind, .question)
    }

    func testFullyResolvedSessionIsNotBlocking() {
        let jsonl = """
        {"message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{}}]}}
        {"message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]}}
        {"message":{"content":[{"type":"text","text":"Done."}]}}
        """
        XCTAssertNil(attention(jsonl, modified: quiet))
    }

    func testEmptySessionIsNotBlocking() {
        XCTAssertNil(attention("", modified: quiet))
    }

    func testSummaryFallsBackWhenNoPromptText() {
        XCTAssertEqual(AgentAttention(kind: .question, prompt: nil).summary, "Waiting on your answer")
        XCTAssertEqual(AgentAttention(kind: .permission, prompt: nil).summary, "Waiting for permission")
        XCTAssertEqual(AgentAttention(kind: .question, prompt: "Pick one").summary, "Pick one")
    }
}

// Guards the click regression: promoting blocked agents to the top re-ordered the list while
// the user was looking at it, and a row moving out from under the pointer mid-press cancels
// the click - so the cards silently stopped being clickable.
final class AgentOrderingTests: XCTestCase {
    private func agent(pid: Int32, activity: Date, attention: AgentAttention?) -> ActiveAgent {
        ActiveAgent(
            id: pid, provider: .claudeCode, directory: nil, chatTitle: "Agent \(pid)",
            hostApp: nil, lastActivity: activity, processID: pid, runtime: "1:00",
            terminalTTY: nil, memoryKB: 1000, command: "claude", sessionUsage: nil,
            attention: attention
        )
    }

    func testOrderDoesNotChangeWhenAnAgentStartsWaiting() {
        let older = Date().addingTimeInterval(-600)
        let newer = Date()
        let blocked = AgentAttention(kind: .question, prompt: "Which one?")

        let before = [agent(pid: 1, activity: newer, attention: nil),
                      agent(pid: 2, activity: older, attention: nil)]
        // The older agent becomes blocked; ordering must be unchanged.
        let after = [agent(pid: 1, activity: newer, attention: nil),
                     agent(pid: 2, activity: older, attention: blocked)]

        XCTAssertEqual(sortedIDs(before), sortedIDs(after))
    }

    /// Mirrors the scanner's ordering rule: most recent activity first.
    private func sortedIDs(_ agents: [ActiveAgent]) -> [Int32] {
        agents.sorted { lhs, rhs in
            let l = lhs.lastActivity ?? .distantPast
            let r = rhs.lastActivity ?? .distantPast
            if l != r { return l > r }
            return lhs.processID < rhs.processID
        }.map(\.processID)
    }
}
