import XCTest
@testable import Toki

final class SpendAnalyticsRowTests: XCTestCase {
    private func money(_ pairs: [(Double, String)]) -> MoneyTotals {
        var totals = MoneyTotals()
        for (amount, currency) in pairs {
            totals.add(Money(amount: amount, currencyCode: currency), includingZero: true)
        }
        return totals
    }

    private func sarvam(
        costs: [(Double, String)],
        today: Int = 0,
        week: Int = 0,
        month: Int = 0,
        allTime: Int = 0
    ) -> SarvamCodeUsageClient.Totals {
        var totals = SarvamCodeUsageClient.Totals()
        totals.todayCosts = money(costs)
        totals.weekCosts = money(costs)
        totals.monthCosts = money(costs)
        totals.allTimeCosts = money(costs)
        totals.todayTokens = today
        totals.weekTokens = week
        totals.monthTokens = month
        totals.allTimeTokens = allTime
        return totals
    }

    private func rows(
        pi: PiUsageClient.Totals? = nil,
        openCode: OpenCodeUsageClient.Totals? = nil,
        fx: FxUsageClient.Totals? = nil,
        sarvam: SarvamCodeUsageClient.Totals? = nil
    ) -> [SpendAnalyticsPanel.LocalSpendRow] {
        SpendAnalyticsPanel.spendRows(pi: pi, openCode: openCode, fx: fx, sarvam: sarvam)
    }

    func testNonUSDProviderDoesNotGetAPhantomUSDRow() {
        let result = rows(sarvam: sarvam(costs: [(120, "INR")], today: 5_000, week: 9_000, month: 9_000, allTime: 9_000))

        XCTAssertEqual(result.map(\.currencyCode), ["INR"])
        XCTAssertEqual(result[0].allTime, 120, accuracy: 0.000_001)
        XCTAssertEqual(result[0].todayTokens, 5_000)
        XCTAssertEqual(result[0].allTimeTokens, 9_000)
    }

    func testUSDProvidersShareOneRowAndSumCostsAndTokens() {
        var pi = PiUsageClient.Totals()
        pi.todayCost = 1
        pi.allTimeCost = 4
        pi.todayTokens = 100
        pi.allTimeTokens = 400

        var openCode = OpenCodeUsageClient.Totals()
        openCode.todayCost = 2
        openCode.allTimeCost = 5
        openCode.todayTokens = 200
        openCode.allTimeTokens = 500

        var fx = FxUsageClient.Totals()
        fx.todayCost = 3
        fx.allTimeCost = 6
        fx.todayTokens = 300
        fx.allTimeTokens = 600

        let result = rows(pi: pi, openCode: openCode, fx: fx)

        XCTAssertEqual(result.map(\.currencyCode), ["USD"])
        XCTAssertEqual(result[0].today, 6, accuracy: 0.000_001)
        XCTAssertEqual(result[0].allTime, 15, accuracy: 0.000_001)
        XCTAssertEqual(result[0].todayTokens, 600)
        XCTAssertEqual(result[0].allTimeTokens, 1_500)
    }

    func testMixedCurrenciesKeepEachProvidersTokensOnItsOwnRow() {
        var pi = PiUsageClient.Totals()
        pi.todayCost = 2
        pi.allTimeCost = 2
        pi.todayTokens = 700
        pi.allTimeTokens = 700

        let result = rows(pi: pi, sarvam: sarvam(costs: [(50, "INR")], today: 300, allTime: 300))

        XCTAssertEqual(result.map(\.currencyCode), ["INR", "USD"])
        XCTAssertEqual(result[0].todayTokens, 300)
        XCTAssertEqual(result[0].allTimeTokens, 300)
        XCTAssertEqual(result[1].todayTokens, 700)
        XCTAssertEqual(result[1].allTimeTokens, 700)
    }

    func testProviderWithoutAnyCostStillShowsAUSDRow() {
        let result = rows(sarvam: sarvam(costs: [], today: 1_200, allTime: 1_200))

        XCTAssertEqual(result.map(\.currencyCode), ["USD"])
        XCTAssertEqual(result[0].allTime, 0, accuracy: 0.000_001)
        XCTAssertEqual(result[0].todayTokens, 1_200)
    }

    func testPeriodWithoutCostFallsBackToTheAllTimeCurrency() {
        var totals = sarvam(costs: [(75, "INR")], today: 400, allTime: 400)
        totals.todayCosts = MoneyTotals()

        let result = rows(sarvam: totals)

        XCTAssertEqual(result.map(\.currencyCode), ["INR"])
        XCTAssertEqual(result[0].todayTokens, 400)
    }

    func testNoProvidersProduceNoRows() {
        XCTAssertTrue(rows().isEmpty)
    }
}
