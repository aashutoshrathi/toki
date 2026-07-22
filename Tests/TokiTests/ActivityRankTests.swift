import XCTest
@testable import Toki

/// The popover heatmap and the terminal one draw the same days at different resolutions. These
/// assert the properties that have to hold at any step count, so the two cannot disagree about
/// which day was busier.
final class ActivityRankTests: XCTestCase {
    func testBusiestDayGetsTopShadeAtEveryResolution() {
        let distinct = [100, 500, 2_000, 9_000]
        for steps in [4, 8, 64] {
            XCTAssertEqual(
                ActivityRank.level(9_000, among: distinct, steps: steps),
                steps - 1,
                "busiest day should reach the top shade with \(steps) steps"
            )
        }
    }

    func testQuietestDayGetsLowestShadeAtEveryResolution() {
        let distinct = [100, 500, 2_000, 9_000]
        for steps in [4, 8, 64] {
            XCTAssertEqual(ActivityRank.level(100, among: distinct, steps: steps), 0)
        }
    }

    /// A lone active day is the busiest day there is. Ranking it at the bottom would draw the
    /// only day you worked as though almost nothing happened.
    func testSingleActiveDayIsNotDrawnAsQuiet() {
        XCTAssertEqual(ActivityRank.level(42, among: [42], steps: 64), 63)
        XCTAssertEqual(ActivityRank.level(42, among: [42], steps: 4), 3)
    }

    func testUnknownValueDoesNotUnderstateTheDay() {
        // Defensive: a total absent from the distinct list means the caller built them
        // inconsistently. Failing toward "busy" is visible; failing toward "quiet" hides work.
        XCTAssertEqual(ActivityRank.level(777, among: [1, 2, 3], steps: 64), 63)
    }

    func testRankIsMonotonic() {
        let distinct = (1...40).map { $0 * 137 }
        let levels = distinct.map { ActivityRank.level($0, among: distinct, steps: 64) }
        XCTAssertEqual(levels, levels.sorted(), "a busier day must never get a lighter shade")
    }

    /// Rank-based, not proportional: one outlier day must not flatten everything else to zero.
    func testOneHugeDayDoesNotFlattenTheRest() {
        let distinct = [10, 20, 30, 5_000_000]
        let levels = distinct.map { ActivityRank.level($0, among: distinct, steps: 64) }
        XCTAssertEqual(Set(levels).count, 4, "each distinct total should keep its own shade")
        XCTAssertGreaterThan(levels[1], levels[0])
    }

    func testDegenerateStepCountsDoNotCrash() {
        XCTAssertEqual(ActivityRank.level(5, among: [1, 5], steps: 1), 0)
        XCTAssertEqual(ActivityRank.level(5, among: [1, 5], steps: 0), 0)
    }

    /// The app's entry point must stay a thin wrapper over the shared function; if it grows its
    /// own arithmetic again, the CLI and the popover start disagreeing silently.
    func testHeatmapDelegatesToSharedRanking() {
        let distinct = [5, 50, 500]
        for value in distinct {
            XCTAssertEqual(
                UsageHeatmap.rankLevel(tokens: value, among: distinct),
                ActivityRank.level(value, among: distinct, steps: UsageHeatmap.shadeCount)
            )
        }
    }
}
