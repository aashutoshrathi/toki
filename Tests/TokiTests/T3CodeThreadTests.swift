import XCTest
@testable import Toki

final class T3CodeThreadTests: XCTestCase {
    private let sessionID = "2ce2fc3d-248b-4011-a6fa-af48f65b2885"
    private var userData = ""

    override func setUpWithError() throws {
        userData = NSTemporaryDirectory() + "t3-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: userData, withIntermediateDirectories: true)
        try "env-1\n".write(toFile: "\(userData)/environment-id", atomically: true, encoding: .utf8)
        addTeardownBlock { [userData] in
            try? FileManager.default.removeItem(atPath: userData)
        }
    }

    private func sqlite(_ statement: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["\(userData)/statev2.sqlite", statement]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func writeThreads() throws {
        try sqlite("""
        CREATE TABLE orchestration_v2_projection_provider_threads (thread_id TEXT, updated_at TEXT, payload_json TEXT);
        INSERT INTO orchestration_v2_projection_provider_threads VALUES
            ('thread-1', '2026-10-21T15:22:35Z', '{"nativeThreadRef":{"nativeId":"\(sessionID)"}}'),
            ('thread-2', '2026-10-21T15:30:00Z', '{"nativeThreadRef":{"nativeId":"9138ab42-981b-4916-ab19-195dc78eb528"}}');
        CREATE TABLE orchestration_v2_projection_threads (thread_id TEXT, title TEXT);
        INSERT INTO orchestration_v2_projection_threads VALUES
            ('thread-1', 'Flag for Multiple Bundles per Country'),
            ('thread-2', 'Investigate' || char(10) || 'Production Sentry Error');
        """)
    }

    private func threadURL(_ sessionPath: String) -> String? {
        T3CodeThreadStore.threads(forSessionPaths: [sessionPath], userData: userData)[sessionPath]?.url?.absoluteString
    }

    private func writeAuthSessions() throws {
        try sqlite("""
        CREATE TABLE auth_sessions (client_surface TEXT, client_os TEXT, expires_at TEXT, revoked_at TEXT);
        INSERT INTO auth_sessions VALUES
            ('mobile', 'Android', '2999-01-01T00:00:00.000Z', NULL),
            ('mobile', 'Android', '2999-01-01T00:00:00.000Z', NULL),
            ('mobile', 'iOS', '2999-01-01T00:00:00.000Z', '2026-10-01T00:00:00.000Z'),
            ('mobile', 'iPadOS', '2020-01-01T00:00:00.000Z', NULL),
            ('desktop', 'macOS', '2999-01-01T00:00:00.000Z', NULL);
        """)
    }

    private func mobileOSes() -> [String]? {
        let path = "/Users/me/.claude/projects/-app/\(sessionID).jsonl"
        return T3CodeThreadStore.threads(forSessionPaths: [path], userData: userData)[path]?.mobileOSes
    }

    func testClaudeSessionOpensItsOwnT3Thread() throws {
        try writeThreads()
        XCTAssertEqual(threadURL("/Users/me/.claude/projects/-app/\(sessionID).jsonl"), "t3code://threads/env-1/thread-1")
    }

    func testSessionT3NeverStartedHasNoThread() throws {
        try writeThreads()
        XCTAssertNil(threadURL("/Users/me/.claude/projects/-app/aaaaaaaa-1111-2222-3333-444444444444.jsonl"))
    }

    func testOnlyASessionUUIDReachesTheQuery() throws {
        try writeThreads()
        XCTAssertNil(threadURL("/tmp/x' OR '1'='1.jsonl"))
    }

    func testNoDatabaseMeansNoThread() {
        XCTAssertNil(threadURL("/Users/me/.claude/projects/-app/\(sessionID).jsonl"))
    }

    func testTitleIsTheOneT3CodeShows() throws {
        try writeThreads()
        let first = "/Users/me/.claude/projects/-app/\(sessionID).jsonl"
        let second = "/Users/me/.claude/projects/-app/9138ab42-981b-4916-ab19-195dc78eb528.jsonl"
        let unknown = "/Users/me/.claude/projects/-app/aaaaaaaa-1111-2222-3333-444444444444.jsonl"
        let threads = T3CodeThreadStore.threads(forSessionPaths: [first, second, unknown], userData: userData)
        XCTAssertEqual(threads[first]?.title, "Flag for Multiple Bundles per Country")
        XCTAssertEqual(threads[second]?.title, "Investigate Production Sentry Error")
        XCTAssertNil(threads[unknown])
    }

    func testThreadHasNoLinkWithoutAnEnvironmentID() throws {
        try writeThreads()
        try "\n".write(toFile: "\(userData)/environment-id", atomically: true, encoding: .utf8)
        XCTAssertNil(threadURL("/Users/me/.claude/projects/-app/\(sessionID).jsonl"))
        XCTAssertEqual(mobileOSes(), [])
    }

    func testOnlyAnActiveMobileSignInCountsAsAPhone() throws {
        try writeThreads()
        try writeAuthSessions()
        XCTAssertEqual(mobileOSes(), ["Android"])
    }

    func testNoPhonesWithoutAnAuthSessionsTable() throws {
        try writeThreads()
        XCTAssertEqual(mobileOSes(), [])
    }

    private func writeOpenThreads() throws {
        try sqlite("""
        CREATE TABLE orchestration_v2_projection_threads (thread_id TEXT, title TEXT, updated_at TEXT, archived_at TEXT, deleted_at TEXT);
        INSERT INTO orchestration_v2_projection_threads VALUES
            ('idle', 'Explain' || char(10) || 'Quota Pauses', '2026-10-28T07:26:53.942Z', NULL, NULL),
            ('closed', 'Old chat', '2026-10-28T07:30:00.000Z', NULL, NULL),
            ('archived', 'Archived chat', '2026-10-28T07:31:00.000Z', '2026-10-28T07:32:00.000Z', NULL);
        CREATE TABLE orchestration_v2_projection_provider_sessions (thread_id TEXT, provider TEXT, driver TEXT, status TEXT, payload_json TEXT);
        INSERT INTO orchestration_v2_projection_provider_sessions VALUES
            ('idle', 'claudeAgent', 'claudeAgent', 'ready', '{"cwd":"/Users/me/app"}'),
            ('closed', 'codex', 'codex', 'stopped', '{"cwd":"/Users/me/app"}'),
            ('archived', 'codex', 'codex', 'ready', '{"cwd":"/Users/me/app"}');
        CREATE TABLE orchestration_v2_projection_provider_threads (thread_id TEXT, updated_at TEXT, payload_json TEXT);
        INSERT INTO orchestration_v2_projection_provider_threads VALUES
            ('idle', '2026-10-28T06:00:00Z', '{"nativeThreadRef":{"nativeId":"old-native"}}'),
            ('idle', '2026-10-28T07:00:00Z', '{"nativeThreadRef":{"nativeId":"\(sessionID)"}}');
        """)
    }

    func testOpenThreadsAreTheReadyOnesT3StillShows() throws {
        try writeOpenThreads()
        let threads = T3CodeThreadStore.openThreads(userData: userData)
        XCTAssertEqual(threads.map(\.thread.id), ["idle"])
        XCTAssertEqual(threads.first?.thread.title, "Explain Quota Pauses")
        XCTAssertEqual(threads.first?.thread.url?.absoluteString, "t3code://threads/env-1/idle")
        XCTAssertEqual(threads.first?.driver, "claudeAgent")
        XCTAssertEqual(threads.first?.directory, "/Users/me/app")
        XCTAssertEqual(threads.first?.nativeID, sessionID)
        XCTAssertEqual(threads.first?.updated, Date(timeIntervalSince1970: 1_793_172_413.942))
    }

    func testNoDatabaseMeansNoOpenThreads() {
        XCTAssertTrue(T3CodeThreadStore.openThreads(userData: userData).isEmpty)
    }

    private let psOutput = """
      501     1 ??       01-00:20:11 300000 /Applications/T3 Code (Beta).app/Contents/MacOS/T3 Code (Beta)
      502   501 ??       01-00:20:10 200000 /Applications/T3 Code (Beta).app/Contents/MacOS/T3 Code (Beta)
    """

    private func openThread(id: String = "thread-1", driver: String = "codex") -> T3CodeThreadStore.OpenThread {
        T3CodeThreadStore.OpenThread(
            thread: T3CodeThreadStore.Thread(id: id, title: "Quota pauses", url: nil, mobileOSes: []),
            driver: driver,
            directory: "/tmp/project",
            nativeID: nil,
            updated: Date()
        )
    }

    func testIdleT3ChatIsARowWithNoProcessBehindIt() {
        let agents = ActiveAgentScanner.withT3Threads([], psOutput: psOutput, threads: [openThread()])
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents[0].provider, .codex)
        XCTAssertEqual(agents[0].chatTitle, "Quota pauses")
        XCTAssertEqual(agents[0].hostApp, HostApp.t3Code)
        XCTAssertEqual(agents[0].hostProcessID, 501)
        XCTAssertEqual(agents[0].t3Thread?.id, "thread-1")
        XCTAssertEqual(agents[0].origin, .threadStore)
        XCTAssertFalse(agents[0].canTerminate)
        XCTAssertLessThan(agents[0].processID, 0)
    }

