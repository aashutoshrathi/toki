import XCTest
@testable import Toki

final class UsageHeatmapTests: XCTestCase {
    private let now = Date()

    private func activity(daysAgo: Int, tokens: Int, cost: Double = 0, provider: Provider = .claudeCode) -> DailyActivity {
        let day = Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
        )
        return DailyActivity(day: day, provider: provider, tokens: tokens, cost: cost)
    }

    private func days(_ activity: [DailyActivity], provider: Provider? = nil, count: Int = 30) -> [HeatmapDay] {
        UsageHeatmap.days(from: activity, provider: provider, dayCount: count, now: now)
    }

    func testProducesOneCellPerRequestedDayOldestFirst() {
        let result = days([], count: 30)
        XCTAssertEqual(result.count, 30)
        XCTAssertTrue(result[0].date < result[29].date)
    }

    func testQuietestActiveDayIsLowestStepAndBusiestIsHighest() {
        let result = days([
            activity(daysAgo: 3, tokens: 100),
            activity(daysAgo: 2, tokens: 5_000),
            activity(daysAgo: 1, tokens: 50_000),
            activity(daysAgo: 0, tokens: 900_000),
        ])
        let levels = result.compactMap(\.level)
        XCTAssertEqual(levels, [0, 1, 2, 3])
    }

    // The reason ranking exists: one outlier day used to crush every other day into the lowest
    // step, rendering the grid as a single bright cell in a field of near-empty ones.
    func testAnOutlierDayDoesNotFlattenTheRest() {
        let result = days([
            activity(daysAgo: 2, tokens: 1_000),
            activity(daysAgo: 1, tokens: 2_000),
            activity(daysAgo: 0, tokens: 100_000_000),
        ])
        let levels = result.compactMap(\.level)
        XCTAssertEqual(Set(levels).count, 3, "each distinct day gets its own step despite the outlier")
        XCTAssertEqual(levels.first, 0)
        XCTAssertEqual(levels.last, 3)
    }

    // A lone active day is by definition the busiest; the lowest step would read as "nothing
    // much happened".
    func testASingleActiveDayIsTheHighestStep() {
        XCTAssertEqual(days([activity(daysAgo: 0, tokens: 500)]).last?.level, 3)
    }

    func testEqualDaysShareAStep() {
        let result = days([activity(daysAgo: 1, tokens: 700), activity(daysAgo: 0, tokens: 700)])
        XCTAssertEqual(result.compactMap(\.level), [3, 3])
    }

    func testDaysWithoutActivityAreNil() {
        let result = days([activity(daysAgo: 0, tokens: 500)])
        XCTAssertNotNil(result.last?.level)
        XCTAssertNil(result.first?.level, "a day with no activity must be distinguishable from a quiet day")
    }

    func testRankLevelSpansTheFullRamp() {
        let distinct = [10, 20, 30, 40, 50]
        XCTAssertEqual(UsageHeatmap.rankLevel(tokens: 10, among: distinct), 0)
        XCTAssertEqual(UsageHeatmap.rankLevel(tokens: 50, among: distinct), 3)
    }

    func testProvidersAreSummedPerDay() {
        let result = days([
            activity(daysAgo: 0, tokens: 300, provider: .claudeCode),
            activity(daysAgo: 0, tokens: 700, provider: .openCode),
        ])
        XCTAssertEqual(result.last?.tokens, 1000)
        XCTAssertEqual(result.last?.accounts.count, 2)
    }

    // Cost-based providers were previously absent entirely: they have no quota percentage, so
    // the old quota-derived metric could not represent them.
    func testCostBasedProvidersAppear() {
        let result = days([
            activity(daysAgo: 0, tokens: 5_000, cost: 1.25, provider: .pi),
            activity(daysAgo: 0, tokens: 2_000, cost: 0.5, provider: .openCode),
        ])
        XCTAssertEqual(try XCTUnwrap(result.last?.cost), 1.75, accuracy: 0.0001)
        XCTAssertEqual(result.last?.accounts.first?.name, Provider.pi.displayName, "heaviest provider leads")
    }

    func testProviderFilterExcludesOtherProviders() {
        let history = [
            activity(daysAgo: 0, tokens: 900, provider: .claudeCode),
            activity(daysAgo: 0, tokens: 100, provider: .openCode),
        ]
        XCTAssertEqual(days(history, provider: .openCode).last?.tokens, 100)
        XCTAssertEqual(days(history, provider: .claudeCode).last?.tokens, 900)
    }

    func testActivityOlderThanTheWindowIsExcluded() {
        let result = days([activity(daysAgo: 40, tokens: 10_000)], count: 30)
        XCTAssertTrue(result.allSatisfy { $0.level == nil })
    }

    func testTooltipReportsAbsoluteFiguresNotTheRelativeShade() {
        let day = HeatmapDay(
            date: now,
            level: 2,
            accounts: [AccountUsage(name: "Claude Code", tokens: 1_500_000, cost: 2)],
            tokens: 1_500_000,
            cost: 2
        )
        XCTAssertTrue(day.tooltip.contains("1.5M"), "absolute tokens, not the relative percentage")
        XCTAssertFalse(day.tooltip.contains("50%"), "the colour already conveys the relative figure")
    }

    func testTooltipDistinguishesNoActivity() {
        XCTAssertTrue(HeatmapDay(date: now, level: nil).tooltip.contains("no activity"))
    }
}

