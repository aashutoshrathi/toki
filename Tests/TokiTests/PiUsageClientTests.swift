import Foundation
import XCTest
@testable import Toki

final class PiUsageClientTests: XCTestCase {
    func testFixtureAggregationDeduplicatesCopiesAndToleratesMalformedLines() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-07-18T18:00:00Z")!

        let totals = try PiUsageClient.aggregate(root: fixtureRoot, now: now, calendar: calendar)

        XCTAssertEqual(totals.todayInput, 108)
        XCTAssertEqual(totals.todayOutput, 25)
        XCTAssertEqual(totals.todayCacheRead, 5)
        XCTAssertEqual(totals.todayCacheWrite, 2)
        XCTAssertEqual(totals.todayCost, 0.21, accuracy: 0.000_001)
        XCTAssertEqual(totals.allTimeCost, 0.22, accuracy: 0.000_001)
        XCTAssertEqual(totals.sessionCount, 2)
    }

    func testAssistantTimestampTakesPrecedenceOverOuterTimestamp() throws {
        let root = try temporaryDirectory()
        let file = (root as NSString).appendingPathComponent("timestamp.jsonl")
        let jsonl = """
        {"type":"session","id":"timestamp-session","cwd":"/tmp/timestamp","timestamp":"2026-07-17T00:00:00Z"}
        {"type":"message","id":"ts","timestamp":"2026-07-18T12:00:00Z","message":{"role":"assistant","timestamp":1784289600000,"provider":"p","api":"a","model":"m","usage":{"input":5,"output":2,"cost":{"total":0.5}}}}
        """
        try jsonl.write(toFile: file, atomically: true, encoding: .utf8)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-07-18T18:00:00Z")!

        let totals = try PiUsageClient.aggregate(root: root, now: now, calendar: calendar)

        XCTAssertEqual(totals.todayInput, 0)
        XCTAssertEqual(totals.allTimeCost, 0.5)
    }

    func testFractionalOuterTimestampIsAcceptedWhenMessageTimestampIsAbsent() throws {
        let root = try temporaryDirectory()
        let file = (root as NSString).appendingPathComponent("fractional.jsonl")
        let jsonl = """
        {"type":"session","id":"fractional-session","cwd":"/tmp/fractional","timestamp":"2026-07-18T00:00:00Z"}
        {"type":"message","id":"fractional","timestamp":"2026-07-18T13:00:00.123Z","message":{"role":"assistant","provider":"p","api":"a","model":"m","usage":{"input":5,"output":2,"cost":{"total":0.5}}}}
        """
        try jsonl.write(toFile: file, atomically: true, encoding: .utf8)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-07-18T18:00:00Z")!

        let totals = try PiUsageClient.aggregate(root: root, now: now, calendar: calendar)

        XCTAssertEqual(totals.todayInput, 5)
        XCTAssertEqual(totals.todayCost, 0.5)
    }

    func testZeroMessageTimestampFallsBackToOuterTimestamp() throws {
        let root = try temporaryDirectory()
        let file = (root as NSString).appendingPathComponent("zero-timestamp.jsonl")
        let jsonl = """
        {"type":"session","id":"zero-session","cwd":"/tmp/zero","timestamp":"2026-07-18T00:00:00Z"}
        {"type":"message","id":"zero","timestamp":"2026-07-18T13:00:00Z","message":{"role":"assistant","timestamp":0,"provider":"p","api":"a","model":"m","usage":{"input":5,"output":2,"cost":{"total":0.5}}}}
        """
        try jsonl.write(toFile: file, atomically: true, encoding: .utf8)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-07-18T18:00:00Z")!

        let totals = try PiUsageClient.aggregate(root: root, now: now, calendar: calendar)

        XCTAssertEqual(totals.todayInput, 5)
        XCTAssertEqual(totals.todayCost, 0.5)
    }

    func testNegativeUsageAndCostAreIgnored() throws {
        let root = try temporaryDirectory()
        let file = (root as NSString).appendingPathComponent("negative.jsonl")
        let jsonl = """
        {"type":"session","id":"negative-session","cwd":"/tmp/negative","timestamp":"2026-07-18T00:00:00Z"}
        {"type":"message","id":"negative","timestamp":"2026-07-18T13:00:00Z","message":{"role":"assistant","provider":"p","api":"a","model":"m","usage":{"input":-5,"output":-2,"cacheRead":-1,"cacheWrite":-3,"cost":{"total":-0.5}}}}
        """
        try jsonl.write(toFile: file, atomically: true, encoding: .utf8)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-07-18T18:00:00Z")!

        let totals = try PiUsageClient.aggregate(root: root, now: now, calendar: calendar)

        XCTAssertEqual(totals.todayInput, 0)
        XCTAssertEqual(totals.todayOutput, 0)
        XCTAssertEqual(totals.todayCacheRead, 0)
        XCTAssertEqual(totals.todayCacheWrite, 0)
        XCTAssertEqual(totals.todayCost, 0)
        XCTAssertEqual(totals.allTimeCost, 0)
    }

    func testMissingAndUnreadableRootErrorsDoNotExposePaths() throws {
        let root = try temporaryDirectory()
        let missing = (root as NSString).appendingPathComponent("private/missing/sessions")
        XCTAssertThrowsError(try PiUsageClient.aggregate(root: missing)) { error in
            XCTAssertEqual(error.localizedDescription, "Pi session history not found")
            XCTAssertFalse(error.localizedDescription.contains(root))
        }

        let notDirectory = (root as NSString).appendingPathComponent("private-history")
        try "not a directory".write(toFile: notDirectory, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try PiUsageClient.aggregate(root: notDirectory)) { error in
            XCTAssertEqual(error.localizedDescription, "Unable to read Pi session history")
            XCTAssertFalse(error.localizedDescription.contains(root))
        }
    }

    func testUnreadableSessionFileErrorDoesNotExposePath() throws {
        let root = try temporaryDirectory()
        let invalidSession = (root as NSString).appendingPathComponent("private-session.jsonl")
        try "{}".write(toFile: invalidSession, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: invalidSession)

        XCTAssertThrowsError(try PiUsageClient.aggregate(root: root)) { error in
            XCTAssertEqual(error.localizedDescription, "Unable to read a Pi session file")
            XCTAssertFalse(error.localizedDescription.contains(root))
        }
    }

    func testSessionRootPrecedenceAndAbsoluteSettingsResolution() throws {
        let home = try temporaryDirectory()
        let agent = (home as NSString).appendingPathComponent("agent")
        let configured = (home as NSString).appendingPathComponent("configured-history")
        try FileManager.default.createDirectory(atPath: agent, withIntermediateDirectories: true)
        try "{\"sessionDir\":\"\(configured)\"}".write(
            toFile: (agent as NSString).appendingPathComponent("settings.json"), atomically: true, encoding: .utf8
        )

        XCTAssertEqual(
            try PiUsageClient.sessionRoot(environment: ["PI_CODING_AGENT_DIR": agent], home: home),
            configured
        )
        XCTAssertEqual(
            try PiUsageClient.sessionRoot(environment: ["PI_CODING_AGENT_DIR": agent, "PI_CODING_AGENT_SESSION_DIR": "~/override"], home: home),
            (home as NSString).appendingPathComponent("override")
        )
        XCTAssertEqual(
            try PiUsageClient.sessionRoot(
                environment: ["PI_CODING_AGENT_DIR": "relative-agent", "PI_CODING_AGENT_SESSION_DIR": configured],
                home: home
            ),
            configured
        )
        XCTAssertEqual(
            try PiUsageClient.sessionRoot(
                environment: ["PI_CODING_AGENT_DIR": "relative-agent", "PI_CODING_AGENT_SESSION_DIR": "~/override"],
                home: home
            ),
            (home as NSString).appendingPathComponent("override")
        )
    }

    func testRelativePiDirectoriesAreRejected() throws {
        let home = try temporaryDirectory()
        XCTAssertThrowsError(try PiUsageClient.sessionRoot(environment: ["PI_CODING_AGENT_DIR": "relative-agent"], home: home))
        XCTAssertThrowsError(try PiUsageClient.sessionRoot(environment: ["PI_CODING_AGENT_SESSION_DIR": "relative-sessions"], home: home))

        let agent = (home as NSString).appendingPathComponent("agent")
        try FileManager.default.createDirectory(atPath: agent, withIntermediateDirectories: true)
        try #"{"sessionDir":"relative/history"}"#.write(
            toFile: (agent as NSString).appendingPathComponent("settings.json"), atomically: true, encoding: .utf8
        )
        XCTAssertThrowsError(try PiUsageClient.sessionRoot(environment: ["PI_CODING_AGENT_DIR": agent], home: home)) { error in
            XCTAssertEqual(error.localizedDescription, "Pi session directory must be absolute, exactly ~, or begin with ~/")
            XCTAssertFalse(error.localizedDescription.contains(home))
        }
    }

    func testUnrelatedJSONLDoesNotCreateAccountOrInflateUsage() throws {
        let root = try temporaryDirectory()
        try #"{"event":"other","message":{"role":"assistant","usage":{"input":999,"cost":{"total":99}}}}"#.write(
            toFile: (root as NSString).appendingPathComponent("other.jsonl"), atomically: true, encoding: .utf8
        )
        XCTAssertNil(PiUsageClient.autoDetectedAccount(environment: ["PI_CODING_AGENT_SESSION_DIR": root], home: root))

        let valid = """
        {"type":"session","id":"valid-session","cwd":"/tmp/valid","timestamp":"2026-07-18T00:00:00Z"}
        {"type":"message","id":"valid","timestamp":"2026-07-18T13:00:00Z","message":{"role":"assistant","provider":"p","api":"a","model":"m","usage":{"input":5,"output":2,"cost":{"total":0.5}}}}
        """
        try valid.write(toFile: (root as NSString).appendingPathComponent("valid.jsonl"), atomically: true, encoding: .utf8)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-07-18T18:00:00Z")!

        let totals = try PiUsageClient.aggregate(root: root, now: now, calendar: calendar)

        XCTAssertEqual(totals.sessionCount, 1)
        XCTAssertEqual(totals.todayInput, 5)
        XCTAssertEqual(totals.allTimeCost, 0.5)
        XCTAssertNotNil(PiUsageClient.autoDetectedAccount(environment: ["PI_CODING_AGENT_SESSION_DIR": root], home: root))
    }

    func testOversizedRecordIsSkippedAndFollowingUsageCounts() throws {
        let root = try temporaryDirectory()
        let file = (root as NSString).appendingPathComponent("oversized.jsonl")
        let oversized = "{\"type\":\"custom\",\"payload\":\"" + String(repeating: "x", count: 1_100_000) + "\"}"
        let jsonl = """
        {"type":"session","id":"oversized-session","cwd":"/tmp/oversized","timestamp":"2026-07-18T00:00:00Z"}
        \(oversized)
        {"type":"message","id":"after-large","timestamp":"2026-07-18T13:00:00Z","message":{"role":"assistant","provider":"p","api":"a","model":"m","usage":{"input":5,"output":2,"cost":{"total":0.5}}}}
        """
        try jsonl.write(toFile: file, atomically: true, encoding: .utf8)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-07-18T18:00:00Z")!

        let totals = try PiUsageClient.aggregate(root: root, now: now, calendar: calendar)

        XCTAssertEqual(totals.sessionCount, 1)
        XCTAssertEqual(totals.todayInput, 5)
    }

    func testDefaultRootAndTildeSettings() throws {
        let home = try temporaryDirectory()
        XCTAssertEqual(
            try PiUsageClient.sessionRoot(environment: [:], home: home),
            (home as NSString).appendingPathComponent(".pi/agent/sessions")
        )

        let agent = (home as NSString).appendingPathComponent(".pi/agent")
        try FileManager.default.createDirectory(atPath: agent, withIntermediateDirectories: true)
        try #"{"sessionDir":"~/pi-history"}"#.write(
            toFile: (agent as NSString).appendingPathComponent("settings.json"), atomically: true, encoding: .utf8
        )
        XCTAssertEqual(
            try PiUsageClient.sessionRoot(environment: [:], home: home),
            (home as NSString).appendingPathComponent("pi-history")
        )
    }

    func testProcessClassificationIsNarrow() {
        let matches: [(String, Provider)] = [
            ("/opt/homebrew/bin/opencode", .openCode),
            ("/usr/local/bin/copilot", .copilot),
            ("node /x/@github/copilot/dist/index.js", .copilot),
            ("/opt/homebrew/bin/codex", .codex),
            ("node /x/@openai/codex/dist/cli.js", .codex),
            ("/usr/local/bin/claude", .claudeCode),
            ("/usr/local/bin/grok", .grok),
            ("/usr/local/bin/gemini", .gemini),
            ("node /x/bin/gemini", .gemini),
            ("/opt/homebrew/bin/pi", .pi),
            ("node /x/@earendil-works/pi-coding-agent/dist/cli.js", .pi),
            ("bun /x/@mariozechner/pi-coding-agent/dist/cli.js", .pi)
        ]
        for (command, expected) in matches {
            XCTAssertEqual(ActiveAgentScanner.providerForCommand(command), expected, command)
        }

        let nonMatches = [
            "node /tmp/pi-helper.js",
            "python pi",
            "node /x/pi-coding-agent/dist/cli.js",
            "bun /x/@earendil-works/not-pi/dist/cli.js",
            "node /tmp/copilot-helper.js",
            "node /tmp/codex-helper.js",
            "node /tmp/gemini-helper.js"
        ]
        for command in nonMatches {
            XCTAssertNil(ActiveAgentScanner.providerForCommand(command), command)
        }
    }

    func testLatestSessionUsesExplicitSessionInfoAndMatchingCWD() throws {
        let root = try temporaryDirectory()
        let destination = (root as NSString).appendingPathComponent("project")
        try FileManager.default.copyItem(atPath: fixtureRoot, toPath: destination)
        let sessionDirectory = (destination as NSString).appendingPathComponent("project")
        let older = (sessionDirectory as NSString).appendingPathComponent("session-a.jsonl")
        let newer = (sessionDirectory as NSString).appendingPathComponent("session-b.jsonl")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: older)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 20)], ofItemAtPath: newer)

        let metadata = PiUsageClient.latestSession(cwd: "/tmp/pi-project", root: root)

        XCTAssertEqual(metadata?.title, "Explicit Pi title")
        XCTAssertEqual((metadata?.path as NSString?)?.lastPathComponent, (newer as NSString).lastPathComponent)
        XCTAssertNil(PiUsageClient.latestSession(cwd: "/tmp/other", root: root))
    }

    func testLatestSessionIndexIsReusedWithinWindowAndRefreshedAfterExpiry() throws {
        let root = try temporaryDirectory()
        let first = (root as NSString).appendingPathComponent("first.jsonl")
        try """
        {"type":"session","id":"first","cwd":"/tmp/cache","timestamp":"2026-07-18T00:00:00Z"}
        {"type":"session_info","id":"first-info","name":"First"}
        """.write(toFile: first, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: first)

        let initial = PiUsageClient.latestSession(cwd: "/tmp/cache", root: root, now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(initial?.title, "First")

        let second = (root as NSString).appendingPathComponent("second.jsonl")
        try """
        {"type":"session","id":"second","cwd":"/tmp/cache","timestamp":"2026-07-18T00:01:00Z"}
        {"type":"session_info","id":"second-info","name":"Second"}
        """.write(toFile: second, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 20)], ofItemAtPath: second)

        XCTAssertEqual(
            PiUsageClient.latestSession(cwd: "/tmp/cache", root: root, now: Date(timeIntervalSince1970: 102))?.title,
            "First"
        )
        XCTAssertEqual(
            PiUsageClient.latestSession(cwd: "/tmp/cache", root: root, now: Date(timeIntervalSince1970: 106))?.title,
            "Second"
        )
    }

    func testProviderCoding() throws {
        XCTAssertEqual(try JSONDecoder().decode(Provider.self, from: Data(#""pi""#.utf8)), .pi)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(Provider.pi), as: UTF8.self), #""pi""#)
        XCTAssertFalse(Provider.pi.isConsumerTracked)
        XCTAssertEqual(Provider.pi.displayName, "Pi")
    }

    private var fixtureRoot: String {
        Bundle.module.url(forResource: "pi", withExtension: nil, subdirectory: "Fixtures")!.path
    }

    private func temporaryDirectory() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }
}
