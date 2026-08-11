import XCTest
@testable import Toki

// Which transcript a running Claude agent is showing. The conversation can move to a new file
// mid-run (/clear, switching chats, a rolled-over transcript), and several agents can share one
// project folder, so these two have to hold at once: follow the live file, and never hand two
// agents the same one.
final class ClaudeSessionAssignmentTests: XCTestCase {
    private var root: String!
    private let cwd = "/Users/x/project"
    private let now = Date()

    override func setUpWithError() throws {
        root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("claude-projects-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: projectDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private var projectDirectory: String {
        "\(root!)/-Users-x-project"
    }

    @discardableResult
    private func writeSession(_ name: String, createdMinutesAgo: Double, modifiedMinutesAgo: Double) throws -> String {
        let path = "\(projectDirectory)/\(name)"
        try "{}".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([
            .creationDate: now.addingTimeInterval(-createdMinutesAgo * 60),
            .modificationDate: now.addingTimeInterval(-modifiedMinutesAgo * 60)
        ], ofItemAtPath: path)
        return path
    }

    private func agent(_ pid: Int32, startedMinutesAgo: Double, command: String = "claude") -> AgentSessionResolver.ClaudeAgentIdentity {
        AgentSessionResolver.ClaudeAgentIdentity(
            id: pid,
            command: command,
            cwd: cwd,
            startTime: now.addingTimeInterval(-startedMinutesAgo * 60)
        )
    }

    private func assign(_ agents: [AgentSessionResolver.ClaudeAgentIdentity]) -> [Int32: String] {
        AgentSessionResolver.assignClaudeSessions(agents, projectsRoot: root)
            .mapValues { ($0.path as NSString).lastPathComponent }
    }

    // The bug this suite exists for: a session started after launch is the live one, and pinning
    // to the file created nearest launch left the phone showing a dead transcript and a name that
    // never changed.
    func testAgentFollowsATranscriptStartedAfterItLaunched() throws {
        try writeSession("first.jsonl", createdMinutesAgo: 90, modifiedMinutesAgo: 40)
        try writeSession("cleared.jsonl", createdMinutesAgo: 20, modifiedMinutesAgo: 1)

        XCTAssertEqual(assign([agent(1, startedMinutesAgo: 90)])[1], "cleared.jsonl")
    }

    func testSingleAgentUsesTheNewestTranscriptWhenLaunchTimeIsUnknown() throws {
        try writeSession("older.jsonl", createdMinutesAgo: 90, modifiedMinutesAgo: 40)
        try writeSession("newer.jsonl", createdMinutesAgo: 20, modifiedMinutesAgo: 1)

        let unknownStart = AgentSessionResolver.ClaudeAgentIdentity(id: 1, command: "claude", cwd: cwd, startTime: nil)
        XCTAssertEqual(assign([unknownStart])[1], "newer.jsonl")
    }

    // Two agents in one folder: the later one's transcript must not be handed to the earlier one
    // just because it is the most recently written file in the folder.
    func testCoLocatedAgentsKeepTheirOwnTranscripts() throws {
        try writeSession("early.jsonl", createdMinutesAgo: 60, modifiedMinutesAgo: 30)
        try writeSession("late.jsonl", createdMinutesAgo: 10, modifiedMinutesAgo: 1)

        let assigned = assign([agent(1, startedMinutesAgo: 60), agent(2, startedMinutesAgo: 10)])
        XCTAssertEqual(assigned[1], "early.jsonl")
        XCTAssertEqual(assigned[2], "late.jsonl")
    }

    func testEachCoLocatedAgentStillFollowsItsOwnNewSession() throws {
        try writeSession("early.jsonl", createdMinutesAgo: 60, modifiedMinutesAgo: 50)
        try writeSession("early-cleared.jsonl", createdMinutesAgo: 40, modifiedMinutesAgo: 2)
        try writeSession("late.jsonl", createdMinutesAgo: 10, modifiedMinutesAgo: 1)

        let assigned = assign([agent(1, startedMinutesAgo: 60), agent(2, startedMinutesAgo: 10)])
        XCTAssertEqual(assigned[1], "early-cleared.jsonl")
        XCTAssertEqual(assigned[2], "late.jsonl")
    }

    func testTwoAgentsNeverShareOneTranscript() throws {
        try writeSession("only.jsonl", createdMinutesAgo: 60, modifiedMinutesAgo: 1)

        let assigned = assign([agent(1, startedMinutesAgo: 60), agent(2, startedMinutesAgo: 50)])
        XCTAssertEqual(assigned[1], "only.jsonl")
        XCTAssertNil(assigned[2])
    }

    // A resumed conversation's file predates the process that reopened it, so ownership by launch
    // time cannot find it - and a freshly created sibling must not be substituted for it.
    func testResumedSessionKeepsItsPreExistingTranscript() throws {
        try writeSession("resumed.jsonl", createdMinutesAgo: 2000, modifiedMinutesAgo: 3)
        try writeSession("other.jsonl", createdMinutesAgo: 5, modifiedMinutesAgo: 1)

        let assigned = assign([agent(1, startedMinutesAgo: 30), agent(2, startedMinutesAgo: 5)])
        XCTAssertEqual(assigned[1], "resumed.jsonl")
        XCTAssertEqual(assigned[2], "other.jsonl")
    }

    func testSessionNamedOnTheCommandLineWins() throws {
        let sessionID = "aaaaaaaa-1111-2222-3333-444444444444"
        try writeSession("\(sessionID).jsonl", createdMinutesAgo: 2000, modifiedMinutesAgo: 90)
        try writeSession("newer.jsonl", createdMinutesAgo: 5, modifiedMinutesAgo: 1)

        let resumed = agent(1, startedMinutesAgo: 5, command: "claude --resume \(sessionID)")
        XCTAssertEqual(assign([resumed])[1], "\(sessionID).jsonl")
    }

    func testTranscriptPathOnTheCommandLineWins() throws {
        let path = try writeSession("explicit.jsonl", createdMinutesAgo: 2000, modifiedMinutesAgo: 90)
        try writeSession("newer.jsonl", createdMinutesAgo: 5, modifiedMinutesAgo: 1)

        let resumed = agent(1, startedMinutesAgo: 5, command: "claude --resume \(path)")
        XCTAssertEqual(assign([resumed])[1], "explicit.jsonl")
    }

    func testNoTranscriptsYieldsNoAssignment() {
        XCTAssertTrue(assign([agent(1, startedMinutesAgo: 5)]).isEmpty)
    }
}
