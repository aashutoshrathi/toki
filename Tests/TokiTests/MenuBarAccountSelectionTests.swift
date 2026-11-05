import XCTest
@testable import Toki

// With more than one Codex home signed in, the menu bar shows one segment per provider, so
// something has to choose which account speaks for Codex. These cover the default (the account
// closest to running out) and the explicit override.
final class MenuBarAccountSelectionTests: XCTestCase {
    private func codex(_ id: String, left: Int, isError: Bool = false) -> AccountSnapshot {
        AccountSnapshot(
            id: id,
            name: id,
            provider: .codex,
            primary: "",
            subtitle: "",
            remainingRatio: Double(left) / 100,
            metrics: [],
            isError: isError,
            primaryWindow: RateLimitWindow(label: "5h", percentLeft: left, resetHint: nil)
        )
    }

    private func claude(_ id: String, left: Int) -> AccountSnapshot {
        AccountSnapshot(
            id: id,
            name: id,
            provider: .claudeCode,
            primary: "",
            subtitle: "",
            remainingRatio: Double(left) / 100,
            metrics: [],
            primaryWindow: RateLimitWindow(label: "5h", percentLeft: left, resetHint: nil)
        )
    }

    func testPinnedDefaultsToTheCodexAccountClosestToRunningOut() {
        let entries = menuBarEntries(
            for: [codex("work", left: 70), codex("personal", left: 20)],
            mode: .pinned,
            pinnedProviders: [.codex]
        )
        XCTAssertEqual(entries.map(\.value), ["20%"])
    }

    func testPinnedUsesTheChosenAccountEvenWhenAnotherHasLessLeft() {
        let entries = menuBarEntries(
            for: [codex("work", left: 70), codex("personal", left: 20)],
            mode: .pinned,
            pinnedProviders: [.codex],
            accounts: ["codex": "work"]
        )
        XCTAssertEqual(entries.map(\.value), ["70%"])
    }

    func testAStoredAccountThatNoLongerExistsFallsBackToTheLowest() {
        let entries = menuBarEntries(
            for: [codex("work", left: 70), codex("personal", left: 20)],
            mode: .pinned,
            pinnedProviders: [.codex],
            accounts: ["codex": "someone-removed-this-home"]
        )
        XCTAssertEqual(entries.map(\.value), ["20%"])
    }

    func testSmartAlsoPicksTheCodexAccountWithTheLeastLeft() {
        let entries = menuBarEntries(
            for: [codex("work", left: 70), codex("personal", left: 20)],
            mode: .smart
        )
        XCTAssertEqual(entries.map(\.provider), [.codex])
        XCTAssertEqual(entries.first?.value, "20%")
    }

    func testSmartHonoursTheChosenCodexAccount() {
        let entries = menuBarEntries(
            for: [codex("work", left: 70), codex("personal", left: 20)],
            mode: .smart,
            accounts: ["codex": "work"]
        )
        XCTAssertEqual(entries.first?.value, "70%")
    }

    // An errored account is never the representative, however little it claims to have left.
    func testAnErroredAccountNeverRepresentsTheProvider() {
        let entries = menuBarEntries(
            for: [codex("work", left: 70), codex("broken", left: 1, isError: true)],
            mode: .pinned,
            pinnedProviders: [.codex],
            accounts: ["codex": "broken"]
        )
        XCTAssertEqual(entries.map(\.value), ["70%"])
    }

    // A spent account must not make Codex look empty while its sibling still has quota.
    func testASpentAccountYieldsToOneWithQuota() {
        let entries = menuBarEntries(
            for: [codex("spent", left: 0), codex("fresh", left: 55)],
            mode: .pinned,
            pinnedProviders: [.codex]
        )
        XCTAssertEqual(entries.map(\.value), ["55%"])
    }

    // Smart keeps its Claude slot on the login in use, rather than hopping to a sibling that
    // happens to have less quota.
    func testSmartKeepsTheActiveClaudeAccount() {
        var active = claude("active", left: 80)
        active.switchTarget = nil
        var idle = claude("idle", left: 10)
        idle.switchTarget = "active"

        let entries = menuBarEntries(for: [idle, active], mode: .smart)
        XCTAssertEqual(entries.map(\.value), ["80%"])
    }

    func testPreferencesRoundTripTheChosenAccounts() throws {
        var preferences = AppPreferences()
        preferences.menuBarAccounts = ["codex": "work"]
        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)
        XCTAssertEqual(decoded.menuBarAccounts, ["codex": "work"])
    }

    // Older state files predate the key; a missing one must stay additive, not throw.
    func testAnOlderStateFileDecodesWithoutTheKey() throws {
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.menuBarAccounts.isEmpty)
    }
}
