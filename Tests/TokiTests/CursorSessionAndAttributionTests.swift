import XCTest
@testable import Toki

final class CursorSessionResolverTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("cursor-chats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func writeSession(workspace: String, id: String, json: String) throws {
        let dir = "\(root!)/\(workspace)/\(id)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try json.write(toFile: "\(dir)/meta.json", atomically: true, encoding: .utf8)
    }

    func testReturnsTitleAndLastActiveForMatchingCwd() throws {
        try writeSession(workspace: "ws1", id: "a", json:
            #"{"title":"Hey There","cwd":"/Users/x/project","updatedAtMs":1785046347202}"#)
        let session = AgentSessionResolver.newestCursorSession(cwd: "/Users/x/project", chatsRoot: root)
        XCTAssertEqual(session?.title, "Hey There")
        XCTAssertEqual(session?.lastActive, Date(timeIntervalSince1970: 1785046347202 / 1000))
    }

    func testPicksNewestSessionForSameCwd() throws {
        try writeSession(workspace: "ws1", id: "old", json:
            #"{"title":"Old chat","cwd":"/Users/x/project","updatedAtMs":1000000000000}"#)
        try writeSession(workspace: "ws2", id: "new", json:
            #"{"title":"New chat","cwd":"/Users/x/project","updatedAtMs":2000000000000}"#)
        let session = AgentSessionResolver.newestCursorSession(cwd: "/Users/x/project", chatsRoot: root)
        XCTAssertEqual(session?.title, "New chat")
    }

    func testIgnoresSessionsWithADifferentCwd() throws {
        try writeSession(workspace: "ws1", id: "a", json:
            #"{"title":"Other project","cwd":"/Users/x/other","updatedAtMs":2000000000000}"#)
        try writeSession(workspace: "ws2", id: "b", json:
            #"{"title":"My project","cwd":"/Users/x/project","updatedAtMs":1000000000000}"#)
        let session = AgentSessionResolver.newestCursorSession(cwd: "/Users/x/project", chatsRoot: root)
        XCTAssertEqual(session?.title, "My project")
    }

    func testEmptyTitleBecomesNilButStillMatches() throws {
        try writeSession(workspace: "ws1", id: "a", json:
            #"{"title":"","cwd":"/Users/x/project","updatedAtMs":1785046347202}"#)
        let session = AgentSessionResolver.newestCursorSession(cwd: "/Users/x/project", chatsRoot: root)
        XCTAssertNil(session?.title)
        XCTAssertNotNil(session?.lastActive)
    }

    func testNoMatchingCwdReturnsNil() throws {
        try writeSession(workspace: "ws1", id: "a", json:
            #"{"title":"Elsewhere","cwd":"/Users/x/elsewhere","updatedAtMs":1785046347202}"#)
        XCTAssertNil(AgentSessionResolver.newestCursorSession(cwd: "/Users/x/project", chatsRoot: root))
    }

    func testNilCwdReturnsNil() {
        XCTAssertNil(AgentSessionResolver.newestCursorSession(cwd: nil, chatsRoot: root))
    }
}

final class ClaudeSessionAttributionTests: XCTestCase {
    private func agent(pid: Int32, provider: Provider) -> ActiveAgent {
        ActiveAgent(
            id: pid, provider: provider, directory: nil, chatTitle: nil,
            hostApp: nil, hostProcessID: nil, lastActivity: nil, processID: pid, runtime: "1:00",
            terminalTTY: nil, memoryKB: 1000, command: "agent", sessionUsage: nil, attention: nil
        )
    }

    private func claude(id: String, switchTarget: String?) -> AccountSnapshot {
        AccountSnapshot(
            id: id, name: id, provider: .claudeCode, primary: "50%", subtitle: "",
            remainingRatio: 0.5, metrics: [], switchTarget: switchTarget
        )
    }

    func testSingleClaudeAccountShowsTheSession() {
        let active = claude(id: "claude-1", switchTarget: nil)
        let agents = AccountCard.attributedAgents(
            [agent(pid: 1, provider: .claudeCode)], for: active, among: [active]
        )
        XCTAssertEqual(agents.map(\.id), [1])
    }

    func testActiveClaudeAccountShowsTheSession() {
        let active = claude(id: "claude-1", switchTarget: nil)
        let inactive = claude(id: "claude-2", switchTarget: "2")
        let agents = AccountCard.attributedAgents(
            [agent(pid: 1, provider: .claudeCode)], for: active, among: [active, inactive]
        )
        XCTAssertEqual(agents.map(\.id), [1])
    }

    func testInactiveClaudeAccountDoesNotShowTheSession() {
        let active = claude(id: "claude-1", switchTarget: nil)
        let inactive = claude(id: "claude-2", switchTarget: "2")
        let agents = AccountCard.attributedAgents(
            [agent(pid: 1, provider: .claudeCode)], for: inactive, among: [active, inactive]
        )
        XCTAssertTrue(agents.isEmpty)
    }

    func testNonClaudeProviderStaysProviderScoped() {
        let codex = AccountSnapshot(
            id: "codex", name: "Codex", provider: .codex, primary: "50%", subtitle: "",
            remainingRatio: 0.5, metrics: []
        )
        let agents = AccountCard.attributedAgents(
            [agent(pid: 7, provider: .codex)], for: codex, among: [codex]
        )
        XCTAssertEqual(agents.map(\.id), [7])
    }

    func testAgentsOfOtherProvidersAreFilteredOut() {
        let active = claude(id: "claude-1", switchTarget: nil)
        let agents = AccountCard.attributedAgents(
            [agent(pid: 1, provider: .claudeCode), agent(pid: 2, provider: .codex)],
            for: active, among: [active]
        )
        XCTAssertEqual(agents.map(\.id), [1])
    }
}
