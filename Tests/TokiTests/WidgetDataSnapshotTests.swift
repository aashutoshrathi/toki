import Foundation
import TokiWidgetShared
import XCTest
@testable import Toki

final class WidgetDataSnapshotTests: XCTestCase {
    func testSnapshotUsesAccountValuesAndAttentionCount() {
        let date = Date(timeIntervalSince1970: 1_000)
        let account = AccountSnapshot(
            id: "codex",
            name: "Work",
            provider: .codex,
            primary: "72% remaining",
            subtitle: "Codex",
            remainingRatio: 0.72,
            metrics: [],
            colorHex: "#7A9CFF"
        )

        let snapshot = WidgetDataStore.makeSnapshot(
            entries: [],
            awaitingInput: 2,
            snapshots: [account],
            updatedAt: date
        )

        XCTAssertEqual(snapshot.updatedAt, date)
        XCTAssertEqual(snapshot.awaitingInputCount, 2)
        XCTAssertEqual(snapshot.entries.map(\.id), ["codex"])
        XCTAssertEqual(snapshot.entries.map(\.displayName), ["Codex"])
        XCTAssertEqual(snapshot.entries.map(\.value), ["72%"])
        XCTAssertEqual(snapshot.entries.map(\.remainingRatio), [0.72])
        XCTAssertEqual(snapshot.entries.map(\.colorHex), ["#7A9CFF"])
        XCTAssertFalse(snapshot.allExhausted)
        XCTAssertNil(snapshot.breakSuggestion)
    }

    func testExhaustedSnapshotIncludesBreakSuggestion() {
        let account = AccountSnapshot(
            id: "claude",
            name: "Claude",
            provider: .claudeCode,
            primary: "0% remaining",
            subtitle: "Claude Code",
            remainingRatio: 0,
            metrics: []
        )

        let snapshot = WidgetDataStore.makeSnapshot(
            entries: [],
            awaitingInput: 0,
            snapshots: [account],
            updatedAt: Date()
        )

        XCTAssertTrue(snapshot.allExhausted)
        XCTAssertNotNil(snapshot.breakSuggestion)
        XCTAssertEqual(snapshot.entries.first?.remainingRatio, 0)
        XCTAssertEqual(snapshot.entries.first?.value, "0%")
    }

    func testResetContextDescribesTheMostConstrainedReportedWindow() {
        var account = AccountSnapshot(
            id: "codex", name: "Work", provider: .codex,
            primary: "20% remaining", subtitle: "Codex", remainingRatio: 0.2, metrics: []
        )
        account.primaryWindow = RateLimitWindow(label: "5h", percentLeft: 70, resetHint: "resets in 1h")
        account.secondaryWindow = RateLimitWindow(label: "7d", percentLeft: 20, resetHint: "resets in 2d")

        let snapshot = WidgetDataStore.makeSnapshot(
            entries: [], awaitingInput: 0, snapshots: [account], updatedAt: Date()
        )
        XCTAssertEqual(snapshot.entries.first?.resetContext, "7d · resets in 2d")
    }

    func testMissingResetHintIsNotInventedFromQuota() {
        var account = AccountSnapshot(
            id: "codex", name: "Work", provider: .codex,
            primary: "0% remaining", subtitle: "Codex", remainingRatio: 0, metrics: []
        )
        account.primaryWindow = RateLimitWindow(label: "5h", percentLeft: 0, resetHint: nil)
        let snapshot = WidgetDataStore.makeSnapshot(
            entries: [], awaitingInput: 0, snapshots: [account], updatedAt: Date()
        )
        XCTAssertNil(snapshot.entries.first?.resetContext)
    }

    func testOlderWidgetEntriesDecodeWithoutResetContext() throws {
        let data = Data(#"{"id":"codex","provider":"codex","displayName":"Codex","value":"72%","remainingRatio":0.72}"#.utf8)
        let entry = try JSONDecoder().decode(WidgetEntry.self, from: data)
        XCTAssertNil(entry.resetContext)
        XCTAssertEqual(entry.remainingRatio, 0.72)
    }

    func testResetContextSurvivesSnapshotRoundTrip() throws {
        let entry = WidgetEntry(
            id: "codex", provider: "codex", displayName: "Codex", value: "0%",
            remainingRatio: 0, leadingText: nil, colorHex: nil, resetContext: "5h · resets in 1h"
        )
        let restored = try JSONDecoder().decode(WidgetEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(restored.resetContext, entry.resetContext)
    }

    func testStalenessWindowOutlastsTheRefreshCadence() {
        let updatedAt = Date(timeIntervalSince1970: 1_000)
        let snapshot = WidgetDataSnapshot(
            updatedAt: updatedAt,
            entries: [],
            awaitingInputCount: 0,
            allExhausted: false,
            breakSuggestion: nil
        )

        XCTAssertFalse(snapshot.isStale(at: updatedAt.addingTimeInterval(10 * 60)))
        XCTAssertFalse(snapshot.isStale(at: updatedAt.addingTimeInterval(tokiWidgetStaleAfter - 1)))
        XCTAssertTrue(snapshot.isStale(at: updatedAt.addingTimeInterval(tokiWidgetStaleAfter + 1)))
    }

    func testLocalURLUsesApplicationSupport() {
        let url = tokiLocalWidgetDataURL(
            userHomeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
        )

        XCTAssertEqual(url?.path, "/Users/example/Library/Application Support/Toki/widget-data.json")
    }
}
