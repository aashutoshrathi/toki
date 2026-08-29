import XCTest
@testable import Toki

// The settings panel makes three claims at once: how many pins fit, which are reaching the
// menu bar, and which are pinned but dropped. All three have to agree with what
// `menuBarEntries` actually draws, which is what these cover.
final class MenuBarPinningTests: XCTestCase {
    private let connected: [Provider] = [.claudeCode, .codex, .cursor, .gemini]

    func testPinsAreKeptInTheOrderTheyWerePinned() {
        let state = menuBarPinState(pinned: [.cursor, .claudeCode], connected: connected, density: .comfortable)
        XCTAssertEqual(state.effective, [.cursor, .claudeCode])
        XCTAssertEqual(state.drawn, [.cursor, .claudeCode])
        XCTAssertTrue(state.overflow.isEmpty)
    }

    // A pin with no account behind it never reaches the bar, so letting it hold a slot would
    // block one that would have.
    func testAPinWithNoConnectedAccountDoesNotUseUpASlot() {
        let state = menuBarPinState(
            pinned: [.gemini, .claudeCode, .codex, .cursor],
            connected: [.claudeCode, .codex, .cursor],
            density: .comfortable
        )
        XCTAssertEqual(state.effective, [.claudeCode, .codex, .cursor])
        XCTAssertTrue(state.overflow.isEmpty, "the unconnected pin must not push a real one out")
        XCTAssertFalse(state.canPinMore)
    }

    func testTheCapFollowsTheDensity() {
        XCTAssertEqual(menuBarPinState(pinned: [], connected: [], density: .comfortable).cap, 3)
        XCTAssertEqual(menuBarPinState(pinned: [], connected: [], density: .compact).cap, 3)
        XCTAssertEqual(menuBarPinState(pinned: [], connected: [], density: .stacked).cap, 2)
    }

    func testMoreCanBePinnedUntilTheCapIsReached() {
        let pins: [Provider] = [.claudeCode, .codex]
        XCTAssertTrue(menuBarPinState(pinned: pins, connected: connected, density: .comfortable).canPinMore)
        XCTAssertFalse(menuBarPinState(pinned: pins, connected: connected, density: .stacked).canPinMore)
    }

    // The case the panel cannot block: switching density shrinks the cap under a selection
    // that was legal when it was made.
    func testShrinkingTheCapPushesTheTailIntoOverflow() {
        let pins: [Provider] = [.claudeCode, .codex, .cursor]
        let comfortable = menuBarPinState(pinned: pins, connected: connected, density: .comfortable)
        XCTAssertTrue(comfortable.overflow.isEmpty)

        let stacked = menuBarPinState(pinned: pins, connected: connected, density: .stacked)
        XCTAssertEqual(stacked.drawn, [.claudeCode, .codex])
        XCTAssertEqual(stacked.overflow, [.cursor])
    }

    // The panel's promise and the bar's behaviour are two separate code paths; this is the one
    // test that holds them to each other.
    func testWhatThePanelSaysIsDrawnIsWhatTheBarDraws() {
        let snapshots = connected.map {
            AccountSnapshot(id: $0.rawValue, name: $0.rawValue, provider: $0, primary: "", subtitle: "",
                            remainingRatio: 0.5, metrics: [], menuBarValue: nil)
        }
        let pins: [Provider] = [.claudeCode, .codex, .cursor, .gemini]

        for density in MenuBarDensity.allCases {
            let state = menuBarPinState(pinned: pins, connected: connected, density: density)
            let entries = menuBarEntries(for: snapshots, mode: .pinned, pinnedProviders: pins, density: density)
            XCTAssertEqual(state.drawn, entries.map(\.provider), "\(density.label) disagrees with the menu bar")
        }
    }
}

// Naming the pins a density is dropping, in a sentence rather than as a bare list.
final class ListedNamesTests: XCTestCase {
    func testNothingReadsAsNothing() {
        XCTAssertEqual(listedNames([]), "")
    }

    func testOneNameStandsAlone() {
        XCTAssertEqual(listedNames([.codex]), "Codex")
    }

    func testTwoNamesAreJoinedWithAnd() {
        XCTAssertEqual(listedNames([.claudeCode, .codex]), "Claude Code and Codex")
    }

    func testThreeOrMoreTakeCommasThenAnd() {
        XCTAssertEqual(listedNames([.claudeCode, .codex, .cursor]), "Claude Code, Codex and Cursor")
    }
}

final class MenuBarDisplayValueTests: XCTestCase {
    // Compact buys width by shrinking, so every character counts.
    func testCompactDropsThePercentSign() {
        XCTAssertEqual(menuBarDisplayValue("42%", density: .compact), "42")
    }

    // Stacked has already halved the readout by going vertical and can afford to keep it.
    func testComfortableAndStackedKeepThePercentSign() {
        XCTAssertEqual(menuBarDisplayValue("42%", density: .comfortable), "42%")
        XCTAssertEqual(menuBarDisplayValue("42%", density: .stacked), "42%")
    }

    // Cost providers have no percent sign, and trimming their last character would turn
    // "$12.30" into "$12.3".
    func testCostReadoutsAreLeftAloneAtEveryDensity() {
        for density in MenuBarDensity.allCases {
            XCTAssertEqual(menuBarDisplayValue("$12.30", density: density), "$12.30")
        }
    }

    func testThePlaceholderIsLeftAlone() {
        XCTAssertEqual(menuBarDisplayValue("--", density: .compact), "--")
    }

    func testTheLongestStackedValueSurvivesIntact() {
        XCTAssertEqual(menuBarDisplayValue("100%", density: .stacked), "100%")
    }
}
