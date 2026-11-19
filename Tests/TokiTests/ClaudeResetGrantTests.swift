import Foundation
import XCTest
@testable import Toki

final class ClaudeResetGrantTests: XCTestCase {
    private let endsAt = "2026-10-22T16:00:00+00:00"

    private func usage(
        cedarEmber: Any?,
        fiveHour: [String: Any]? = nil,
        sevenDay: [String: Any]? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "five_hour": fiveHour ?? ["utilization": 10.0, "resets_at": "2026-09-22T22:59:59.879383+00:00"],
            "seven_day": sevenDay ?? ["utilization": 64.0, "resets_at": "2026-09-22T18:59:59.879412+00:00"]
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
        endsAt: String? = nil,
        clears: [String]? = nil
    ) -> [String: Any] {
        [
            "id": id,
            "label": "Claude Opus 5.5 launch: one usage-limit reset for Team members",
            "resets_total": 1,
            "resets_left": resetsLeft,
            "starts_at": "2026-09-22T16:00:00+00:00",
            "ends_at": endsAt ?? self.endsAt,
            "clears": clears ?? ["five_hour", "seven_day", "seven_day_overage_included"],
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

    func testExpiryIsTheNextGrantsEvenWhenAnotherEndsSooner() {
        let nextEnds = "2026-11-20T16:00:00+00:00"
        let payload = usage(cedarEmber: block(grants: [
            grant(id: "grant-a", resetsLeft: 1, endsAt: "2026-10-01T16:00:00+00:00"),
            grant(id: "grant-b", resetsLeft: 1, endsAt: nextEnds)
        ], nextGrantID: "grant-b"))

        let parsed = ClaudeCodeUsage(json: payload)

        XCTAssertEqual(parsed.resetGrantID, "grant-b")
        XCTAssertEqual(parsed.resetCreditExpiry, ISO8601DateFormatter().date(from: nextEnds))
    }

    func testGrantIsOnlyOfferedWhenItIsTheNamedNextGrant() {
        for nextGrantID in ["retired-grant", nil] {
            let parsed = ClaudeCodeUsage(json: usage(cedarEmber: block(grants: [grant(id: "grant-a")], nextGrantID: nextGrantID)))

            XCTAssertEqual(parsed.resetCreditsAvailable, 0)
            XCTAssertNil(parsed.resetGrantID)
        }
    }

    func testNextGrantThatCannotBeUsedNowHidesTheBadge() {
        let payload = usage(cedarEmber: block(grants: [
            grant(id: "grant-a"),
            grant(id: "grant-b", paused: true)
        ], nextGrantID: "grant-b"))

        XCTAssertEqual(ClaudeCodeUsage(json: payload).resetCreditsAvailable, 0)
    }

    func testFableAndStandardResetsAreSeparated() {
        let fableEnds = "2026-10-15T12:00:00+00:00"
        let stdEnds = "2026-10-20T12:00:00+00:00"
        let fableGrant: [String: Any] = [
            "id": "fable-launch-2026",
            "label": "Claude Fable 5 weekly reset",
            "resets_total": 1,
            "resets_left": 1,
            "starts_at": "2026-09-22T16:00:00+00:00",
            "ends_at": fableEnds,
            "clears": ["seven_day_fable_5"],
            "paused": false,
            "usable_now": true,
            "use_requires_limit": true
        ]
        let stdGrant: [String: Any] = [
            "id": "team-launch-2026",
            "label": "Claude standard reset",
            "resets_total": 2,
            "resets_left": 2,
            "starts_at": "2026-09-22T16:00:00+00:00",
            "ends_at": stdEnds,
            "clears": ["five_hour", "seven_day"],
            "paused": false,
            "usable_now": true,
            "use_requires_limit": false
        ]

        let payload = usage(cedarEmber: block(
            atLimit: false,
            grants: [stdGrant, fableGrant],
            nextGrantID: "team-launch-2026"
        ))
        let parsed = ClaudeCodeUsage(json: payload)

        XCTAssertEqual(parsed.resetCreditGroups.count, 2)
        let std = parsed.resetCreditGroups.first { $0.kind == .standard }
        let fab = parsed.resetCreditGroups.first { $0.kind == .fable }

        XCTAssertNotNil(std)
        XCTAssertEqual(std?.count, 2)
        XCTAssertEqual(std?.expiry, ISO8601DateFormatter().date(from: stdEnds))
        XCTAssertTrue(std?.canRedeemNow == true)
        XCTAssertEqual(std?.grantID, "team-launch-2026")

        XCTAssertNotNil(fab)
        XCTAssertEqual(fab?.count, 1)
        XCTAssertEqual(fab?.expiry, ISO8601DateFormatter().date(from: fableEnds))
        XCTAssertFalse(fab?.canRedeemNow == true) // requires limit, and atLimit is false
        XCTAssertEqual(fab?.requirementDescription, "Requires rate limit")
        XCTAssertEqual(fab?.unavailableReason, "queued behind active reset; requires reaching Fable 7d limit first")
        XCTAssertNil(fab?.grantID) // Not the named next_grant_id, so cannot be redeemed yet

        XCTAssertTrue(parsed.metrics.contains { $0.label == "Resets (Standard)" && $0.value.contains("2 available") })
        XCTAssertTrue(parsed.metrics.contains { $0.label == "Resets (Fable)" && $0.value.contains("queued") && $0.value.contains("requires limit") })
    }

    func testOnlyTheGroupHoldingNextGrantIDIsRedeemable() {
        let fableGrant: [String: Any] = [
            "id": "fable-launch-2026",
            "label": "Claude Fable 5 weekly reset",
            "resets_total": 1,
            "resets_left": 1,
            "starts_at": "2026-09-22T16:00:00+00:00",
            "ends_at": endsAt,
            "clears": ["seven_day_fable_5"],
            "paused": false,
            "usable_now": true,
            "use_requires_limit": true
        ]
        let stdGrant: [String: Any] = [
            "id": "team-launch-2026",
            "label": "Claude Standard weekly reset",
            "resets_total": 1,
            "resets_left": 1,
            "starts_at": "2026-09-22T16:00:00+00:00",
            "ends_at": endsAt,
            "clears": ["five_hour", "seven_day"],
            "paused": false,
            "usable_now": true,
            "use_requires_limit": false
        ]

        // When next_grant_id is the Fable grant and at limit
        let fableNextPayload = usage(cedarEmber: block(
            atLimit: true,
            grants: [stdGrant, fableGrant],
            nextGrantID: "fable-launch-2026"
        ))
        let fableParsed = ClaudeCodeUsage(json: fableNextPayload)
        let fabGroup = fableParsed.resetCreditGroups.first { $0.kind == .fable }
        let stdGroup = fableParsed.resetCreditGroups.first { $0.kind == .standard }

        XCTAssertEqual(fabGroup?.grantID, "fable-launch-2026")
        XCTAssertTrue(fabGroup?.canRedeemNow == true)
        XCTAssertNil(stdGroup?.grantID)
        XCTAssertFalse(stdGroup?.canRedeemNow == true)
        XCTAssertEqual(stdGroup?.unavailableReason, "queued behind active reset")
    }

    func testUnusableOrMissingNextGrantHidesGroups() {
        let grantA = grant(id: "grant-a")
        for badNextID in ["other-grant", nil] {
            let payload = usage(cedarEmber: block(grants: [grantA], nextGrantID: badNextID))
            let parsed = ClaudeCodeUsage(json: payload)
            XCTAssertTrue(parsed.resetCreditGroups.isEmpty)
            XCTAssertEqual(parsed.resetCreditsAvailable, 0)
            XCTAssertNil(parsed.resetGrantID)
        }
    }

    func testFableResetCanRedeemWhenAtLimit() {
        let fableGrant: [String: Any] = [
            "id": "fable-launch-2026",
            "label": "Claude Fable 5 weekly reset",
            "resets_total": 1,
            "resets_left": 1,
            "starts_at": "2026-09-22T16:00:00+00:00",
            "ends_at": endsAt,
            "clears": ["seven_day_fable_5"],
            "paused": false,
            "usable_now": true,
            "use_requires_limit": true
        ]
        let payload = usage(cedarEmber: block(
            atLimit: true,
            grants: [fableGrant],
            nextGrantID: "fable-launch-2026"
        ))
        let parsed = ClaudeCodeUsage(json: payload)

        XCTAssertEqual(parsed.resetCreditGroups.count, 1)
        let fab = parsed.resetCreditGroups.first
        XCTAssertEqual(fab?.kind, .fable)
        XCTAssertTrue(fab?.canRedeemNow == true)
        XCTAssertEqual(fab?.requirementDescription, "At rate limit")
        XCTAssertTrue(parsed.metrics.contains { $0.label == "Resets (Fable)" })
    }

    func testNextGrantWithoutExpiryDoesNotInheritAnotherGrantsExpiry() throws {
        var next = grant(id: "next")
        next["ends_at"] = NSNull()
        let parsed = ClaudeCodeUsage(json: usage(cedarEmber: block(
            grants: [grant(id: "other"), next], nextGrantID: "next"
        )))
        XCTAssertNil(parsed.resetCreditExpiry)
        XCTAssertNil(try XCTUnwrap(parsed.resetCreditGroups.first).expiry)
    }

    func testSelectedGrantIsRevalidatedAgainstLiveNextGrant() throws {
        let parsed = ClaudeCodeUsage(json: usage(cedarEmber: block(
            grants: [grant(id: "old"), grant(id: "next")], nextGrantID: "next"
        )))
        XCTAssertThrowsError(try ClaudeCodeUsageClient.validatedResetGrant(
            in: parsed, creditID: "old", condition: nil
        ))
        let selected = try ClaudeCodeUsageClient.validatedResetGrant(
            in: parsed, creditID: "next", condition: nil
        )
        XCTAssertEqual(selected.grantID, "next")
        XCTAssertEqual(selected.expiry, ISO8601DateFormatter().date(from: endsAt))
    }

    func testSelectedGrantCannotRedeemWhenLiveGrantIsPaused() {
        let parsed = ClaudeCodeUsage(json: usage(cedarEmber: block(grants: [grant(paused: true)])))
        XCTAssertThrowsError(try ClaudeCodeUsageClient.validatedResetGrant(
            in: parsed, creditID: "opus55-launch-team-20260921", condition: nil
        ))
    }

    func testSelectedGrantExpiryConditionUsesItsLiveExpiry() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: endsAt)).addingTimeInterval(-120)
        let parsed = ClaudeCodeUsage(json: usage(cedarEmber: block(grants: [grant()])))
        let selected = try ClaudeCodeUsageClient.validatedResetGrant(
            in: parsed, creditID: parsed.resetGrantID,
            condition: .expiringBy(now.addingTimeInterval(300)), now: now
        )
        XCTAssertEqual(selected.expiry, parsed.resetCreditExpiry)
        XCTAssertThrowsError(try ClaudeCodeUsageClient.validatedResetGrant(
            in: parsed, creditID: parsed.resetGrantID,
            condition: .expiringBy(now.addingTimeInterval(60)), now: now
        ))
    }

    func testIsFableGrantVariants() {
        XCTAssertTrue(ClaudeCodeUsage.isFableGrant(["clears": ["seven_day_fable_5"]]))
        XCTAssertTrue(ClaudeCodeUsage.isFableGrant(["clears": ["fable_window"]]))
        XCTAssertTrue(ClaudeCodeUsage.isFableGrant(["id": "fable-launch-credit"]))
        XCTAssertTrue(ClaudeCodeUsage.isFableGrant(["label": "Fable 5 special reset"]))
        XCTAssertFalse(ClaudeCodeUsage.isFableGrant(["clears": ["five_hour", "seven_day"], "id": "standard-grant"]))
    }

    func testSingleGrantRequiringRateLimitIsVisibleWhenNotAtLimit() {
        let fableGrant: [String: Any] = [
            "id": "fable-only",
            "label": "Claude Fable reset",
            "resets_total": 1,
            "resets_left": 1,
            "starts_at": "2026-09-22T16:00:00+00:00",
            "ends_at": endsAt,
            "clears": ["seven_day_fable_5"],
            "paused": false,
            "usable_now": true,
            "use_requires_limit": true
        ]
        let payload = usage(cedarEmber: block(
            atLimit: false,
            grants: [fableGrant],
            nextGrantID: "fable-only"
        ))
        let parsed = ClaudeCodeUsage(json: payload)

        XCTAssertEqual(parsed.resetCreditsAvailable, 0)
        XCTAssertNil(parsed.resetGrantID)
        XCTAssertEqual(parsed.resetCreditGroups.count, 1)

        let fab = parsed.resetCreditGroups.first
        XCTAssertEqual(fab?.count, 1)
        XCTAssertEqual(fab?.grantID, "fable-only")
        XCTAssertFalse(fab?.canRedeemNow == true)
        XCTAssertEqual(fab?.requirementDescription, "Requires rate limit")
        XCTAssertEqual(fab?.unavailableReason, "requires reaching Fable 7d limit first")
    }

    func testQueuedGroupUsesSoonestExpiryAmongItsGrants() {
        let stdGrant = grant(id: "std-next", endsAt: "2026-11-20T16:00:00+00:00")
        let fabLate: [String: Any] = [
            "id": "fab-late", "resets_total": 1, "resets_left": 1,
            "starts_at": "2026-09-22T16:00:00+00:00",
            "ends_at": "2026-12-01T16:00:00+00:00",
            "clears": ["seven_day_fable_5"], "paused": false, "usable_now": true, "use_requires_limit": true
        ]
        let fabSoon: [String: Any] = [
            "id": "fab-soon", "resets_total": 1, "resets_left": 1,
            "starts_at": "2026-09-22T16:00:00+00:00",
            "ends_at": "2026-10-01T16:00:00+00:00",
            "clears": ["seven_day_fable_5"], "paused": false, "usable_now": true, "use_requires_limit": true
        ]
        let payload = usage(cedarEmber: block(
            atLimit: false,
            grants: [stdGrant, fabLate, fabSoon],
            nextGrantID: "std-next"
        ))
        let parsed = ClaudeCodeUsage(json: payload)

        let fabGroup = parsed.resetCreditGroups.first { $0.kind == .fable }
        XCTAssertNotNil(fabGroup)
        XCTAssertEqual(fabGroup?.expiry, ISO8601DateFormatter().date(from: "2026-10-01T16:00:00+00:00"))
    }

    func testSelectedGrantWeeklyConditionRequiresSevenDayClear() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let weekEnd = now.addingTimeInterval(86_400)
        let weekEndStr = ISO8601DateFormatter().string(from: weekEnd)

        // Grant with exact seven_day clear succeeds (utilization: 95 means 5% left)
        let validGrant = grant(id: "std-valid", clears: ["five_hour", "seven_day"])
        let validParsed = ClaudeCodeUsage(json: usage(
            cedarEmber: block(grants: [validGrant], nextGrantID: "std-valid"),
            sevenDay: ["utilization": 95.0, "resets_at": weekEndStr]
        ))
        let selected = try ClaudeCodeUsageClient.validatedResetGrant(
            in: validParsed,
            creditID: "std-valid",
            condition: .weeklyAtOrBelow(10, minimumHoursRemaining: 1, expectedWindowEnd: weekEnd),
            now: now
        )
        XCTAssertEqual(selected.grantID, "std-valid")

        // Grant with only model-specific or empty clears fails weekly live check
        let emptyClearsGrant = grant(id: "empty-clears", clears: [])
        let emptyParsed = ClaudeCodeUsage(json: usage(
            cedarEmber: block(grants: [emptyClearsGrant], nextGrantID: "empty-clears"),
            sevenDay: ["utilization": 95.0, "resets_at": weekEndStr]
        ))
        XCTAssertThrowsError(try ClaudeCodeUsageClient.validatedResetGrant(
            in: emptyParsed,
            creditID: "empty-clears",
            condition: .weeklyAtOrBelow(10, minimumHoursRemaining: 1),
            now: now
        ))

        let fableClearsGrant: [String: Any] = [
            "id": "fab-clears", "resets_total": 1, "resets_left": 1,
            "starts_at": "2026-09-22T16:00:00+00:00", "ends_at": endsAt,
            "clears": ["seven_day_fable_5"], "paused": false, "usable_now": true, "use_requires_limit": false
        ]
        let fableParsed = ClaudeCodeUsage(json: usage(
            cedarEmber: block(grants: [fableClearsGrant], nextGrantID: "fab-clears"),
            sevenDay: ["utilization": 95.0, "resets_at": weekEndStr]
        ))
        XCTAssertThrowsError(try ClaudeCodeUsageClient.validatedResetGrant(
            in: fableParsed,
            creditID: "fab-clears",
            condition: .weeklyAtOrBelow(10, minimumHoursRemaining: 1),
            now: now
        ))
    }

    func testSelectedGrantWeeklyConditionRejectsWindowEndDrift() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let originalWindowEnd = now.addingTimeInterval(48 * 3600)
        let movedWindowEnd = originalWindowEnd.addingTimeInterval(5 * 3600) // 5 hours later

        let stdGrant = grant(id: "std-drift", clears: ["five_hour", "seven_day"])
        let liveUsage = ClaudeCodeUsage(json: usage(
            cedarEmber: block(grants: [stdGrant], nextGrantID: "std-drift"),
            sevenDay: [
                "utilization": 95.0,
                "resets_at": ISO8601DateFormatter().string(from: movedWindowEnd)
            ]
        ))

        XCTAssertThrowsError(try ClaudeCodeUsageClient.validatedResetGrant(
            in: liveUsage,
            creditID: "std-drift",
            condition: .weeklyAtOrBelow(10, minimumHoursRemaining: 1, expectedWindowEnd: originalWindowEnd),
            now: now
        ))
    }
}
