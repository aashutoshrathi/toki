import Foundation
import XCTest
@testable import Toki

final class OpenCodeSarvamAttributionTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-08-24T12:00:00Z")!

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testAssistantRowsPartitionFromLegacyFallbackWithoutDoubleCounting() throws {
        let db = try makeDatabase(
            sessions: [
                "('mixed', 1787572800000, 99, 900, 90, 0, 0, 0)",
                "('legacy', 1787572800000, 0.5, 2, 3, 7, 4, 1)"
            ],
            messages: [
                message(session: "mixed", provider: "openrouter", total: 100, input: 60, output: 10, reasoning: 9, read: 30, write: 0, cost: 1),
                message(session: "mixed", provider: "sarvam", total: 200, input: 150, output: 20, reasoning: 8, read: 30, write: 0, cost: 0)
            ]
        )
        defer { try? FileManager.default.removeItem(atPath: db) }

        let openCode = try OpenCodeUsageClient.aggregate(db: db, now: now, calendar: utc)
        XCTAssertEqual(openCode.allTimeTokens, 110)
        XCTAssertEqual(openCode.allTimeCost, 1.5, accuracy: 0.000_001)
        XCTAssertEqual(openCode.sessionCount, 2)
        XCTAssertEqual(openCode.todayInput, 62)
        XCTAssertEqual(openCode.todayCachedInput, 34)

        let sarvam = try SarvamCodeUsageClient.aggregate(root: db + ".missing", openCodeDB: db, now: now, calendar: utc)
        XCTAssertEqual(sarvam.allTimeTokens, 200)
        XCTAssertEqual(sarvam.todayInput, 150)
        XCTAssertEqual(sarvam.todayCachedInput, 30)
        XCTAssertEqual(sarvam.allTimeCosts.amount(for: "USD"), 0)
    }

    func testLegacyDatabaseWithoutMessageTableStillAggregates() throws {
        let db = try makeDatabase(sessions: ["('legacy', 1787572800000, 0.5, 2, 3, 7, 4, 1)"], messages: nil)
        defer { try? FileManager.default.removeItem(atPath: db) }

        let totals = try OpenCodeUsageClient.aggregate(db: db, now: now, calendar: utc)
        XCTAssertEqual(totals.allTimeTokens, 10)
        XCTAssertEqual(totals.allTimeCost, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(totals.todayInput, 2)
        XCTAssertEqual(totals.todayCachedInput, 4)
    }

    func testMissingTotalUsesCacheButDoesNotAddReasoning() throws {
        let db = try makeDatabase(
            sessions: ["('s', 1787572800000, 0, 0, 0, 0, 0, 0)"],
            messages: [message(session: "s", provider: "sarvam", total: nil, input: 10, output: 2, reasoning: 99, read: 30, write: 4, cost: 0)]
        )
        defer { try? FileManager.default.removeItem(atPath: db) }

        let row = try XCTUnwrap(OpenCodeUsageClient.usageRows(db: db).first)
        XCTAssertEqual(row.total, 46)
        XCTAssertEqual(row.reasoning, 99)
        XCTAssertEqual(row.cacheRead, 30)
    }

    func testSarvamAutodetectsOpenCodeOnlyDatabase() throws {
        let dbDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-only-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dbDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dbDirectory) }
        let db = try makeDatabase(
            fileName: "opencode.db",
            directory: dbDirectory,
            sessions: ["('s', 1787572800000, 0, 0, 0, 0, 0, 0)"],
            messages: [message(session: "s", provider: "sarvam", total: 10, input: 8, output: 2, reasoning: 0, read: 0, write: 0, cost: 0)]
        )
        let environment = ["OPENCODE_DATA_DIR": dbDirectory.path]
        XCTAssertNotNil(SarvamCodeUsageClient.autoDetectedAccount(environment: environment, home: dbDirectory.path, cliIsInstalled: { _ in false }))
        XCTAssertEqual(try SarvamCodeUsageClient.aggregate(environment: environment, home: dbDirectory.path).allTimeTokens, 10)
        try FileManager.default.removeItem(atPath: db)
        XCTAssertNil(SarvamCodeUsageClient.autoDetectedAccount(environment: environment, home: dbDirectory.path, cliIsInstalled: { _ in false }))
    }

    func testNativeSarvamAndOpenCodeSarvamMergeOnlyWhenInjected() throws {
        let db = try makeDatabase(
            sessions: ["('s', 1787572800000, 0, 0, 0, 0, 0, 0)"],
            messages: [message(session: "s", provider: "sarvam", total: 10, input: 8, output: 2, reasoning: 0, read: 0, write: 0, cost: 0)]
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sarvam-native-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: db); try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("native.jsonl")
        try """
        {"type":"session_meta","payload":{"id":"native"}}
        {"timestamp":"2026-08-24T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5,"cached_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0,"total_tokens":10,"cost":0.25}}}}
        """.write(to: file, atomically: true, encoding: .utf8)

        let isolated = try SarvamCodeUsageClient.aggregate(root: root.path, now: now, calendar: utc)
        XCTAssertEqual(isolated.allTimeTokens, 10)
        let merged = try SarvamCodeUsageClient.aggregate(root: root.path, openCodeDB: db, now: now, calendar: utc)
        XCTAssertEqual(merged.allTimeTokens, 20)
        XCTAssertEqual(merged.allTimeCosts.amount(for: "USD"), 0.25, accuracy: 0.000_001)
    }

    func testSarvamTotalsRefreshAfterAppendingAndUpdatingMessage() async throws {
        let db = try makeDatabase(
            sessions: ["('s', 1787572800000, 0, 0, 0, 0, 0, 0)"],
            messages: [message(session: "s", provider: "sarvam", total: 10, input: 8, output: 2, reasoning: 0, read: 0, write: 0, cost: 0)]
        )
        defer { try? FileManager.default.removeItem(atPath: db) }
        let first = try SarvamCodeUsageClient.aggregate(root: db + ".missing", openCodeDB: db, now: now, calendar: utc)
        XCTAssertEqual(first.allTimeTokens, 10)
        _ = try Shell.require("/usr/bin/sqlite3", [db, "INSERT INTO message VALUES ('m2','s',1787572800000,1787572800000,'{\"role\":\"assistant\",\"providerID\":\"sarvam\",\"tokens\":{\"total\":5,\"input\":4,\"output\":1},\"cost\":0}');"], failureMessage: "fixture update failed")
        let updated = try SarvamCodeUsageClient.aggregate(root: db + ".missing", openCodeDB: db, now: now, calendar: utc)
        XCTAssertEqual(updated.allTimeTokens, 15)
        _ = try Shell.require("/usr/bin/sqlite3", [db, "UPDATE message SET data=json_set(data,'$.tokens.total',20) WHERE id='m2';"], failureMessage: "fixture update failed")
        let account = AccountConfig(id: "sarvam", name: "Sarvam", provider: .sarvamCode)
        let snapshot = try await SarvamCodeUsageClient(account: account).snapshot(root: db + ".missing", openCodeDB: db, now: now, calendar: utc)
        XCTAssertEqual(snapshot.menuBarValue, "30 tok")
        XCTAssertEqual(snapshot.primary, "30 tokens today")
        XCTAssertFalse(snapshot.metrics.contains { $0.label.contains("Cost") })
    }

    func testDailyAttributionUsesMessageDateAndKeepsCombinedSpendUnique() throws {
        let db = try makeDatabase(
            sessions: ["('mixed', 1787572800000, 999, 999, 999, 0, 0, 0)"],
            messages: [
                message(session: "mixed", provider: "openrouter", total: 100, input: 80, output: 20, reasoning: 0, read: 0, write: 0, cost: 1),
                message(session: "mixed", provider: " SARVAM ", total: 200, input: 150, output: 20, reasoning: 0, read: 30, write: 0, cost: 2)
            ]
        )
        defer { try? FileManager.default.removeItem(atPath: db) }
        _ = try Shell.require("/usr/bin/sqlite3", [db, "UPDATE message SET time_created=time_created-86400000 WHERE id='m1';"], failureMessage: "fixture update failed")
        let today = utc.startOfDay(for: now)
        let yesterday = try XCTUnwrap(utc.date(byAdding: .day, value: -1, to: today))
        let openCode = try OpenCodeUsageClient.aggregate(db: db, now: now, calendar: utc)
        let sarvam = try SarvamCodeUsageClient.aggregate(root: db + ".missing", openCodeDB: db, now: now, calendar: utc)
        XCTAssertEqual(sarvam.todayTokens, 0)
        XCTAssertEqual(sarvam.allTimeTokens, 200)
        XCTAssertEqual(sarvam.allTimeCosts.amount(for: "USD"), 2)
        let spend = SpendAnalyticsPanel.spendRows(pi: nil, openCode: openCode, fx: nil, sarvam: sarvam)
        XCTAssertEqual(spend.first?.allTimeTokens, 300)
        XCTAssertEqual(spend.first?.allTime, 3)
        let openDays = try XCTUnwrap(DailyActivityScanner.openCodeActivity(since: yesterday, calendar: utc, db: db))
        let sarvamDays = try XCTUnwrap(DailyActivityScanner.sarvamCodeActivity(since: yesterday, calendar: utc, root: db + ".missing", openCodeDB: db))
        XCTAssertEqual(openDays.count, 1)
        XCTAssertEqual(openDays.first?.day, today)
        XCTAssertEqual(openDays.first?.tokens, 100)
        XCTAssertEqual(sarvamDays.count, 1)
        XCTAssertEqual(sarvamDays.first?.day, yesterday)
        XCTAssertEqual(sarvamDays.first?.tokens, 200)
    }

    func testLegacyNullableColumnsAndMissingCacheColumns() throws {
        let db = try makeDatabase(sessions: ["('legacy', 1787572800000, NULL, NULL, 3, NULL, NULL, NULL)"], messages: nil)
        defer { try? FileManager.default.removeItem(atPath: db) }
        _ = try Shell.require("/usr/bin/sqlite3", [db, "ALTER TABLE session DROP COLUMN tokens_cache_read; ALTER TABLE session DROP COLUMN tokens_cache_write;"], failureMessage: "fixture update failed")
        let totals = try OpenCodeUsageClient.aggregate(db: db, now: now, calendar: utc)
        XCTAssertEqual(totals.allTimeTokens, 3)
        XCTAssertEqual(totals.allTimeCost, 0)
    }

    private func makeDatabase(fileName: String? = nil, directory: URL? = nil, sessions: [String], messages: [String]?) throws -> String {
        let directory = directory ?? FileManager.default.temporaryDirectory
        let db = directory.appendingPathComponent(fileName ?? "opencode-\(UUID().uuidString).db").path
        var sql = """
        CREATE TABLE session (id TEXT PRIMARY KEY, time_updated INTEGER, cost REAL, tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER);
        INSERT INTO session VALUES \(sessions.joined(separator: ",\n")) ;
        """
        if let messages {
            sql += """
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
            INSERT INTO message VALUES \(messages.enumerated().map { "('m\($0.offset)', '\($0.element.split(separator: "|", maxSplits: 1).first ?? "")', 1787572800000, 1787572800000, '\($0.element.split(separator: "|", maxSplits: 1).dropFirst().first ?? "")')" }.joined(separator: ",\n"));
            """
        }
        _ = try Shell.require("/usr/bin/sqlite3", [db, sql], failureMessage: "fixture database failed")
        return db
    }

    private func message(session: String, provider: String, total: Int?, input: Int, output: Int, reasoning: Int, read: Int, write: Int, cost: Double) -> String {
        let totalField = total.map(String.init) ?? "null"
        let json = "{\"role\":\"assistant\",\"providerID\":\"\(provider)\",\"tokens\":{\"total\":\(totalField),\"input\":\(input),\"output\":\(output),\"reasoning\":\(reasoning),\"cache\":{\"read\":\(read),\"write\":\(write)}},\"cost\":\(cost)}"
        return "\(session)|\(json)"
    }
}
