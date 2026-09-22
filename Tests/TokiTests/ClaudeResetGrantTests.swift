import Foundation
import XCTest
@testable import Toki

final class ClaudeResetGrantTests: XCTestCase {
    private let endsAt = "2026-10-22T16:00:00+00:00"

    private func usage(cedarEmber: Any?) -> [String: Any] {
        var payload: [String: Any] = [
            "five_hour": ["utilization": 10.0, "resets_at": "2026-09-22T22:59:59.879383+00:00"],
            "seven_day": ["utilization": 64.0, "resets_at": "2026-09-22T18:59:59.879412+00:00"]
        ]
        if let cedarEmber { payload["cedar_ember"] = cedarEmber }
        return payload
    }

    private func grant(
        id: String = "opus55-launch-team-20260921",
        resetsLeft: Int = 1,
        paused: Bool = false,
        usableNow: Bool = true,
        useRequiresLimit: Bool = false,
        endsAt: String? = nil
    ) -> [String: Any] {
        [
            "id": id,
            "label": "Claude Opus 5.5 launch: one usage-limit reset for Team members",
            "resets_total": 1,
            "resets_left": resetsLeft,
            "starts_at": "2026-09-22T16:00:00+00:00",
            "ends_at": endsAt ?? self.endsAt,
            "clears": ["five_hour", "seven_day", "seven_day_overage_included"],
            "paused": paused,
            "usable_now": usableNow,
            "use_requires_limit": useRequiresLimit,
            "percent_used": ["five_hour": 2, "seven_day": 0],
            "blocking": []
        ]
    }

    private func block(
        eligible: Bool = true,
        atLimit: Bool = false,
        grants: [[String: Any]],
        nextGrantID: Any? = "opus55-launch-team-20260921"
    ) -> [String: Any] {
        [
            "eligible": eligible,
            "ineligible_reason": NSNull(),
            "at_limit": atLimit,
            "exhausted": [],
            "grants": grants,
            "next_grant_id": nextGrantID ?? NSNull(),
            "weekly_resets_at": "2026-09-29T19:00:00+00:00",
            "cooldown_until": NSNull()
        ]
    }

    func testUsableGrantIsOffered() {
        let parsed = ClaudeCodeUsage(json: usage(cedarEmber: block(grants: [grant()])))

        XCTAssertEqual(parsed.resetCreditsAvailable, 1)
        XCTAssertEqual(parsed.resetGrantID, "opus55-launch-team-20260921")
        XCTAssertEqual(parsed.resetCreditExpiry, ISO8601DateFormatter().date(from: endsAt))
        XCTAssertTrue(parsed.metrics.contains { $0.label == "Resets" })
    }

    func testMissingBlockLeavesNoCredit() {
        let parsed = ClaudeCodeUsage(json: usage(cedarEmber: nil))

        XCTAssertEqual(parsed.resetCreditsAvailable, 0)
        XCTAssertNil(parsed.resetGrantID)
        XCTAssertFalse(parsed.metrics.contains { $0.label == "Resets" })
    }

    func testIneligibleAccountIsNotOffered() {
        let payload = usage(cedarEmber: block(eligible: false, grants: [grant()]))

        XCTAssertEqual(ClaudeCodeUsage(json: payload).resetCreditsAvailable, 0)
    }

    func testPausedExhaustedAndUnusableGrantsAreSkipped() {
        for candidate in [grant(paused: true), grant(resetsLeft: 0), grant(usableNow: false)] {
            let parsed = ClaudeCodeUsage(json: usage(cedarEmber: block(grants: [candidate])))
            XCTAssertEqual(parsed.resetCreditsAvailable, 0)
            XCTAssertNil(parsed.resetGrantID)
        }
    }

    func testGrantNeedingTheWallIsOnlyOfferedAtTheWall() {
        let needsWall = grant(useRequiresLimit: true)

        XCTAssertEqual(ClaudeCodeUsage(json: usage(cedarEmber: block(atLimit: false, grants: [needsWall]))).resetCreditsAvailable, 0)
        XCTAssertEqual(ClaudeCodeUsage(json: usage(cedarEmber: block(atLimit: true, grants: [needsWall]))).resetCreditsAvailable, 1)
    }

    func testCountSumsGrantsAndExpiryIsTheSoonest() {
        let soonest = "2026-10-01T16:00:00+00:00"
        let payload = usage(cedarEmber: block(grants: [
            grant(id: "grant-a", resetsLeft: 2),
            grant(id: "grant-b", resetsLeft: 3, endsAt: soonest)
        ], nextGrantID: "grant-b"))

        let parsed = ClaudeCodeUsage(json: payload)

        XCTAssertEqual(parsed.resetCreditsAvailable, 5)
        XCTAssertEqual(parsed.resetGrantID, "grant-b")
        XCTAssertEqual(parsed.resetCreditExpiry, ISO8601DateFormatter().date(from: soonest))
    }

    func testUnknownNextGrantFallsBackToAUsableGrant() {
        let payload = usage(cedarEmber: block(grants: [grant(id: "grant-a")], nextGrantID: "retired-grant"))

        XCTAssertEqual(ClaudeCodeUsage(json: payload).resetGrantID, "grant-a")
    }
}
