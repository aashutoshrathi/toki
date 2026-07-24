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

    func testAutoModeSuppressesPermissionPrompt() {
        // In auto mode Bash runs without asking, so a lingering tool_use is executing.
        let jsonl = """
        {"type":"permission-mode","permissionMode":"auto"}
        {"message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}
        """
        XCTAssertNil(attention(jsonl, modified: quiet))
    }

    func testAutoModeStillSurfacesAskedQuestions() {
        // A question waits on the user regardless of permission mode.
        let jsonl = """
        {"type":"permission-mode","permissionMode":"auto"}
        {"message":{"content":[{"type":"tool_use","id":"t1","name":"AskUserQuestion","input":{"questions":[{"question":"Which one?"}]}}]}}
        """
        XCTAssertEqual(attention(jsonl, modified: quiet)?.kind, .question)
    }

    func testAcceptEditsSuppressesEditsButNotBash() {
        let edit = """
        {"type":"permission-mode","permissionMode":"acceptEdits"}
        {"message":{"content":[{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
        """
        XCTAssertNil(attention(edit, modified: quiet))

        let bash = """
        {"type":"permission-mode","permissionMode":"acceptEdits"}
        {"message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}
        """
        XCTAssertEqual(attention(bash, modified: quiet)?.kind, .permission)
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

final class AgentDisambiguationTests: XCTestCase {
    private func agent(pid: Int32, title: String, tty: String?) -> ActiveAgent {
        ActiveAgent(
            id: pid, provider: .claudeCode, directory: nil, chatTitle: title,
            hostApp: nil, hostProcessID: nil, lastActivity: nil, processID: pid, runtime: "1:00",
            terminalTTY: tty, memoryKB: 1000, command: "claude", sessionUsage: nil, attention: nil
        )
    }

    func testSharedTitlesGetTtyMarkers() {
        let result = ActiveAgentScanner.disambiguate([
            agent(pid: 1, title: "Audit database", tty: "/dev/ttys004"),
            agent(pid: 2, title: "Audit database", tty: "ttys007"),
            agent(pid: 3, title: "Unique task", tty: "/dev/ttys009"),
        ])
        XCTAssertEqual(result[0].title, "Audit database · ttys004")
        XCTAssertEqual(result[1].title, "Audit database · ttys007")
        // A title nobody else shares is left alone.
        XCTAssertEqual(result[2].title, "Unique task")
    }

    func testUniqueTitlesAreUnchanged() {
        let result = ActiveAgentScanner.disambiguate([
            agent(pid: 1, title: "A", tty: "/dev/ttys004"),
            agent(pid: 2, title: "B", tty: "/dev/ttys007"),
        ])
        XCTAssertEqual(result.map(\.title), ["A", "B"])
    }

    func testStartDateParsesETimeFormats() {
        let now = Date()
        // mm:ss
        XCTAssertEqual(ActiveAgentScanner.startDate(fromETime: "05:00")!.timeIntervalSince(now), -300, accuracy: 2)
        // hh:mm:ss
        XCTAssertEqual(ActiveAgentScanner.startDate(fromETime: "01:00:00")!.timeIntervalSince(now), -3600, accuracy: 2)
        // dd-hh:mm:ss
        XCTAssertEqual(ActiveAgentScanner.startDate(fromETime: "1-00:00:00")!.timeIntervalSince(now), -86400, accuracy: 2)
    }
}

// Guards the click regression: promoting blocked agents to the top re-ordered the list while
// the user was looking at it, and a row moving out from under the pointer mid-press cancels
// the click - so the cards silently stopped being clickable.
final class AgentOrderingTests: XCTestCase {
    private func agent(pid: Int32, activity: Date, attention: AgentAttention?) -> ActiveAgent {
        ActiveAgent(
            id: pid, provider: .claudeCode, directory: nil, chatTitle: "Agent \(pid)",
            hostApp: nil, hostProcessID: nil, lastActivity: activity, processID: pid, runtime: "1:00",
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
