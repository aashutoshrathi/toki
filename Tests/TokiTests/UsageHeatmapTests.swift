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

    // Shading is relative to the busiest day in the window: there is no fixed ceiling on daily
    // tokens, so an absolute scale would bottom out for a light user and saturate for a heavy one.
    func testBusiestDayIsFullIntensityAndOthersScaleAgainstIt() {
        let result = days([
            activity(daysAgo: 1, tokens: 1_000_000),
            activity(daysAgo: 0, tokens: 250_000),
        ])
        XCTAssertEqual(try XCTUnwrap(result[result.count - 2].intensity), 1.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.last?.intensity), 0.25, accuracy: 0.0001)
    }

    func testDaysWithoutActivityAreNil() {
        let result = days([activity(daysAgo: 0, tokens: 500)])
        XCTAssertNotNil(result.last?.intensity)
        XCTAssertNil(result.first?.intensity, "a day with no activity must be distinguishable from a quiet day")
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
        XCTAssertTrue(result.allSatisfy { $0.intensity == nil })
    }

    func testTooltipReportsAbsoluteFiguresNotTheRelativeShade() {
        let day = HeatmapDay(
            date: now,
            intensity: 0.5,
            accounts: [AccountUsage(name: "Claude Code", tokens: 1_500_000, cost: 2)],
            tokens: 1_500_000,
            cost: 2
        )
        XCTAssertTrue(day.tooltip.contains("1.5M"), "absolute tokens, not the relative percentage")
        XCTAssertFalse(day.tooltip.contains("50%"), "the colour already conveys the relative figure")
    }

    func testTooltipDistinguishesNoActivity() {
        XCTAssertTrue(HeatmapDay(date: now, intensity: nil).tooltip.contains("no activity"))
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
