import XCTest
@testable import Toki

final class QuotaWindowTests: XCTestCase {
    func testClaudeExposesRecentAndWeeklyWindowsForCompactCards() {
        let usage = ClaudeCodeUsage(json: [
            "five_hour": ["utilization": 12.0, "resets_at": NSNull()],
            "seven_day": ["utilization": 34.0, "resets_at": "2099-01-02T03:04:05Z"]
        ])

        XCTAssertEqual(usage.rateLimitWindows.map(\.label), ["5h", "7d"])
        XCTAssertEqual(usage.rateLimitWindows.map(\.percentLeft), [88, 66])
        XCTAssertNil(usage.rateLimitWindows[0].resetHint)
        XCTAssertNotNil(usage.rateLimitWindows[1].resetHint)
        XCTAssertEqual(usage.metrics.map(\.label), ["5h", "7d"])
        XCTAssertEqual(usage.primaryMetric?.label, "5h")
    }

    func testClaudeKeepsAWindowWithoutAResetTimestamp() {
        let usage = ClaudeCodeUsage(json: [
            "five_hour": ["utilization": 0.0, "resets_at": NSNull()]
        ])

        XCTAssertEqual(usage.rateLimitWindows.count, 1)
        XCTAssertEqual(usage.rateLimitWindows[0].percentLeft, 100)
        XCTAssertNil(usage.rateLimitWindows[0].resetHint)
    }

    func testClaudeOmitsAWindowWhoseUtilizationIsNull() {
        let usage = ClaudeCodeUsage(json: [
            "five_hour": ["utilization": NSNull(), "resets_at": NSNull()],
            "seven_day": ["utilization": 9.0, "resets_at": NSNull()]
        ])

        XCTAssertEqual(usage.rateLimitWindows.map(\.label), ["7d"])
        XCTAssertEqual(usage.primaryMetric?.label, "7d")
    }

    func testCodexExposesBothWindowsWhenThePrimaryAllowanceProvidesThem() {
        let limits = CodexRateLimits(json: [
            "rateLimitsByLimitId": [
                "codex": [
                    "planType": "plus",
                    "primary": ["usedPercent": 20, "windowDurationMins": 300, "resetsAt": 4_102_444_800],
                    "secondary": ["usedPercent": 40, "windowDurationMins": 10_080, "resetsAt": 4_103_049_600]
                ]
            ]
        ])

        XCTAssertEqual(limits.primaryWindow?.label, "5h")
        XCTAssertEqual(limits.primaryWindow?.percentLeft, 80)
        XCTAssertEqual(limits.secondaryWindow?.label, "7d")
        XCTAssertEqual(limits.secondaryWindow?.percentLeft, 60)
    }

    func testCodexKeepsAWeeklyOnlyPrimaryAllowanceSeparateFromOtherBuckets() {
        let limits = CodexRateLimits(json: [
            "rateLimitsByLimitId": [
                "codex": [
                    "planType": "pro",
                    "primary": ["usedPercent": 1, "windowDurationMins": 10_080, "resetsAt": 4_103_049_600]
                ],
                "codex_model_specific": [
                    "planType": "pro",
                    "primary": ["usedPercent": 75, "windowDurationMins": 300, "resetsAt": 4_102_444_800],
                    "secondary": ["usedPercent": 50, "windowDurationMins": 10_080, "resetsAt": 4_103_049_600]
                ]
            ]
        ])

        XCTAssertEqual(limits.primaryWindow?.label, "7d")
        XCTAssertEqual(limits.primaryWindow?.percentLeft, 99)
        XCTAssertNil(limits.secondaryWindow)
    }

    func testCompactResetDescriptionKeepsOnlyTheRelativeCountdown() {
        XCTAssertEqual(compactResetDescription("resets in 4h (18:00)"), "in 4h")
        XCTAssertEqual(compactResetDescription("resets in 6d (Sep 4 00:58)"), "in 6d")
        XCTAssertEqual(compactResetDescription("resets in now (12:00)"), "now")
        XCTAssertNil(compactResetDescription(nil))
    }
}
