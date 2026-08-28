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

    // Smart mode caps at two segments: two quota providers fill both slots, so a cost provider
    // is dropped rather than widening the status item to a size macOS might hide entirely.
    func testSmartModeCapsAtTwoSegmentsAndDropsCostWhenQuotaFillsBoth() {
        let entries = menuBarEntries(
            for: [
                snapshot(id: "claude", provider: .claudeCode, remainingRatio: 0.8),
                snapshot(id: "codex", provider: .codex, remainingRatio: 0.5),
                snapshot(id: "pi", provider: .pi, menuBarValue: "$0.40")
            ],
            mode: .smart
        )
        XCTAssertEqual(entries.map(\.provider), [.claudeCode, .codex])
    }

    // With only one quota provider, the cost provider fills the remaining slot.
    func testCostSegmentFillsRemainingSlot() {
        let entries = menuBarEntries(
            for: [
                snapshot(id: "claude", provider: .claudeCode, remainingRatio: 0.8),
                snapshot(id: "pi", provider: .pi, menuBarValue: "$0.40")
            ],
            mode: .smart
        )
        XCTAssertEqual(entries.map(\.provider), [.claudeCode, .pi])
        XCTAssertEqual(entries.last?.value, "$0.40")
    }

    // Percentage providers keep rendering their percentage; only nil-ratio cost providers
    // fall through to menuBarValue.
    func testQuotaProviderStillRendersPercentage() {
        let entry = menuBarEntry(for: snapshot(id: "codex", provider: .codex, remainingRatio: 0.42))
        XCTAssertEqual(entry.value, "42%")
    }

    func testLogoOnlyProducesNoEntries() {
        let entries = menuBarEntries(
            for: [snapshot(id: "claude", provider: .claudeCode, remainingRatio: 0.8)],
            mode: .logoOnly
        )
        XCTAssertTrue(entries.isEmpty)
    }

    // The break suggestion is itself a readout, so it must not reintroduce one in the mode
    // whose entire purpose is showing nothing.
    func testLogoOnlyStaysEmptyWhenEveryQuotaIsExhausted() {
        let entries = menuBarEntries(
            for: [
                snapshot(id: "claude", provider: .claudeCode, remainingRatio: 0),
                snapshot(id: "codex", provider: .codex, remainingRatio: 0)
            ],
            mode: .logoOnly
        )
        XCTAssertTrue(entries.isEmpty)
    }

    func testPinnedModeFollowsPinOrderNotSnapshotOrder() {
        let entries = menuBarEntries(
            for: [
                snapshot(id: "claude", provider: .claudeCode, remainingRatio: 0.8),
                snapshot(id: "cursor", provider: .cursor, remainingRatio: 0.3)
            ],
            mode: .pinned,
            pinnedProviders: [.cursor, .claudeCode]
        )
        XCTAssertEqual(entries.map(\.provider), [.cursor, .claudeCode])
    }

    func testPinnedModeSkipsProvidersWithNoConnectedAccount() {
        let entries = menuBarEntries(
            for: [snapshot(id: "codex", provider: .codex, remainingRatio: 0.5)],
            mode: .pinned,
            pinnedProviders: [.gemini, .codex]
        )
        XCTAssertEqual(entries.map(\.provider), [.codex])
    }

    private var fourProviders: [AccountSnapshot] {
        [
            snapshot(id: "claude", provider: .claudeCode, remainingRatio: 0.8),
            snapshot(id: "codex", provider: .codex, remainingRatio: 0.5),
            snapshot(id: "cursor", provider: .cursor, remainingRatio: 0.3),
            snapshot(id: "gemini", provider: .gemini, remainingRatio: 0.2)
        ]
    }

    func testPinnedModeCapsAtThreeSegmentsWhenComfortable() {
        let entries = menuBarEntries(
            for: fourProviders,
            mode: .pinned,
            pinnedProviders: [.claudeCode, .codex, .cursor, .gemini],
            density: .comfortable
        )
        XCTAssertEqual(entries.map(\.provider), [.claudeCode, .codex, .cursor])
    }

    func testCompactCarriesTheSameThreeSegments() {
        let entries = menuBarEntries(
            for: fourProviders,
            mode: .pinned,
            pinnedProviders: [.claudeCode, .codex, .cursor, .gemini],
            density: .compact
        )
        XCTAssertEqual(entries.count, 3)
    }

    // Two half-height rows have no room for a third, so the cap has to be lower here than it
    // is for the single-row densities.
    func testStackedCapsAtTwoSegments() {
        let entries = menuBarEntries(
            for: fourProviders,
            mode: .pinned,
            pinnedProviders: [.claudeCode, .codex, .cursor, .gemini],
            density: .stacked
        )
        XCTAssertEqual(entries.map(\.provider), [.claudeCode, .codex])
    }

    // The settings panel promises a count off this same property, so a drift here would make
    // it lie about what the bar draws.
    func testDensityCapsMatchWhatTheBarCanDraw() {
        XCTAssertEqual(MenuBarDensity.comfortable.maxSegments, 3)
        XCTAssertEqual(MenuBarDensity.compact.maxSegments, 3)
        XCTAssertEqual(MenuBarDensity.stacked.maxSegments, 2)
    }

    // Pinning nothing would otherwise leave a status item with no content at all, which reads
    // as a broken app rather than as a choice.
    func testPinnedModeWithNoPinsFallsBackToSmart() {
        let entries = menuBarEntries(
            for: [
                snapshot(id: "claude", provider: .claudeCode, remainingRatio: 0.8),
                snapshot(id: "codex", provider: .codex, remainingRatio: 0.5)
            ],
            mode: .pinned,
            pinnedProviders: []
        )
        XCTAssertEqual(entries.map(\.provider), [.claudeCode, .codex])
    }
}
