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
        T3CodeThreadStore.threadURL(forSessionPath: sessionPath, userData: userData)?.absoluteString
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

    func testT3CodeIsTheHostOfItsAgents() {
        XCTAssertEqual(HostApp.match(comm: "/applications/t3 code (beta).app/contents/macos/t3 code (beta)"), .t3Code)
        XCTAssertEqual(HostApp.match(comm: "/applications/t3 code.app/contents/macos/t3 code"), .t3Code)
    }
}
