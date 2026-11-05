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

    func testTwoClaudeAccountsWithNoActiveOneFallsBackToProviderScoped() {
        let a = claude(id: "claude-1", switchTarget: "1")
        let b = claude(id: "claude-2", switchTarget: "2")
        let onA = AccountCard.attributedAgents([agent(pid: 1, provider: .claudeCode)], for: a, among: [a, b])
        let onB = AccountCard.attributedAgents([agent(pid: 1, provider: .claudeCode)], for: b, among: [a, b])
        XCTAssertEqual(onA.map(\.id), [1])
        XCTAssertEqual(onB.map(\.id), [1])
    }

    func testTwoClaudeAccountsWithTwoActiveFallsBackToProviderScoped() {
        let a = claude(id: "claude-1", switchTarget: nil)
        let b = claude(id: "claude-2", switchTarget: nil)
        let onA = AccountCard.attributedAgents([agent(pid: 1, provider: .claudeCode)], for: a, among: [a, b])
        let onB = AccountCard.attributedAgents([agent(pid: 1, provider: .claudeCode)], for: b, among: [a, b])
        XCTAssertEqual(onA.map(\.id), [1])
        XCTAssertEqual(onB.map(\.id), [1])
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

final class CodexSessionAttributionTests: XCTestCase {
    private func agent(pid: Int32, codexHome: String?) -> ActiveAgent {
        ActiveAgent(
            id: pid, provider: .codex, directory: nil, chatTitle: nil,
            hostApp: nil, hostProcessID: nil, lastActivity: nil, processID: pid, runtime: "1:00",
            terminalTTY: nil, memoryKB: 1000, command: "codex", sessionUsage: nil, attention: nil,
            codexHome: codexHome
        )
    }

    private func codex(id: String, home: String) -> AccountSnapshot {
        AccountSnapshot(
            id: id, name: id, provider: .codex, codexHome: home, primary: "50%", subtitle: "",
            remainingRatio: 0.5, metrics: []
        )
    }

    func testSingleCodexAccountStaysProviderScoped() {
        let account = codex(id: "codex", home: "/Users/x/.codex")
        let agents = AccountCard.attributedAgents(
            [agent(pid: 7, codexHome: "/Users/x/.codex-secret-workspace")],
            for: account, among: [account]
        )
        XCTAssertEqual(agents.map(\.id), [7])
    }

    func testSessionLandsOnTheAccountWhoseHomeMatches() {
        let work = codex(id: "codex", home: "/Users/x/.codex")
        let secret = codex(id: "codex-secret", home: "/Users/x/.codex-secret-workspace")
        let session = agent(pid: 7, codexHome: "/Users/x/.codex-secret-workspace")
        XCTAssertEqual(AccountCard.attributedAgents([session], for: secret, among: [work, secret]).map(\.id), [7])
        XCTAssertTrue(AccountCard.attributedAgents([session], for: work, among: [work, secret]).isEmpty)
    }

    func testAnUnattributedSessionStaysProviderScoped() {
        let work = codex(id: "codex", home: "/Users/x/.codex")
        let secret = codex(id: "codex-secret", home: "/Users/x/.codex-secret-workspace")
        let session = agent(pid: 7, codexHome: nil)
        XCTAssertEqual(AccountCard.attributedAgents([session], for: work, among: [work, secret]).map(\.id), [7])
        XCTAssertEqual(AccountCard.attributedAgents([session], for: secret, among: [work, secret]).map(\.id), [7])
    }
}

final class AccountGroupingTests: XCTestCase {
    private func snapshot(id: String, provider: Provider) -> AccountSnapshot {
        AccountSnapshot(id: id, name: id, provider: provider, primary: "50%", subtitle: "",
                        remainingRatio: 0.5, metrics: [])
    }

    func testGroupsAccountsOfTheSameProvider() {
        let groups = accountGroups(for: [
            snapshot(id: "codex", provider: .codex),
            snapshot(id: "claude-1", provider: .claudeCode),
            snapshot(id: "codex-secret", provider: .codex),
            snapshot(id: "claude-2", provider: .claudeCode)
        ])
        XCTAssertEqual(groups.map(\.provider), [.codex, .claudeCode])
        XCTAssertEqual(groups[0].snapshots.map(\.id), ["codex", "codex-secret"])
        XCTAssertEqual(groups[1].snapshots.map(\.id), ["claude-1", "claude-2"])
    }

    func testSingleAccountProviderStaysItsOwnGroup() {
        let groups = accountGroups(for: [
            snapshot(id: "codex", provider: .codex),
            snapshot(id: "pi", provider: .pi)
        ])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map(\.snapshots.count), [1, 1])
    }
}
