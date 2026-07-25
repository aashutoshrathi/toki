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
    }

    func testStalenessUsesFiveMinuteWindow() {
        let updatedAt = Date(timeIntervalSince1970: 1_000)
        let snapshot = WidgetDataSnapshot(
            updatedAt: updatedAt,
            entries: [],
            awaitingInputCount: 0,
            allExhausted: false,
            breakSuggestion: nil
        )

        XCTAssertFalse(snapshot.isStale(at: updatedAt.addingTimeInterval(299)))
        XCTAssertTrue(snapshot.isStale(at: updatedAt.addingTimeInterval(301)))
    }

    func testLocalURLUsesApplicationSupport() {
        let url = tokiLocalWidgetDataURL(
            userHomeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
        )

        XCTAssertEqual(url?.path, "/Users/example/Library/Application Support/Toki/widget-data.json")
    }
}
