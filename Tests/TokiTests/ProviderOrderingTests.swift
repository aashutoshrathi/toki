import XCTest
@testable import Toki

final class ProviderOrderingTests: XCTestCase {
    private func snapshot(
        _ id: String,
        provider: Provider,
        remaining: Double? = nil,
        isError: Bool = false,
        agentOnly: Bool = false
    ) -> AccountSnapshot {
        AccountSnapshot(
            id: id,
            name: id,
            provider: provider,
            primary: "",
            subtitle: "",
            remainingRatio: remaining,
            metrics: [],
            isError: isError,
            isAgentDetectionOnly: agentOnly
        )
    }

    private func order(_ snapshots: [AccountSnapshot], active: Set<Provider> = []) -> [String] {
        sortedByAvailability(snapshots, activeProviders: active).map(\.id)
    }

    func testRunningCostProviderOutranksIdleOneRegardlessOfDetectionOrder() {
        let snapshots = [
            snapshot("opencode", provider: .openCode),
            snapshot("pi", provider: .pi),
            snapshot("fx", provider: .fx),
            snapshot("sarvam", provider: .sarvamCode)
        ]

        XCTAssertEqual(order(snapshots), ["opencode", "pi", "fx", "sarvam"])
        XCTAssertEqual(order(snapshots, active: [.sarvamCode]), ["sarvam", "opencode", "pi", "fx"])
    }

    func testCostProvidersKeepDetectionOrderWhenSeveralAreRunning() {
        let snapshots = [
            snapshot("pi", provider: .pi),
            snapshot("sarvam", provider: .sarvamCode),
            snapshot("fx", provider: .fx)
        ]

        XCTAssertEqual(order(snapshots, active: [.pi, .sarvamCode]), ["pi", "sarvam", "fx"])
    }

    func testALiveSessionNeverOutranksQuotaHeadroom() {
        let snapshots = [
            snapshot("claude", provider: .claudeCode, remaining: 0.9),
            snapshot("codex", provider: .codex, remaining: 0.4),
            snapshot("sarvam", provider: .sarvamCode)
        ]

        XCTAssertEqual(order(snapshots, active: [.sarvamCode]), ["claude", "codex", "sarvam"])
    }

    func testAgentOnlyProvidersStillRankBelowRealUsageData() {
        let snapshots = [
            snapshot("grok", provider: .grok, agentOnly: true),
            snapshot("pi", provider: .pi)
        ]

        XCTAssertEqual(order(snapshots, active: [.grok]), ["pi", "grok"])
    }

    func testErroredProviderSinksBelowAHealthyOneEvenWhenRunning() {
        let snapshots = [
            snapshot("sarvam", provider: .sarvamCode, isError: true),
            snapshot("pi", provider: .pi)
        ]

        XCTAssertEqual(order(snapshots, active: [.sarvamCode]), ["pi", "sarvam"])
    }

    func testOpenPopoverRetainsOrderWhileReconcilingRefresh() {
        XCTAssertEqual(
            PopoverPresentationState.reconciledOrder(["codex", "claude", "removed"], presentIDs: ["claude", "new", "codex", "new"]),
            ["codex", "claude", "new"]
        )
    }

    func testPopoverRanksErrorsLastWithoutChangingRecommendationOrder() {
        let snapshots = [
            snapshot("error", provider: .pi, isError: true),
            snapshot("exhausted", provider: .codex, remaining: 0),
            snapshot("ready", provider: .claudeCode, remaining: 0.8)
        ]
        XCTAssertEqual(
            PopoverPresentationState.rankedAccountIDs(snapshots: snapshots, agents: []),
            ["ready", "exhausted", "error"]
        )
    }
}
