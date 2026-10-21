import XCTest
@testable import Toki

final class AutoResetTests: XCTestCase {
    private let weekEnd = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        provider: Provider = .codex,
        weeklyLeft: Int,
        credits: Int = 1,
        expiry: Date? = nil,
        isError: Bool = false
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
            secondaryWindow: RateLimitWindow(label: "7d", percentLeft: weeklyLeft, resetAt: weekEnd)
        )
    }

    func testRedeemsWhenWeeklyLeftIsAtOrBelowTheSetting() {
        XCTAssertTrue(shouldAutoRedeemReset(snapshot(weeklyLeft: 10), weeklyPercentLeft: 10, lastRedeemedWindowEnd: nil))
        XCTAssertTrue(shouldAutoRedeemReset(snapshot(provider: .claudeCode, weeklyLeft: 4), weeklyPercentLeft: 10, lastRedeemedWindowEnd: nil))
    }

    func testWaitsWhileWeeklyLeftIsAboveTheSetting() {
        XCTAssertFalse(shouldAutoRedeemReset(snapshot(weeklyLeft: 11), weeklyPercentLeft: 10, lastRedeemedWindowEnd: nil))
    }

    func testOnlyTheWeeklyWindowCounts() {
        var low5h = snapshot(weeklyLeft: 80)
        low5h.primaryWindow?.percentLeft = 0
        XCTAssertFalse(shouldAutoRedeemReset(low5h, weeklyPercentLeft: 10, lastRedeemedWindowEnd: nil))
    }

    func testNeedsABankedReset() {
        XCTAssertFalse(shouldAutoRedeemReset(snapshot(weeklyLeft: 2, credits: 0), weeklyPercentLeft: 10, lastRedeemedWindowEnd: nil))
    }

    func testSkipsErroredAndUnsupportedProviders() {
        XCTAssertFalse(shouldAutoRedeemReset(snapshot(weeklyLeft: 2, isError: true), weeklyPercentLeft: 10, lastRedeemedWindowEnd: nil))
        XCTAssertFalse(shouldAutoRedeemReset(snapshot(provider: .cursor, weeklyLeft: 2), weeklyPercentLeft: 10, lastRedeemedWindowEnd: nil))
    }

    private func expiring(_ snapshot: AccountSnapshot, within minutes: Int, lastRedeemedExpiry: Date? = nil) -> Bool {
        shouldRedeemExpiringReset(snapshot, minutesBeforeExpiry: minutes, lastRedeemedExpiry: lastRedeemedExpiry, now: weekEnd)
    }

    func testRedeemsAResetAboutToExpire() {
        XCTAssertTrue(expiring(snapshot(weeklyLeft: 80, expiry: weekEnd.addingTimeInterval(4 * 60)), within: 5))
        XCTAssertTrue(expiring(snapshot(weeklyLeft: 80, expiry: weekEnd.addingTimeInterval(5 * 60)), within: 5))
    }

    func testLeavesAResetThatIsNotAboutToExpire() {
        XCTAssertFalse(expiring(snapshot(weeklyLeft: 80, expiry: weekEnd.addingTimeInterval(6 * 60)), within: 5))
        XCTAssertFalse(expiring(snapshot(weeklyLeft: 80, expiry: nil), within: 5))
    }

    func testIgnoresAResetThatHasAlreadyExpired() {
        XCTAssertFalse(expiring(snapshot(weeklyLeft: 80, expiry: weekEnd.addingTimeInterval(-1)), within: 5))
    }

    func testExpiryNeedsABankedResetOnASupportedProvider() {
        let soon = weekEnd.addingTimeInterval(60)
        XCTAssertFalse(expiring(snapshot(weeklyLeft: 80, credits: 0, expiry: soon), within: 5))
        XCTAssertFalse(expiring(snapshot(provider: .cursor, weeklyLeft: 80, expiry: soon), within: 5))
        XCTAssertFalse(expiring(snapshot(weeklyLeft: 80, expiry: soon, isError: true), within: 5))
    }

    func testRedeemsEachExpiringResetOnce() {
        let soon = weekEnd.addingTimeInterval(60)
        let account = snapshot(weeklyLeft: 80, expiry: soon)
        XCTAssertFalse(expiring(account, within: 5, lastRedeemedExpiry: soon))
        XCTAssertTrue(expiring(account, within: 5, lastRedeemedExpiry: soon.addingTimeInterval(-86_400)))
    }

    private func preferences(enabled: Bool, percentLeft: Int?) -> AppPreferences {
        var preferences = AppPreferences()
        preferences.autoResetEnabled = enabled
        preferences.autoResetWeeklyPercentLeft = percentLeft
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
    }

    func testNoMarkerForProvidersWithoutResets() throws {
        let account = snapshot(provider: .cursor, weeklyLeft: 60)
        let weekly = try XCTUnwrap(account.secondaryWindow)
        XCTAssertNil(autoResetMarkerRatio(for: weekly, in: account, preferences: preferences(enabled: true, percentLeft: 10)))
    }

    func testRedeemsOncePerWeeklyWindow() {
        let low = snapshot(weeklyLeft: 2)
        XCTAssertFalse(shouldAutoRedeemReset(low, weeklyPercentLeft: 10, lastRedeemedWindowEnd: weekEnd))
        XCTAssertFalse(shouldAutoRedeemReset(low, weeklyPercentLeft: 10, lastRedeemedWindowEnd: weekEnd.addingTimeInterval(-30)))
        XCTAssertTrue(shouldAutoRedeemReset(low, weeklyPercentLeft: 10, lastRedeemedWindowEnd: weekEnd.addingTimeInterval(-7 * 86_400)))
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
        autoRedeemConditionHolds(condition, weeklyWindow: weekly, soonestExpiry: expiry, now: weekEnd)
    }

    func testWeeklyConditionHoldsWhileLiveWeeklyIsAtOrBelowTheSetting() {
        XCTAssertTrue(holds(.weeklyAtOrBelow(10), weekly: RateLimitWindow(label: "7d", percentLeft: 10)))
        XCTAssertTrue(holds(.weeklyAtOrBelow(10), weekly: RateLimitWindow(label: "7d", percentLeft: 3)))
    }

    func testWeeklyConditionFailsOnceLiveWeeklyRecovers() {
        XCTAssertFalse(holds(.weeklyAtOrBelow(10), weekly: RateLimitWindow(label: "7d", percentLeft: 11)))
    }

    func testWeeklyConditionFailsWithoutAWeeklyWindow() {
        XCTAssertFalse(holds(.weeklyAtOrBelow(10)))
    }

    func testExpiryConditionHoldsUntilTheDeadline() {
        let deadline = weekEnd.addingTimeInterval(5 * 60)
        XCTAssertTrue(holds(.expiringBy(deadline), expiry: weekEnd.addingTimeInterval(60)))
        XCTAssertTrue(holds(.expiringBy(deadline), expiry: deadline))
    }

    func testExpiryConditionFailsWhenTheLiveExpiryMovedPastTheDeadline() {
        let deadline = weekEnd.addingTimeInterval(5 * 60)
        XCTAssertFalse(holds(.expiringBy(deadline), expiry: deadline.addingTimeInterval(1)))
    }

    func testExpiryConditionFailsForAnExpiredReset() {
        let deadline = weekEnd.addingTimeInterval(5 * 60)
        XCTAssertFalse(holds(.expiringBy(deadline), expiry: weekEnd))
        XCTAssertFalse(holds(.expiringBy(deadline), expiry: weekEnd.addingTimeInterval(-60)))
    }

    func testExpiryConditionFailsWithoutALiveExpiry() {
        XCTAssertFalse(holds(.expiringBy(weekEnd.addingTimeInterval(5 * 60))))
    }

    private func claimPreferences(enabled: Bool = true, weekly: Int? = nil, minutes: Int? = nil) -> AppPreferences {
        var preferences = AppPreferences()
        preferences.autoResetEnabled = enabled
        preferences.autoResetWeeklyPercentLeft = weekly
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
            now: weekEnd
        )
    }

    func testWeeklyClaimCarriesTheConditionTheGuardAndTheReason() throws {
        let result = try XCTUnwrap(claim(snapshot(weeklyLeft: 4), preferences: claimPreferences(weekly: 10)))
        XCTAssertEqual(result.trigger, .weekly)
        XCTAssertEqual(result.condition, .weeklyAtOrBelow(10))
        XCTAssertEqual(result.guardDate, weekEnd)
        XCTAssertEqual(result.detail, "Weekly quota was at 4% left, at or below your 10% setting.")
    }

    func testExpiryClaimCarriesTheDeadlineTheGuardAndTheReason() throws {
        let expiry = weekEnd.addingTimeInterval(4 * 60)
        let result = try XCTUnwrap(claim(snapshot(weeklyLeft: 80, expiry: expiry), preferences: claimPreferences(minutes: 5)))
        XCTAssertEqual(result.trigger, .expiry)
        XCTAssertEqual(result.condition, .expiringBy(weekEnd.addingTimeInterval(5 * 60)))
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

    func testNoClaimWhileTheTriggerIsGuarded() {
        let expiry = weekEnd.addingTimeInterval(60)
        let account = snapshot(weeklyLeft: 4, expiry: expiry)
        XCTAssertNil(claim(account, preferences: claimPreferences(weekly: 10), lastRedeemedWindowEnd: weekEnd))
        XCTAssertNil(claim(account, preferences: claimPreferences(minutes: 5), lastRedeemedExpiry: expiry))
    }

    func testAGuardedWeeklyTriggerDoesNotBlockTheExpiryTrigger() throws {
        let expiry = weekEnd.addingTimeInterval(60)
        let result = try XCTUnwrap(claim(
            snapshot(weeklyLeft: 4, expiry: expiry),
            preferences: claimPreferences(weekly: 10, minutes: 5),
            lastRedeemedWindowEnd: weekEnd
        ))
        XCTAssertEqual(result.trigger, .expiry)
    }

    func testWeeklyWinsWhenBothTriggersMatch() throws {
        let account = snapshot(weeklyLeft: 4, expiry: weekEnd.addingTimeInterval(60))
        let result = try XCTUnwrap(claim(account, preferences: claimPreferences(weekly: 10, minutes: 5)))
        XCTAssertEqual(result.trigger, .weekly)
    }

    func testAnExpiryReadBackAFractionOffStillCountsAsGuarded() {
        let expiry = weekEnd.addingTimeInterval(60.4)
        let account = snapshot(weeklyLeft: 80, expiry: expiry)
        XCTAssertFalse(expiring(account, within: 5, lastRedeemedExpiry: weekEnd.addingTimeInterval(60)))
        XCTAssertTrue(expiring(account, within: 5, lastRedeemedExpiry: weekEnd.addingTimeInterval(58)))
    }
}