    func testT3ChatWithARunningProcessIsLeftToThatProcess() {
        var running = ActiveAgent(
            id: 900, provider: .claudeCode, directory: "/tmp/project", chatTitle: "Quota pauses",
            hostApp: HostApp.t3Code, hostProcessID: 502, lastActivity: Date(), processID: 900, runtime: "00:31",
            terminalTTY: nil, memoryKB: 41_000, command: "claude", sessionUsage: nil, attention: nil
        )
        running.t3Thread = openThread().thread
        let agents = ActiveAgentScanner.withT3Threads([running], psOutput: psOutput, threads: [openThread()])
        XCTAssertEqual(agents.map(\.processID), [900])
    }

    func testLiveT3CodexProcessTakesTheNewestOpenChatInItsFolder() {
        let running = ActiveAgent(
            id: 901, provider: .codex, directory: "/tmp/project", chatTitle: "project",
            hostApp: HostApp.t3Code, hostProcessID: 502, lastActivity: Date(), processID: 901, runtime: "00:12",
            terminalTTY: nil, memoryKB: 30_000, command: "codex app-server", sessionUsage: nil, attention: nil
        )
        let agents = ActiveAgentScanner.withT3Threads(
            [running], psOutput: psOutput, threads: [openThread(id: "newest"), openThread(id: "older")]
        )
        XCTAssertEqual(agents.map(\.processID).first, 901)
        XCTAssertEqual(agents.first?.t3Thread?.id, "newest")
        XCTAssertEqual(agents.dropFirst().map(\.t3Thread?.id), ["older"])
    }

    func testT3ChatsAreHiddenWhenUnknownOrT3IsClosed() {
        XCTAssertTrue(ActiveAgentScanner.withT3Threads([], psOutput: psOutput, threads: [openThread(driver: "mystery")]).isEmpty)
        XCTAssertTrue(ActiveAgentScanner.withT3Threads([], psOutput: "", threads: [openThread()]).isEmpty)
    }

    func testT3CodeIsTheHostOfItsAgents() {
        XCTAssertEqual(HostApp.match(comm: "/applications/t3 code (beta).app/contents/macos/t3 code (beta)"), .t3Code)
        XCTAssertEqual(HostApp.match(comm: "/applications/t3 code.app/contents/macos/t3 code"), .t3Code)
    }
}
