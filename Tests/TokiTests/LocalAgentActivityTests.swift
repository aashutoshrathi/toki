import XCTest
@testable import Toki

final class LocalAgentActivityTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "toki-activity-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func touch(_ relative: String, at date: Date) throws {
        let path = "\(root!)/\(relative)"
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data("{}\n".utf8))
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    func testClaudeActivityIsTheNewestTranscriptAcrossProjects() throws {
        let newest = Date(timeIntervalSince1970: 1_790_000_000)
        try touch(".claude/projects/-a/old.jsonl", at: newest.addingTimeInterval(-86_400))
        try touch(".claude/projects/-b/new.jsonl", at: newest)
        try touch(".claude/projects/-b/notes.txt", at: newest.addingTimeInterval(60))

        XCTAssertEqual(LocalAgentActivity.claudeCode(home: root), newest)
    }

    func testClaudeActivityIsNilWithoutTranscripts() {
        XCTAssertNil(LocalAgentActivity.claudeCode(home: root))
    }

    func testCodexActivityReadsTheNewestRolloutDay() throws {
        let newest = Date(timeIntervalSince1970: 1_790_000_000)
        try touch("sessions/2026/08/31/rollout-a.jsonl", at: newest.addingTimeInterval(-86_400))
        try touch("sessions/2026/09/02/rollout-b.jsonl", at: newest)

        XCTAssertEqual(LocalAgentActivity.codex(codexHome: "\(root!)"), newest)
    }

    func testCodexActivityReadsTheThreadsDatabase() throws {
        let database = "\(root!)/state_5.sqlite"
        _ = Shell.output("/usr/bin/sqlite3", [database, "CREATE TABLE threads (id TEXT, updated_at INTEGER); INSERT INTO threads VALUES ('a', 1790000000), ('b', 1780000000);"])

        XCTAssertEqual(LocalAgentActivity.codex(codexHome: "\(root!)"), Date(timeIntervalSince1970: 1_790_000_000))
    }

    func testOpenCodeServerIsNotAnAgent() {
        XCTAssertNil(ActiveAgentScanner.providerForCommand("/Users/me/.opencode/bin/opencode serve --service"))
        XCTAssertNil(ActiveAgentScanner.providerForCommand("opencode web"))
        XCTAssertEqual(ActiveAgentScanner.providerForCommand("/Users/me/.opencode/bin/opencode"), .openCode)
        XCTAssertEqual(ActiveAgentScanner.providerForCommand("opencode run fix it"), .openCode)
    }
}

final class APIFailureLogTests: XCTestCase {
    func testEndpointDescriptionDropsIdentifiersAndQueries() {
        let url = URL(string: "https://api.anthropic.com/api/organizations/0f2c9a1e-7b3d-4e5f-9a8b-1c2d3e4f5a6b/reset_rate_limits?token=abc")
        XCTAssertEqual(apiEndpointDescription(url), "api.anthropic.com/api/organizations/:id/reset_rate_limits")
        XCTAssertEqual(apiEndpointDescription(URL(string: "https://cursor.com/api/dashboard/get-usage")), "cursor.com/api/dashboard/get-usage")
        XCTAssertEqual(apiEndpointDescription(nil), "<unknown-endpoint>")
    }
}
