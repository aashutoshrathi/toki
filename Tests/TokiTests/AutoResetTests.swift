import XCTest
@testable import Toki

final class AutoResetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let weekEnd = Date(timeIntervalSince1970: 1_800_000_000 + 86_400)

    private func snapshot(
        provider: Provider = .codex,
        weeklyLeft: Int,
        credits: Int = 1,
        expiry: Date? = nil,
        isError: Bool = false,
        weeklyResetAt: Date? = Date(timeIntervalSince1970: 1_800_086_400)
    ) -> AccountSnapshot {
        AccountSnapshot(
            id: "account",
            name: "Account",
            provider: provider,
            primary: "",
            subtitle: "",
            remainingRatio: nil,
            resetCreditsAvailable: credits,
            resetCreditExpiry: expiry,
            metrics: [],
            isError: isError,
            primaryWindow: RateLimitWindow(label: "5h", percentLeft: 90, resetAt: weekEnd.addingTimeInterval(-86_400)),
            secondaryWindow: RateLimitWindow(label: "7d", percentLeft: weeklyLeft, resetAt: weeklyResetAt)
        )
    }

    func testRedeemsWhenWeeklyLeftIsAtOrBelowTheSetting() {
        XCTAssertTrue(shouldAutoRedeemReset(snapshot(weeklyLeft: 10), weeklyPercentLeft: 10, minimumHoursRemaining: 1, lastRedeemedWindowEnd: nil, now: now))
        XCTAssertTrue(shouldAutoRedeemReset(snapshot(provider: .claudeCode, weeklyLeft: 4), weeklyPercentLeft: 10, minimumHoursRemaining: 1, lastRedeemedWindowEnd: nil, now: now))
    }

    func testWaitsWhileWeeklyLeftIsAboveTheSetting() {
        XCTAssertFalse(shouldAutoRedeemReset(snapshot(weeklyLeft: 11), weeklyPercentLeft: 10, minimumHoursRemaining: 1, lastRedeemedWindowEnd: nil, now: now))
    }

    func testOnlyTheWeeklyWindowCounts() {
        var low5h = snapshot(weeklyLeft: 80)
        low5h.primaryWindow?.percentLeft = 0
        XCTAssertFalse(shouldAutoRedeemReset(low5h, weeklyPercentLeft: 10, minimumHoursRemaining: 1, lastRedeemedWindowEnd: nil, now: now))
    }

    func testNeedsABankedReset() {
        XCTAssertFalse(shouldAutoRedeemReset(snapshot(weeklyLeft: 2, credits: 0), weeklyPercentLeft: 10, minimumHoursRemaining: 1, lastRedeemedWindowEnd: nil, now: now))
    }

    func testSkipsErroredAndUnsupportedProviders() {
        XCTAssertFalse(shouldAutoRedeemReset(snapshot(weeklyLeft: 2, isError: true), weeklyPercentLeft: 10, minimumHoursRemaining: 1, lastRedeemedWindowEnd: nil, now: now))
        XCTAssertFalse(shouldAutoRedeemReset(snapshot(provider: .cursor, weeklyLeft: 2), weeklyPercentLeft: 10, minimumHoursRemaining: 1, lastRedeemedWindowEnd: nil, now: now))
    }

    private func expiring(_ snapshot: AccountSnapshot, within minutes: Int, lastRedeemedExpiry: Date? = nil) -> Bool {
        shouldRedeemExpiringReset(snapshot, minutesBeforeExpiry: minutes, lastRedeemedExpiry: lastRedeemedExpiry, now: now)
    }

    func testRedeemsAResetAboutToExpire() {
        XCTAssertTrue(expiring(snapshot(weeklyLeft: 80, expiry: now.addingTimeInterval(4 * 60)), within: 5))
        XCTAssertTrue(expiring(snapshot(weeklyLeft: 80, expiry: now.addingTimeInterval(5 * 60)), within: 5))
    }

    func testLeavesAResetThatIsNotAboutToExpire() {
        XCTAssertFalse(expiring(snapshot(weeklyLeft: 80, expiry: now.addingTimeInterval(6 * 60)), within: 5))
        XCTAssertFalse(expiring(snapshot(weeklyLeft: 80, expiry: nil), within: 5))
    }

    func testIgnoresAResetThatHasAlreadyExpired() {
        XCTAssertFalse(expiring(snapshot(weeklyLeft: 80, expiry: now.addingTimeInterval(-1)), within: 5))
    }

    func testExpiryNeedsABankedResetOnASupportedProvider() {
        let soon = now.addingTimeInterval(60)
        XCTAssertFalse(expiring(snapshot(weeklyLeft: 80, credits: 0, expiry: soon), within: 5))
        XCTAssertFalse(expiring(snapshot(provider: .cursor, weeklyLeft: 80, expiry: soon), within: 5))
        XCTAssertFalse(expiring(snapshot(weeklyLeft: 80, expiry: soon, isError: true), within: 5))
    }

    func testRedeemsEachExpiringResetOnce() {
        let soon = now.addingTimeInterval(60)
        let account = snapshot(weeklyLeft: 80, expiry: soon)
        XCTAssertFalse(expiring(account, within: 5, lastRedeemedExpiry: soon))
        XCTAssertTrue(expiring(account, within: 5, lastRedeemedExpiry: soon.addingTimeInterval(-86_400)))
    }

    private func preferences(enabled: Bool, percentLeft: Int?, minimumHoursRemaining: Int = 1) -> AppPreferences {
        var preferences = AppPreferences()
        preferences.autoResetEnabled = enabled
        preferences.autoResetWeeklyPercentLeft = percentLeft
        preferences.autoResetWeeklyMinHoursRemaining = minimumHoursRemaining
        return preferences
    }

    func testMarkerSitsWhereTheSettingLeavesThatMuchLeft() throws {
        let account = snapshot(weeklyLeft: 60)
        let weekly = try XCTUnwrap(account.secondaryWindow)
        XCTAssertEqual(autoResetMarkerRatio(for: weekly, in: account, preferences: preferences(enabled: true, percentLeft: 1)), 0.99)
        XCTAssertEqual(autoResetMarkerRatio(for: weekly, in: account, preferences: preferences(enabled: true, percentLeft: 0)), 1)
    }

    func testMarkerOnlyOnTheWeeklyBar() throws {
        let account = snapshot(weeklyLeft: 60)
        let session = try XCTUnwrap(account.primaryWindow)
        let fable = RateLimitWindow(label: "Fable 5 7d", percentLeft: 40, resetAt: weekEnd)
        XCTAssertNil(autoResetMarkerRatio(for: session, in: account, preferences: preferences(enabled: true, percentLeft: 10)))
        XCTAssertNil(autoResetMarkerRatio(for: fable, in: account, preferences: preferences(enabled: true, percentLeft: 10)))
    }

    func testNoMarkerUntilTheSettingIsOnAndFilledIn() throws {
        let account = snapshot(weeklyLeft: 60)
        let weekly = try XCTUnwrap(account.secondaryWindow)
        XCTAssertNil(autoResetMarkerRatio(for: weekly, in: account, preferences: preferences(enabled: false, percentLeft: 10)))
        XCTAssertNil(autoResetMarkerRatio(for: weekly, in: account, preferences: preferences(enabled: true, percentLeft: nil)))

        let withoutResetTime = snapshot(weeklyLeft: 60, weeklyResetAt: nil)
        let weeklyWithoutResetTime = try XCTUnwrap(withoutResetTime.secondaryWindow)
        XCTAssertEqual(autoResetMarkerRatio(for: weeklyWithoutResetTime, in: withoutResetTime, preferences: preferences(enabled: true, percentLeft: 10)), 0.9)
        XCTAssertNil(autoResetMarkerRatio(for: weekly, in: account, preferences: preferences(enabled: true, percentLeft: -1)))
        XCTAssertNil(autoResetMarkerRatio(for: weekly, in: account, preferences: preferences(enabled: true, percentLeft: 100)))
        XCTAssertNil(autoResetMarkerRatio(for: weekly, in: account, preferences: preferences(enabled: true, percentLeft: 10, minimumHoursRemaining: 0)))
        XCTAssertNil(autoResetMarkerRatio(for: weekly, in: account, preferences: preferences(enabled: true, percentLeft: 10, minimumHoursRemaining: 169)))
    }

    func testNoMarkerForProvidersWithoutResets() throws {
        let account = snapshot(provider: .cursor, weeklyLeft: 60)
        let weekly = try XCTUnwrap(account.secondaryWindow)
        XCTAssertNil(autoResetMarkerRatio(for: weekly, in: account, preferences: preferences(enabled: true, percentLeft: 10)))
    }

    func testRedeemsOncePerWeeklyWindow() {
        let low = snapshot(weeklyLeft: 2)
        XCTAssertFalse(shouldAutoRedeemReset(low, weeklyPercentLeft: 10, minimumHoursRemaining: 1, lastRedeemedWindowEnd: weekEnd, now: now))
        XCTAssertFalse(shouldAutoRedeemReset(low, weeklyPercentLeft: 10, minimumHoursRemaining: 1, lastRedeemedWindowEnd: weekEnd.addingTimeInterval(-30), now: now))
        XCTAssertTrue(shouldAutoRedeemReset(low, weeklyPercentLeft: 10, minimumHoursRemaining: 1, lastRedeemedWindowEnd: weekEnd.addingTimeInterval(-7 * 86_400), now: now))
    }

    func testWeeklyResetMustBeStrictlyMoreThanConfiguredHoursAway() {
        XCTAssertFalse(shouldAutoRedeemReset(
            snapshot(weeklyLeft: 10, weeklyResetAt: now.addingTimeInterval(24 * 3_600)),
            weeklyPercentLeft: 10,
            minimumHoursRemaining: 24,
            lastRedeemedWindowEnd: nil,
            now: now
        ))
        XCTAssertTrue(shouldAutoRedeemReset(
            snapshot(weeklyLeft: 10, weeklyResetAt: now.addingTimeInterval(24 * 3_600 + 1)),
            weeklyPercentLeft: 10,
            minimumHoursRemaining: 24,
            lastRedeemedWindowEnd: nil,
            now: now
        ))
        XCTAssertFalse(shouldAutoRedeemReset(
            snapshot(weeklyLeft: 10, weeklyResetAt: now.addingTimeInterval(24 * 3_600 - 1)),
            weeklyPercentLeft: 10,
            minimumHoursRemaining: 24,
            lastRedeemedWindowEnd: nil,
            now: now
        ))
    }

    func testWeeklyResetRequiresAValidFutureResetTimeAndSettings() {
        XCTAssertFalse(shouldAutoRedeemReset(snapshot(weeklyLeft: 10, weeklyResetAt: nil), weeklyPercentLeft: 10, minimumHoursRemaining: 1, lastRedeemedWindowEnd: nil, now: now))
        XCTAssertFalse(shouldAutoRedeemReset(snapshot(weeklyLeft: 10, weeklyResetAt: now.addingTimeInterval(-1)), weeklyPercentLeft: 10, minimumHoursRemaining: 1, lastRedeemedWindowEnd: nil, now: now))
        XCTAssertFalse(shouldAutoRedeemReset(snapshot(weeklyLeft: 10), weeklyPercentLeft: 10, minimumHoursRemaining: 0, lastRedeemedWindowEnd: nil, now: now))
        XCTAssertFalse(shouldAutoRedeemReset(snapshot(weeklyLeft: 10), weeklyPercentLeft: 10, minimumHoursRemaining: 169, lastRedeemedWindowEnd: nil, now: now))
        XCTAssertFalse(shouldAutoRedeemReset(snapshot(weeklyLeft: 10), weeklyPercentLeft: 10, minimumHoursRemaining: Int.max, lastRedeemedWindowEnd: nil, now: now))
        XCTAssertFalse(shouldAutoRedeemReset(snapshot(weeklyLeft: 10), weeklyPercentLeft: -1, minimumHoursRemaining: 1, lastRedeemedWindowEnd: nil, now: now))
        XCTAssertFalse(shouldAutoRedeemReset(snapshot(weeklyLeft: 10), weeklyPercentLeft: 100, minimumHoursRemaining: 1, lastRedeemedWindowEnd: nil, now: now))
    }

    func testWeeklyWindowIsPickedFromAnyWindowList() {
        let session = RateLimitWindow(label: "5h", percentLeft: 90)
        let weekly = RateLimitWindow(label: "7d", percentLeft: 40, resetAt: weekEnd)
        XCTAssertEqual(weeklyQuotaWindow(among: [session, weekly]), weekly)
        XCTAssertEqual(weeklyQuotaWindow(among: [weekly, session]), weekly)
        XCTAssertNil(weeklyQuotaWindow(among: [session]))
        XCTAssertNil(weeklyQuotaWindow(among: []))
    }

    private func holds(_ condition: AutoRedeemCondition, weekly: RateLimitWindow? = nil, expiry: Date? = nil) -> Bool {
        autoRedeemConditionHolds(condition, weeklyWindow: weekly, soonestExpiry: expiry, now: now)
    }

    func testWeeklyConditionHoldsWhileLiveWeeklyIsAtOrBelowTheSetting() {
        XCTAssertTrue(holds(.weeklyAtOrBelow(10, minimumHoursRemaining: 1), weekly: RateLimitWindow(label: "7d", percentLeft: 10, resetAt: weekEnd)))
        XCTAssertTrue(holds(.weeklyAtOrBelow(10, minimumHoursRemaining: 1), weekly: RateLimitWindow(label: "7d", percentLeft: 3, resetAt: weekEnd)))
    }

    func testWeeklyConditionFailsOnceLiveWeeklyRecovers() {
        XCTAssertFalse(holds(.weeklyAtOrBelow(10, minimumHoursRemaining: 1), weekly: RateLimitWindow(label: "7d", percentLeft: 11, resetAt: weekEnd)))
    }

    func testWeeklyConditionFailsWithoutAWeeklyWindow() {
        XCTAssertFalse(holds(.weeklyAtOrBelow(10, minimumHoursRemaining: 1)))
    }

    func testWeeklyConditionRejectsMissingElapsedAndBoundaryResetTimes() {
        let condition = AutoRedeemCondition.weeklyAtOrBelow(10, minimumHoursRemaining: 1)
        XCTAssertFalse(holds(condition, weekly: RateLimitWindow(label: "7d", percentLeft: 4)))
        XCTAssertFalse(holds(condition, weekly: RateLimitWindow(label: "7d", percentLeft: 4, resetAt: now)))
        XCTAssertFalse(holds(condition, weekly: RateLimitWindow(label: "7d", percentLeft: 4, resetAt: now.addingTimeInterval(3_600))))
        XCTAssertTrue(holds(condition, weekly: RateLimitWindow(label: "7d", percentLeft: 4, resetAt: now.addingTimeInterval(3_601))))
    }

    func testWeeklyConditionRechecksWhenTimeAdvancesOrResetAtChanges() {
        let condition = AutoRedeemCondition.weeklyAtOrBelow(10, minimumHoursRemaining: 1)
        let liveWindow = RateLimitWindow(label: "7d", percentLeft: 4, resetAt: now.addingTimeInterval(7_200))
        XCTAssertTrue(autoRedeemConditionHolds(condition, weeklyWindow: liveWindow, soonestExpiry: nil, now: now))
        XCTAssertFalse(autoRedeemConditionHolds(condition, weeklyWindow: liveWindow, soonestExpiry: nil, now: now.addingTimeInterval(3_600)))

        let movedWindow = RateLimitWindow(label: "7d", percentLeft: 4, resetAt: now.addingTimeInterval(1_800))
        XCTAssertFalse(autoRedeemConditionHolds(condition, weeklyWindow: movedWindow, soonestExpiry: nil, now: now))
    }

    func testWeeklyConditionRejectsInvalidHoursAndPercentages() {
        let weekly = RateLimitWindow(label: "7d", percentLeft: 10, resetAt: weekEnd)
        XCTAssertFalse(holds(.weeklyAtOrBelow(10, minimumHoursRemaining: 0), weekly: weekly))
        XCTAssertFalse(holds(.weeklyAtOrBelow(10, minimumHoursRemaining: 169), weekly: weekly))
        XCTAssertFalse(holds(.weeklyAtOrBelow(10, minimumHoursRemaining: Int.max), weekly: weekly))
        XCTAssertFalse(holds(.weeklyAtOrBelow(-1, minimumHoursRemaining: 1), weekly: weekly))
        XCTAssertFalse(holds(.weeklyAtOrBelow(100, minimumHoursRemaining: 1), weekly: weekly))
    }

    func testWeeklyConditionSupportsPercentageBoundaries() {
        XCTAssertTrue(holds(.weeklyAtOrBelow(0, minimumHoursRemaining: 1), weekly: RateLimitWindow(label: "7d", percentLeft: 0, resetAt: weekEnd)))
        XCTAssertTrue(holds(.weeklyAtOrBelow(99, minimumHoursRemaining: 1), weekly: RateLimitWindow(label: "7d", percentLeft: 99, resetAt: weekEnd)))
    }

    func testExpiryConditionHoldsUntilTheDeadline() {
        let deadline = now.addingTimeInterval(5 * 60)
        XCTAssertTrue(holds(.expiringBy(deadline), expiry: now.addingTimeInterval(60)))
        XCTAssertTrue(holds(.expiringBy(deadline), expiry: deadline))
    }

    func testExpiryConditionFailsWhenTheLiveExpiryMovedPastTheDeadline() {
        let deadline = now.addingTimeInterval(5 * 60)
        XCTAssertFalse(holds(.expiringBy(deadline), expiry: deadline.addingTimeInterval(1)))
    }

    func testExpiryConditionFailsForAnExpiredReset() {
        let deadline = now.addingTimeInterval(5 * 60)
        XCTAssertFalse(holds(.expiringBy(deadline), expiry: now))
        XCTAssertFalse(holds(.expiringBy(deadline), expiry: now.addingTimeInterval(-60)))
    }

    func testExpiryConditionFailsWithoutALiveExpiry() {
        XCTAssertFalse(holds(.expiringBy(now.addingTimeInterval(5 * 60))))
    }

    private func claimPreferences(enabled: Bool = true, weekly: Int? = nil, hours: Int = 1, minutes: Int? = nil) -> AppPreferences {
        var preferences = AppPreferences()
        preferences.autoResetEnabled = enabled
        preferences.autoResetWeeklyPercentLeft = weekly
        preferences.autoResetWeeklyMinHoursRemaining = hours
        preferences.autoResetMinutesBeforeExpiry = minutes
        return preferences
    }

    private func claim(
        _ snapshot: AccountSnapshot,
        preferences: AppPreferences,
        lastRedeemedWindowEnd: Date? = nil,
        lastRedeemedExpiry: Date? = nil
    ) -> AutoRedeemClaim? {
        autoRedeemClaim(
            for: snapshot,
            preferences: preferences,
            lastRedeemedWindowEnd: lastRedeemedWindowEnd,
            lastRedeemedExpiry: lastRedeemedExpiry,
            now: now
        )
    }

    func testWeeklyClaimCarriesTheConditionTheGuardAndTheReason() throws {
        let result = try XCTUnwrap(claim(snapshot(weeklyLeft: 4), preferences: claimPreferences(weekly: 10)))
        XCTAssertEqual(result.trigger, .weekly)
        XCTAssertEqual(result.condition, .weeklyAtOrBelow(10, minimumHoursRemaining: 1))
        XCTAssertEqual(result.guardDate, weekEnd)
        XCTAssertEqual(result.detail, "Weekly quota was at 4% left, at or below your 10% setting, with more than 1h before the natural weekly reset.")
    }

    func testExpiryClaimCarriesTheDeadlineTheGuardAndTheReason() throws {
        let expiry = now.addingTimeInterval(4 * 60)
        let result = try XCTUnwrap(claim(snapshot(weeklyLeft: 80, expiry: expiry), preferences: claimPreferences(minutes: 5)))
        XCTAssertEqual(result.trigger, .expiry)
        XCTAssertEqual(result.condition, .expiringBy(now.addingTimeInterval(5 * 60)))
        XCTAssertEqual(result.guardDate, expiry)
        XCTAssertTrue(result.detail.hasPrefix("A banked reset was about to expire (in "))
        XCTAssertTrue(result.detail.hasSuffix("), within your 5-minute setting."))
    }

    func testNoClaimWhenAutoResetIsOff() {
        let preferences = claimPreferences(enabled: false, weekly: 10, minutes: 5)
        XCTAssertNil(claim(snapshot(weeklyLeft: 4, expiry: weekEnd.addingTimeInterval(60)), preferences: preferences))
    }

    func testNoClaimWhenNeitherTriggerMatches() {
        XCTAssertNil(claim(snapshot(weeklyLeft: 80, expiry: weekEnd.addingTimeInterval(3_600)), preferences: claimPreferences(weekly: 10, minutes: 5)))
        XCTAssertNil(claim(snapshot(weeklyLeft: 4), preferences: claimPreferences()))
    }

    func testInvalidWeeklyConfigDoesNotRunButExpiryRemainsIndependent() throws {
        let expiry = now.addingTimeInterval(60)
        XCTAssertNil(claim(snapshot(weeklyLeft: 4), preferences: claimPreferences(weekly: 10, hours: 0)))
        let result = try XCTUnwrap(claim(snapshot(weeklyLeft: 4, expiry: expiry), preferences: claimPreferences(weekly: 10, hours: 0, minutes: 5)))
        XCTAssertEqual(result.trigger, .expiry)
    }

    func testPercentageOnlyPreferencesUseTheDefault12HourWeeklyGuard() throws {
        let preferences = try JSONDecoder.toki.decode(
            AppPreferences.self,
            from: Data(#"{"autoResetEnabled":true,"autoResetWeeklyPercentLeft":10}"#.utf8)
        )
        XCTAssertEqual(preferences.autoResetWeeklyMinHoursRemaining, 12)

        let beyondGuard = try XCTUnwrap(claim(
            snapshot(weeklyLeft: 4, weeklyResetAt: now.addingTimeInterval(12 * 3_600 + 1)),
            preferences: preferences
        ))
        XCTAssertEqual(beyondGuard.trigger, .weekly)
        XCTAssertNil(claim(
            snapshot(weeklyLeft: 4, weeklyResetAt: now.addingTimeInterval(12 * 3_600)),
            preferences: preferences
        ))
    }

    func testNoClaimWhileTheTriggerIsGuarded() {
        let expiry = now.addingTimeInterval(60)
        let account = snapshot(weeklyLeft: 4, expiry: expiry)
        XCTAssertNil(claim(account, preferences: claimPreferences(weekly: 10), lastRedeemedWindowEnd: weekEnd))
        XCTAssertNil(claim(account, preferences: claimPreferences(minutes: 5), lastRedeemedExpiry: expiry))
    }

    func testAGuardedWeeklyTriggerDoesNotBlockTheExpiryTrigger() throws {
        let expiry = now.addingTimeInterval(60)
        let result = try XCTUnwrap(claim(
            snapshot(weeklyLeft: 4, expiry: expiry),
            preferences: claimPreferences(weekly: 10, minutes: 5),
            lastRedeemedWindowEnd: weekEnd
        ))
        XCTAssertEqual(result.trigger, .expiry)
    }

    func testWeeklyWinsWhenBothTriggersMatch() throws {
        let account = snapshot(weeklyLeft: 4, expiry: now.addingTimeInterval(60))
        let result = try XCTUnwrap(claim(account, preferences: claimPreferences(weekly: 10, minutes: 5)))
        XCTAssertEqual(result.trigger, .weekly)
    }

    func testExpiryWinsWhenWeeklyTimeGateBlocksForClaudeAndCodex() throws {
        for provider in [Provider.claudeCode, .codex] {
            for hoursUntilReset in [12 * 3_600, 12 * 3_600 - 1] {
                let result = try XCTUnwrap(claim(
                    snapshot(
                        provider: provider,
                        weeklyLeft: 4,
                        expiry: now.addingTimeInterval(60),
                        weeklyResetAt: now.addingTimeInterval(TimeInterval(hoursUntilReset))
                    ),
                    preferences: claimPreferences(weekly: 10, hours: 12, minutes: 5)
                ))
                XCTAssertEqual(result.trigger, .expiry)
            }
        }
    }

    func testAnExpiryReadBackAFractionOffStillCountsAsGuarded() {
        let expiry = now.addingTimeInterval(60.4)
        let account = snapshot(weeklyLeft: 80, expiry: expiry)
        XCTAssertFalse(expiring(account, within: 5, lastRedeemedExpiry: now.addingTimeInterval(60)))
        XCTAssertTrue(expiring(account, within: 5, lastRedeemedExpiry: now.addingTimeInterval(58)))
    }

    func testOutcomesThatSpendNothingAreRecognised() {
        for outcome in ["nothingToReset", "noCredit", "not_limited", "cooldown", "ineligible", "unavailable"] {
            XCTAssertTrue(resetOutcomeSpentNothing(outcome), outcome)
        }
        for outcome in ["reset", "already_used", "alreadyRedeemed", "somethingNew"] {
            XCTAssertFalse(resetOutcomeSpentNothing(outcome), outcome)
        }
    }

    private func guardUpdate(trigger: AutoRedeemClaim.Trigger, guardDate: Date, outcome: String, spent: Date?) -> AutoRedeemGuardUpdate {
        let claim = AutoRedeemClaim(
            trigger: trigger,
            condition: .expiringBy(guardDate),
            guardDate: guardDate,
            detail: ""
        )
        return autoRedeemGuardUpdate(for: claim, redeemed: RedeemedReset(outcome: outcome, creditExpiry: spent))
    }

    func testAnOutcomeThatSpentNothingReleasesTheGuard() {
        let expiry = now.addingTimeInterval(60)
        XCTAssertEqual(guardUpdate(trigger: .expiry, guardDate: expiry, outcome: "cooldown", spent: expiry), .release)
        XCTAssertEqual(guardUpdate(trigger: .weekly, guardDate: weekEnd, outcome: "nothingToReset", spent: nil), .release)
    }

    func testAnExpiryClaimMovesTheGuardToTheCreditThatWasSpent() {
        let expiry = now.addingTimeInterval(60)
        let spent = now.addingTimeInterval(3_600)
        XCTAssertEqual(guardUpdate(trigger: .expiry, guardDate: expiry, outcome: "reset", spent: spent), .move(to: spent))
        XCTAssertEqual(guardUpdate(trigger: .expiry, guardDate: expiry, outcome: "already_used", spent: spent), .move(to: spent))
    }

    func testTheGuardStaysWhenTheSameCreditWasSpent() {
        let expiry = now.addingTimeInterval(60)
        XCTAssertEqual(guardUpdate(trigger: .expiry, guardDate: expiry, outcome: "reset", spent: expiry.addingTimeInterval(0.4)), .keep)
        XCTAssertEqual(guardUpdate(trigger: .expiry, guardDate: expiry, outcome: "reset", spent: expiry.addingTimeInterval(1)), .move(to: expiry.addingTimeInterval(1)))
    }

    func testTheGuardStaysWhenTheSpentCreditIsUnknown() {
        XCTAssertEqual(guardUpdate(trigger: .expiry, guardDate: now.addingTimeInterval(60), outcome: "reset", spent: nil), .keep)
    }

    func testAWeeklyClaimKeepsItsGuardWhateverCreditWasSpent() {
        XCTAssertEqual(guardUpdate(trigger: .weekly, guardDate: weekEnd, outcome: "reset", spent: now.addingTimeInterval(3_600)), .keep)
    }
}
