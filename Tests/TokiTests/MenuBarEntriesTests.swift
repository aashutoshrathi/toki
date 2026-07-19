import XCTest
@testable import Toki

final class MenuBarEntriesTests: XCTestCase {
    private func snapshot(
        id: String,
        provider: Provider,
        remainingRatio: Double? = nil,
        menuBarValue: String? = nil
    ) -> AccountSnapshot {
        AccountSnapshot(
            id: id,
            name: id,
            provider: provider,
            primary: "",
            subtitle: "",
            remainingRatio: remainingRatio,
            metrics: [],
            menuBarValue: menuBarValue
        )
    }

    // A Pi-only user has no quota provider, so the menu bar used to collapse to the
    // "-- / --" placeholder. Pi's spend should now surface as its own segment instead.
    func testPiOnlySurfacesSpendInSmartMode() {
        let entries = menuBarEntries(
            for: [snapshot(id: "pi", provider: .pi, menuBarValue: "$1.20")],
            mode: .smart
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.provider, .pi)
        XCTAssertEqual(entries.first?.value, "$1.20")
    }

    func testCostSegmentTrailsQuotaSegments() {
        let entries = menuBarEntries(
            for: [
                snapshot(id: "claude", provider: .claudeCode, remainingRatio: 0.8),
                snapshot(id: "codex", provider: .codex, remainingRatio: 0.5),
                snapshot(id: "pi", provider: .pi, menuBarValue: "$0.40")
            ],
            mode: .smart
        )
        XCTAssertEqual(entries.map(\.provider), [.claudeCode, .codex, .pi])
        XCTAssertEqual(entries.last?.value, "$0.40")
    }

    // Percentage providers keep rendering their percentage; only nil-ratio cost providers
    // fall through to menuBarValue.
    func testQuotaProviderStillRendersPercentage() {
        let entry = menuBarEntry(for: snapshot(id: "codex", provider: .codex, remainingRatio: 0.42))
        XCTAssertEqual(entry.value, "42%")
    }
}
