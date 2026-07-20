import XCTest
@testable import Toki

final class UsageHeatmapTests: XCTestCase {
    private let now = Date()

    private func entry(daysAgo: Int, remaining: Double?, provider: Provider = .claudeCode) -> UsageHistoryEntry {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
        return UsageHistoryEntry(
            timestamp: date,
            accountID: "a",
            accountName: "A",
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

    func testIntensityIsShareOfQuotaConsumed() {
        // 30% remaining means 70% consumed.
        let result = days([entry(daysAgo: 0, remaining: 0.3)])
        XCTAssertEqual(try XCTUnwrap(result.last?.intensity), 0.7, accuracy: 0.0001)
    }

    // Several samples land per day; the day's figure is the deepest the quota got, not the
    // last sample - a quota that reset mid-day shouldn't erase how heavy the day was.
    func testDayUsesPeakConsumptionNotTheLatestSample() {
        let result = days([
            entry(daysAgo: 0, remaining: 0.9),
            entry(daysAgo: 0, remaining: 0.2),
            entry(daysAgo: 0, remaining: 0.95),
        ])
        XCTAssertEqual(try XCTUnwrap(result.last?.intensity), 0.8, accuracy: 0.0001)
    }

    func testDaysWithoutDataAreNilNotZero() {
        let result = days([entry(daysAgo: 0, remaining: 0.5)])
        XCTAssertNotNil(result.last?.intensity)
        XCTAssertNil(result.first?.intensity, "a day with no samples must be distinguishable from a 0%-used day")
    }

    func testProviderFilterExcludesOtherProviders() {
        let history = [
            entry(daysAgo: 0, remaining: 0.1, provider: .claudeCode),
            entry(daysAgo: 0, remaining: 0.8, provider: .codex),
        ]
        XCTAssertEqual(try XCTUnwrap(days(history, provider: .codex).last?.intensity), 0.2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(days(history, provider: .claudeCode).last?.intensity), 0.9, accuracy: 0.0001)
    }

    func testEntriesWithoutARatioAreIgnored() {
        XCTAssertNil(days([entry(daysAgo: 0, remaining: nil)]).last?.intensity)
    }

    func testIntensityIsClampedToUnitRange() {
        let result = days([entry(daysAgo: 0, remaining: -0.5)])
        XCTAssertEqual(try XCTUnwrap(result.last?.intensity), 1.0, accuracy: 0.0001)
    }

    func testEntriesOlderThanTheWindowAreExcluded() {
        let result = days([entry(daysAgo: 40, remaining: 0.1)], count: 30)
        XCTAssertTrue(result.allSatisfy { $0.intensity == nil })
    }

    func testTooltipDistinguishesNoUsageFromZeroUsage() {
        XCTAssertTrue(HeatmapDay(date: now, intensity: nil).tooltip.contains("no usage recorded"))
        XCTAssertTrue(HeatmapDay(date: now, intensity: 0).tooltip.contains("0%"))
    }
}
