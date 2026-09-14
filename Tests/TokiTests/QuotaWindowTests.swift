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
        XCTAssertNil(usage.rateLimitWindows[0].paceDeviation())
        XCTAssertNotNil(usage.rateLimitWindows[1].resetHint)
        XCTAssertEqual(usage.rateLimitWindows[1].resetAt, ISO8601DateFormatter().date(from: "2099-01-02T03:04:05Z"))
        XCTAssertEqual(usage.rateLimitWindows.map(\.duration), [5 * 3600, 7 * 86_400])
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

    func testPaceComparesUsedQuotaWithElapsedWindowTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var window = RateLimitWindow(
            label: "7d", percentLeft: 60, resetAt: now.addingTimeInterval(3.5 * 86_400),
            duration: 7 * 86_400
        )
        XCTAssertEqual(window.paceDeviation(at: now), -10)
        XCTAssertEqual(window.expectedRemainingRatio(at: now), 0.5)
        XCTAssertEqual(window.expectedRemainingRatio(at: now.addingTimeInterval(1.75 * 86_400)), 0.25)
        window.percentLeft = 40
        XCTAssertEqual(window.paceDeviation(at: now), 10)
        window.percentLeft = 50
        XCTAssertEqual(window.paceDeviation(at: now), 0)
    }

    func testPaceIsHiddenWithoutACurrentKnownWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var window = RateLimitWindow(label: "5h", percentLeft: 80)
        XCTAssertNil(window.paceDeviation(at: now))
        window.resetAt = now.addingTimeInterval(3600)
        XCTAssertNil(window.paceDeviation(at: now))
        window.duration = 0
        XCTAssertNil(window.paceDeviation(at: now))
        window.duration = 5 * 3600
        window.resetAt = now
        XCTAssertNil(window.paceDeviation(at: now))
        window.resetAt = now.addingTimeInterval(6 * 3600)
        XCTAssertNil(window.paceDeviation(at: now))
    }

    func testCodexPaceUsesReportedDurationWithoutGuessingFromItsLabel() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let limits = CodexRateLimits(json: ["rateLimits": [
            "primary": ["usedPercent": 40, "windowDurationMins": 45, "resetsAt": now.timeIntervalSince1970 + 1350],
            "secondary": ["usedPercent": 40, "resetsAt": now.timeIntervalSince1970 + 1350]
        ]])
        XCTAssertEqual(limits.primaryWindow?.duration, 2700)
        XCTAssertEqual(limits.primaryWindow?.paceDeviation(at: now), -10)
        XCTAssertNil(limits.secondaryWindow?.paceDeviation(at: now))
    }

    func testOverviewLabelsTheWindowItsRingRepresents() {
        var snapshot = AccountSnapshot(
            id: "claude", name: "Claude", provider: .claudeCode,
            primary: "100% left", subtitle: "", remainingRatio: 1, metrics: [],
            primaryWindow: .init(label: "5h", percentLeft: 100),
            secondaryWindow: .init(label: "7d", percentLeft: 100, resetHint: "in 6d")
        )
        let tied = QuotaRingsPanel.overviewSnapshot(snapshot)
        XCTAssertEqual(tied.primaryWindow?.label, "7d")
        XCTAssertEqual(tied.primaryWindow?.resetHint, "in 6d")
        XCTAssertEqual(tied.remainingRatio, 1)

        snapshot.primaryWindow?.percentLeft = 25
        let limited = QuotaRingsPanel.overviewSnapshot(snapshot)
        XCTAssertEqual(limited.primaryWindow?.label, "5h")
        XCTAssertNil(limited.primaryWindow?.resetHint)
        XCTAssertEqual(limited.remainingRatio, 0.25)
    }

    func testOverviewUsesPreferredWindowAndFallsBackWhenUnavailable() {
        let fiveHour = RateLimitWindow(label: "5h", percentLeft: 75, resetHint: "in 4h")
        let weekly = RateLimitWindow(label: "7d", percentLeft: 10, resetHint: "in 6d")
        let snapshot = AccountSnapshot(
            id: "claude", name: "Claude", provider: .claudeCode,
            primary: "10% left", subtitle: "", remainingRatio: 0.1, metrics: [],
            primaryWindow: fiveHour, secondaryWindow: weekly
        )

        for (preference, expected) in [("5h", fiveHour), ("7d", weekly), ("unavailable", weekly)] {
            let displayed = QuotaRingsPanel.overviewSnapshot(snapshot, preferredWindow: preference)
            XCTAssertEqual(displayed.primaryWindow, expected, "Preference: \(preference)")
            XCTAssertEqual(displayed.remainingRatio, Double(expected.percentLeft) / 100)
        }
    }
}
