import Foundation
import XCTest
@testable import Toki

final class FxUsageClientTests: XCTestCase {
    private func ms(_ iso: String) -> Int {
        Int(ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970 * 1000)
    }

    private func generation(
        id: String,
        at iso: String,
        cost: Double,
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0
    ) -> String {
        "{\"schema_version\":1,\"kind\":\"generation\",\"fact\":{\"id\":\"\(id)\",\"created_at_ms\":\(ms(iso)),"
            + "\"model\":\"m\",\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_read_tokens\":\(cacheRead),"
            + "\"cache_write_tokens\":\(cacheWrite),\"reasoning_tokens\":0,\"total_cost\":\(cost)}}"
    }

    func testAggregateBucketsDedupesAndToleratesNoise() throws {
        let root = try temporaryDirectory()
        let file = (root as NSString).appendingPathComponent("usage.jsonl")
        // now = 2026-08-19 (Wed). Sunday-based week is 2026-08-16..08-22; August is the month.
        let jsonl = [
            "{\"schema_version\":1,\"kind\":\"coverage\",\"started_at_ms\":\(ms("2026-08-01T00:00:00Z"))}",
            generation(id: "today", at: "2026-08-19T09:00:00Z", cost: 0.10, input: 100, output: 10, cacheRead: 1_000, cacheWrite: 50),
            generation(id: "today", at: "2026-08-19T10:00:00Z", cost: 0.99, input: 999, output: 99),  // dup id
            generation(id: "week", at: "2026-08-18T09:00:00Z", cost: 0.20, input: 20, output: 2),
            generation(id: "month", at: "2026-08-03T09:00:00Z", cost: 0.30, input: 30, output: 3),
            generation(id: "last-month", at: "2026-07-20T09:00:00Z", cost: 0.40, input: 40, output: 4),
            generation(id: "negative", at: "2026-08-19T11:00:00Z", cost: -5),
            "{ not valid json"
        ].joined(separator: "\n")
        try jsonl.write(toFile: file, atomically: true, encoding: .utf8)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-08-19T18:00:00Z")!

        let totals = try FxUsageClient.aggregate(path: file, now: now, calendar: calendar)

        XCTAssertEqual(totals.todayCost, 0.10, accuracy: 0.000_001)
        XCTAssertEqual(totals.todayInput, 100)
        XCTAssertEqual(totals.todayOutput, 10)
        XCTAssertEqual(totals.weekCost, 0.30, accuracy: 0.000_001)   // today + week
        XCTAssertEqual(totals.monthCost, 0.60, accuracy: 0.000_001)  // today + week + month
        XCTAssertEqual(totals.allTimeCost, 1.00, accuracy: 0.000_001) // negative ignored
        XCTAssertEqual(totals.requestCount, 5)                        // unique generation facts
    }

    func testAggregateBucketsTokensIncludingCacheAndSkipsDuplicates() throws {
        let root = try temporaryDirectory()
        let file = (root as NSString).appendingPathComponent("usage.jsonl")
        let jsonl = [
            generation(id: "today", at: "2026-08-19T09:00:00Z", cost: 0.10, input: 100, output: 10, cacheRead: 1_000, cacheWrite: 50),
            generation(id: "today", at: "2026-08-19T10:00:00Z", cost: 0.99, input: 999, output: 99),  // dup id
            generation(id: "week", at: "2026-08-18T09:00:00Z", cost: 0.20, input: 20, output: 2),
            generation(id: "month", at: "2026-08-03T09:00:00Z", cost: 0.30, input: 30, output: 3),
            generation(id: "last-month", at: "2026-07-20T09:00:00Z", cost: 0.40, input: 40, output: 4)
        ].joined(separator: "\n")
        try jsonl.write(toFile: file, atomically: true, encoding: .utf8)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-08-19T18:00:00Z")!

        let totals = try FxUsageClient.aggregate(path: file, now: now, calendar: calendar)

        XCTAssertEqual(totals.todayTokens, 1_160)     // 100 + 10 + 1000 + 50, dup not counted
        XCTAssertEqual(totals.weekTokens, 1_182)      // today + 22
        XCTAssertEqual(totals.monthTokens, 1_215)     // today + week + 33
        XCTAssertEqual(totals.allTimeTokens, 1_259)   // + last month's 44
        XCTAssertEqual(totals.todayCacheRead, 1_000)
    }

    func testMissingLedgerThrowsWithoutExposingPath() throws {
        let root = try temporaryDirectory()
        let missing = (root as NSString).appendingPathComponent("private/usage.jsonl")
        XCTAssertThrowsError(try FxUsageClient.aggregate(path: missing)) { error in
            XCTAssertEqual(error.localizedDescription, "fx usage ledger not found")
            XCTAssertFalse(error.localizedDescription.contains(root))
        }
    }

    func testAutoDetectedAccountFollowsLedgerPresence() throws {
        let home = try temporaryDirectory()
        XCTAssertNil(FxUsageClient.autoDetectedAccount(home: home))

        let fxDir = (home as NSString).appendingPathComponent(".fx")
        try FileManager.default.createDirectory(atPath: fxDir, withIntermediateDirectories: true)
        try "".write(toFile: (fxDir as NSString).appendingPathComponent("usage.jsonl"), atomically: true, encoding: .utf8)

        let account = FxUsageClient.autoDetectedAccount(home: home)
        XCTAssertEqual(account?.provider, .fx)
        XCTAssertEqual(account?.id, FxUsageClient.autoDetectedID)
    }

    private func temporaryDirectory() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }
}
