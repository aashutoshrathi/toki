import XCTest
@testable import Toki

final class SarvamCodeUsageClientTests: XCTestCase {
    func testCumulativeCountersAreDeltaCountedAndDuplicateEventsAreIgnored() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSession(
            root: root,
            name: "usage",
            events: [
                event(at: "2026-08-23T10:00:00Z", input: 100, cached: 40, output: 20, reasoning: 5, total: 120, cost: #""cost":0.10"#),
                event(at: "2026-08-23T10:01:00Z", input: 100, cached: 40, output: 20, reasoning: 5, total: 120, cost: #""cost":0.10"#),
                event(at: "2026-08-24T10:00:00Z", input: 150, cached: 60, output: 30, reasoning: 8, total: 180, cost: #""cost":0.25"#)
            ]
        )

        let totals = try SarvamCodeUsageClient.aggregate(
            root: root.path,
            now: iso("2026-08-24T12:00:00Z"),
            calendar: utcCalendar
        )

        XCTAssertEqual(totals.sessionCount, 1)
        XCTAssertEqual(totals.allTimeTokens, 180)
        XCTAssertEqual(totals.todayTokens, 60)
        XCTAssertEqual(totals.todayInput, 50)
        XCTAssertEqual(totals.todayCachedInput, 20)
        XCTAssertEqual(totals.todayOutput, 10)
        XCTAssertEqual(totals.todayReasoningOutput, 3)
        XCTAssertEqual(totals.allTimeCosts.amount(for: "USD"), 0.25, accuracy: 0.000_001)
        XCTAssertEqual(totals.todayCosts.amount(for: "USD"), 0.15, accuracy: 0.000_001)
    }

    func testExplicitCurrencyOverridesUSDDefault() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSession(
            root: root,
            name: "currency",
            events: [
                event(at: "2026-08-24T10:00:00Z", input: 10, cached: 0, output: 2, reasoning: 0, total: 12,
                      cost: #""cost":{"amount":2.5,"currency":"inr"}"#),
                event(at: "2026-08-24T10:01:00Z", input: 20, cached: 0, output: 4, reasoning: 0, total: 24,
                      cost: #""cost":{"amount":4.0,"currency":"inr"}"#)
            ]
        )

        let totals = try SarvamCodeUsageClient.aggregate(
            root: root.path,
            now: iso("2026-08-24T12:00:00Z"),
            calendar: utcCalendar
        )
        XCTAssertEqual(totals.allTimeCosts.amount(for: "INR"), 4, accuracy: 0.000_001)
        XCTAssertEqual(totals.allTimeCosts.amount(for: "USD"), 0)
    }

    func testCounterResetStartsANewSegment() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSession(
            root: root,
            name: "reset",
            events: [
                event(at: "2026-08-24T10:00:00Z", input: 90, cached: 10, output: 10, reasoning: 0, total: 100, cost: #""cost_usd":1.0"#),
                event(at: "2026-08-24T10:01:00Z", input: 20, cached: 5, output: 5, reasoning: 1, total: 25, cost: #""cost_usd":0.2"#)
            ]
        )

        let totals = try SarvamCodeUsageClient.aggregate(
            root: root.path,
            now: iso("2026-08-24T12:00:00Z"),
            calendar: utcCalendar
        )
        XCTAssertEqual(totals.allTimeTokens, 125)
        XCTAssertEqual(totals.allTimeCosts.amount(for: "USD"), 1.2, accuracy: 0.000_001)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("toki-sarvam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeSession(root: URL, name: String, events: [String]) throws {
        let directory = root.appendingPathComponent("2026/08/24")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let header = #"{"type":"session_meta","payload":{"id":"session-id","cwd":"/tmp/project"}}"#
        try ([header] + events).joined(separator: "\n").write(
            to: directory.appendingPathComponent("\(name).jsonl"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func event(
        at timestamp: String,
        input: Int,
        cached: Int,
        output: Int,
        reasoning: Int,
        total: Int,
        cost: String
    ) -> String {
        """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"output_tokens":\(output),"reasoning_output_tokens":\(reasoning),"total_tokens":\(total),\(cost)}}}}
        """
    }

    private func iso(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
