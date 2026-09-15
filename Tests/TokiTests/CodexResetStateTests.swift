import XCTest
@testable import Toki

final class CodexResetStateTests: XCTestCase {
    func testSuccessfulResetUpdatesQuotaAndConsumesCreditImmediately() {
        let snapshot = AccountSnapshot(
            id: "codex",
            name: "Codex",
            provider: .codex,
            primary: "11% left",
            subtitle: "OpenAI Codex",
            remainingRatio: 0.11,
            progressRatio: 0.89,
            resetCreditsAvailable: 2,
            metrics: [
                MetricLine(label: "5h", value: "89% used - resets in 2h"),
                MetricLine(label: "7d", value: "44% used - resets in 3d"),
                MetricLine(label: "Resets", value: "2 available"),
                MetricLine(label: "Limit", value: "primary")
            ],
            primaryWindow: RateLimitWindow(label: "5h", percentLeft: 11, resetHint: "resets in 2h"),
            secondaryWindow: RateLimitWindow(label: "7d", percentLeft: 56, resetHint: "resets in 3d")
        )

        let updated = codexSnapshotAfterReset(snapshot, resetsQuota: true)

        XCTAssertEqual(updated.primary, "100% left")
        XCTAssertEqual(updated.remainingRatio, 1)
        XCTAssertEqual(updated.progressRatio, 0)
        XCTAssertEqual(updated.resetCreditsAvailable, 1)
        XCTAssertEqual(updated.primaryWindow?.percentLeft, 100)
        XCTAssertEqual(updated.secondaryWindow?.percentLeft, 100)
        XCTAssertEqual(updated.metrics.first(where: { $0.label == "Resets" })?.value, "1 available")
        XCTAssertEqual(updated.metrics.first(where: { $0.label == "5h" })?.value, "0% used")
        XCTAssertFalse(updated.metrics.contains(where: { $0.label == "Limit" }))
    }

    func testNoCreditOnlyClearsStaleResetBadge() {
        let snapshot = AccountSnapshot(
            id: "codex",
            name: "Codex",
            provider: .codex,
            primary: "11% left",
            subtitle: "OpenAI Codex",
            remainingRatio: 0.11,
            resetCreditsAvailable: 1,
            metrics: [MetricLine(label: "Resets", value: "1 available")]
        )

        let updated = codexSnapshotAfterReset(snapshot, resetsQuota: false)

        XCTAssertEqual(updated.primary, "11% left")
        XCTAssertEqual(updated.remainingRatio, 0.11)
        XCTAssertEqual(updated.resetCreditsAvailable, 0)
        XCTAssertFalse(updated.metrics.contains(where: { $0.label == "Resets" }))
    }

    func testResetClearsExpiryWhenNoCreditsRemain() {
        let expiry = Date().addingTimeInterval(3 * 24 * 3600)
        let snapshot = AccountSnapshot(
            id: "codex",
            name: "Codex",
            provider: .codex,
            primary: "11% left",
            subtitle: "OpenAI Codex",
            remainingRatio: 0.11,
            resetCreditsAvailable: 1,
            resetCreditExpiry: expiry,
            metrics: [MetricLine(label: "Resets", value: "1 available · expires \(resetDescription(for: expiry))")]
        )

        let updated = codexSnapshotAfterReset(snapshot, resetsQuota: true)

        XCTAssertEqual(updated.resetCreditsAvailable, 0)
        XCTAssertNil(updated.resetCreditExpiry)
        XCTAssertFalse(updated.metrics.contains(where: { $0.label == "Resets" }))
    }

    func testResetPreservesExpiryWhenCreditsRemain() {
        let expiry = Date().addingTimeInterval(3 * 24 * 3600)
        let snapshot = AccountSnapshot(
            id: "codex",
            name: "Codex",
            provider: .codex,
            primary: "11% left",
            subtitle: "OpenAI Codex",
            remainingRatio: 0.11,
            resetCreditsAvailable: 2,
            resetCreditExpiry: expiry,
            metrics: [MetricLine(label: "Resets", value: "2 available · expires \(resetDescription(for: expiry))")]
        )

        let updated = codexSnapshotAfterReset(snapshot, resetsQuota: true)

        XCTAssertEqual(updated.resetCreditsAvailable, 1)
        XCTAssertEqual(updated.resetCreditExpiry, expiry)
        let resetsMetric = updated.metrics.first(where: { $0.label == "Resets" })
        XCTAssertNotNil(resetsMetric)
        XCTAssertTrue(resetsMetric?.value.hasPrefix("1 available · expires ") ?? false)
    }
}
