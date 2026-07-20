import XCTest
@testable import Toki

final class UsageHeatmapTests: XCTestCase {
    private let now = Date()

    private func entry(daysAgo: Int, remaining: Double?, provider: Provider = .claudeCode) -> UsageHistoryEntry {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
        // Distinct per provider: consumption is tracked per account, so sharing one id across
        // providers would interleave their readings into one bogus series.
        return UsageHistoryEntry(
            timestamp: date,
            accountID: "account-\(provider)",
            accountName: "Account \(provider)",
            provider: provider,
            remainingRatio: remaining,
            primary: ""
        )
    }

    private func days(_ history: [UsageHistoryEntry], provider: Provider? = nil, count: Int = 30) -> [HeatmapDay] {
        UsageHeatmap.days(from: history, provider: provider, dayCount: count, now: now)
    }

    func testProducesOneCellPerRequestedDayOldestFirst() {
        let result = days([], count: 30)
        XCTAssertEqual(result.count, 30)
        XCTAssertTrue(result[0].date < result[29].date)
    }

    func testIntensityIsQuotaConsumedDuringTheDay() {
        // 90% remaining down to 30% is 60% consumed.
        let result = days([
            entry(daysAgo: 0, remaining: 0.9),
            entry(daysAgo: 0, remaining: 0.3),
        ])
        XCTAssertEqual(try XCTUnwrap(result.last?.intensity), 0.6, accuracy: 0.0001)
    }

    // The core correctness property. An account sitting at 0% remaining is exhausted, not
    // busy - reading the standing figure would paint every idle day as fully saturated.
    func testExhaustedButIdleAccountDoesNotRegisterUsage() {
        let result = days([
            entry(daysAgo: 2, remaining: 0.0),
            entry(daysAgo: 1, remaining: 0.0),
            entry(daysAgo: 0, remaining: 0.0),
        ])
        XCTAssertTrue(result.allSatisfy { $0.intensity == nil }, "a flat quota means no consumption")
    }

    // A quota reset raises the remaining figure; that is not negative usage, and it must not
    // cancel out real consumption recorded earlier the same day.
    func testResetsAreIgnoredAndDropsAccumulate() {
        let result = days([
            entry(daysAgo: 0, remaining: 0.9),
            entry(daysAgo: 0, remaining: 0.6),  // 0.3 consumed
            entry(daysAgo: 0, remaining: 1.0),  // reset, ignored
            entry(daysAgo: 0, remaining: 0.8),  // 0.2 consumed
        ])
        XCTAssertEqual(try XCTUnwrap(result.last?.intensity), 0.5, accuracy: 0.0001)
    }

    func testConsumptionIsAttributedToTheDayItHappened() {
        let result = days([
            entry(daysAgo: 1, remaining: 0.9),
            entry(daysAgo: 0, remaining: 0.4),
        ])
        XCTAssertNil(result[result.count - 2].intensity, "the first reading alone establishes a baseline")
        XCTAssertEqual(try XCTUnwrap(result.last?.intensity), 0.5, accuracy: 0.0001)
    }

    func testDaysWithoutDataAreNilNotZero() {
        let result = days([entry(daysAgo: 0, remaining: 0.9), entry(daysAgo: 0, remaining: 0.5)])
        XCTAssertNotNil(result.last?.intensity)
        XCTAssertNil(result.first?.intensity, "a day with no samples must be distinguishable from a 0%-used day")
    }

    func testProviderFilterExcludesOtherProviders() {
        let history = [
            entry(daysAgo: 0, remaining: 1.0, provider: .claudeCode),
            entry(daysAgo: 0, remaining: 0.1, provider: .claudeCode),
            entry(daysAgo: 0, remaining: 1.0, provider: .codex),
            entry(daysAgo: 0, remaining: 0.8, provider: .codex),
        ]
        XCTAssertEqual(try XCTUnwrap(days(history, provider: .codex).last?.intensity), 0.2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(days(history, provider: .claudeCode).last?.intensity), 0.9, accuracy: 0.0001)
    }

    func testEntriesWithoutARatioAreIgnored() {
        XCTAssertNil(days([entry(daysAgo: 0, remaining: nil)]).last?.intensity)
    }

    func testIntensityIsClampedToUnitRange() {
        let result = days([entry(daysAgo: 0, remaining: 1.0), entry(daysAgo: 0, remaining: -0.5)])
        XCTAssertEqual(try XCTUnwrap(result.last?.intensity), 1.0, accuracy: 0.0001)
    }

    func testEntriesOlderThanTheWindowAreExcluded() {
        let result = days([entry(daysAgo: 41, remaining: 0.9), entry(daysAgo: 40, remaining: 0.1)], count: 30)
        XCTAssertTrue(result.allSatisfy { $0.intensity == nil })
    }

    func testTooltipDistinguishesNoUsageFromZeroUsage() {
        XCTAssertTrue(HeatmapDay(date: now, intensity: nil).tooltip.contains("no usage recorded"))
        XCTAssertTrue(HeatmapDay(date: now, intensity: 0).tooltip.contains("0%"))
    }
}