final class DailyActivityScannerTests: XCTestCase {
    private let calendar = Calendar.current

    func testClaudeUsageIsBucketedByMessageTimestamp() {
        let jsonl = """
        {"type":"assistant","timestamp":"2026-07-19T10:00:00Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":50}}}
        {"type":"assistant","timestamp":"2026-07-19T18:00:00Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":200,"output_tokens":25}}}
        """
        var byDay: [Date: (tokens: Int, cost: Double)] = [:]
        DailyActivityScanner.accumulateClaude(
            data: Data(jsonl.utf8), since: .distantPast, calendar: calendar, into: &byDay
        )
        XCTAssertEqual(byDay.count, 1, "both messages fall on the same day")
        XCTAssertEqual(byDay.values.first?.tokens, 375)
    }

    // Cache tokens dominate real sessions; omitting them would understate activity heavily.
    func testCacheTokensCountTowardDailyTotals() {
        let jsonl = """
        {"type":"assistant","timestamp":"2026-07-19T10:00:00Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":10,"output_tokens":10,"cache_creation_input_tokens":500,"cache_read_input_tokens":1000}}}
        """
        var byDay: [Date: (tokens: Int, cost: Double)] = [:]
        DailyActivityScanner.accumulateClaude(
            data: Data(jsonl.utf8), since: .distantPast, calendar: calendar, into: &byDay
        )
        XCTAssertEqual(byDay.values.first?.tokens, 1520)
    }

    func testEntriesBeforeTheWindowAreSkipped() {
        let jsonl = """
        {"type":"assistant","timestamp":"2020-01-01T10:00:00Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":50}}}
        """
        var byDay: [Date: (tokens: Int, cost: Double)] = [:]
        DailyActivityScanner.accumulateClaude(
            data: Data(jsonl.utf8), since: Date(), calendar: calendar, into: &byDay
        )
        XCTAssertTrue(byDay.isEmpty)
    }

    func testNonAssistantLinesAreIgnored() {
        let jsonl = """
        {"type":"user","timestamp":"2026-07-19T10:00:00Z"}
        {"type":"summary","aiTitle":"x"}
        """
        var byDay: [Date: (tokens: Int, cost: Double)] = [:]
        DailyActivityScanner.accumulateClaude(
            data: Data(jsonl.utf8), since: .distantPast, calendar: calendar, into: &byDay
        )
        XCTAssertTrue(byDay.isEmpty)
    }
}
