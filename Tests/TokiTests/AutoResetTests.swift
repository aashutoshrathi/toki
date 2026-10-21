import XCTest
@testable import Toki

final class AutoResetTests: XCTestCase {
    private let weekEnd = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        provider: Provider = .codex,
        weeklyLeft: Int,
        credits: Int = 1,
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
}
