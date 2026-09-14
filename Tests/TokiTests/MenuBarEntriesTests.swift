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
        XCTAssertNil(entry.windowLabel)
    }

    func testAutoUsesTheMostConstrainedMainWindow() {
        var account = snapshot(id: "claude", provider: .claudeCode, remainingRatio: 0.8)
        account.primaryWindow = RateLimitWindow(label: "5h", percentLeft: 80, resetHint: nil)
        account.secondaryWindow = RateLimitWindow(label: "7d", percentLeft: 30, resetHint: nil)
        account.modelWindows = [RateLimitWindow(label: "Sonnet", percentLeft: 10, resetHint: nil)]

        XCTAssertEqual(displayQuotaWindow(for: account)?.label, "7d")
        XCTAssertEqual(menuBarEntry(for: account).value, "30%")
        XCTAssertEqual(menuBarEntry(for: account).windowLabel, "7d")
        XCTAssertEqual(menuBarEntry(for: account, preferredWindow: "5h").value, "80%")
        XCTAssertEqual(menuBarEntry(for: account, preferredWindow: "5h").windowLabel, "5h")

        account.secondaryWindow?.percentLeft = 90
        XCTAssertEqual(displayQuotaWindow(for: account)?.label, "5h")
    }

    func testUnavailableWindowFallsBackToTheActualAvailableWindow() {
        var account = snapshot(id: "codex", provider: .codex, remainingRatio: 0.6)
        account.primaryWindow = RateLimitWindow(label: "7d", percentLeft: 60, resetHint: nil)
        let entry = menuBarEntry(for: account, preferredWindow: "5h")
        XCTAssertEqual(entry.value, "60%")
        XCTAssertEqual(entry.windowLabel, "7d")
        XCTAssertEqual(displayQuotaWindow(for: account, preferredWindow: "unknown")?.label, "7d")
    }

    func testProviderChoicesApplyIndependentlyInSmartAndPinnedModes() {
        var claude = snapshot(id: "claude", provider: .claudeCode, remainingRatio: 0.8)
        claude.primaryWindow = RateLimitWindow(label: "5h", percentLeft: 80, resetHint: nil)
        claude.secondaryWindow = RateLimitWindow(label: "7d", percentLeft: 30, resetHint: nil)
        var codex = snapshot(id: "codex", provider: .codex, remainingRatio: 0.6)
        codex.primaryWindow = RateLimitWindow(label: "5h", percentLeft: 60, resetHint: nil)
        codex.secondaryWindow = RateLimitWindow(label: "7d", percentLeft: 90, resetHint: nil)

        for mode in [MenuBarDisplayMode.smart, .pinned] {
            let entries = menuBarEntries(
                for: [claude, codex], mode: mode, pinnedProviders: [.claudeCode, .codex],
                quotaWindows: ["claudeCode": "5h", "codex": "7d"]
            )
            XCTAssertEqual(entries.map(\.value), ["80%", "90%"])
            XCTAssertEqual(entries.map(\.windowLabel), ["5h", "7d"])
        }

        let lowest = menuBarEntries(for: [claude, codex], mode: .lowest, quotaWindows: ["claudeCode": "5h"])
        XCTAssertEqual(lowest.first?.provider, .codex)
        XCTAssertEqual(lowest.first?.value, "60%")
    }

    func testSpendAndPlaceholderNeverInventAWindow() {
        let entry = menuBarEntry(for: snapshot(id: "pi", provider: .pi, menuBarValue: "$1.20"), preferredWindow: "5h")
        XCTAssertEqual(entry.value, "$1.20")
        XCTAssertNil(entry.windowLabel)
        XCTAssertTrue(menuBarPlaceholderEntries().allSatisfy { $0.windowLabel == nil })
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
