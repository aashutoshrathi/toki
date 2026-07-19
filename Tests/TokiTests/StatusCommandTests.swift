import XCTest
@testable import Toki

final class StatusCommandTests: XCTestCase {
    private func entry(
        _ name: String,
        _ provider: Provider,
        remainingRatio: Double? = nil,
        isError: Bool = false
    ) -> StatusCacheEntry {
        StatusCacheEntry(
            id: name,
            name: name,
            provider: provider,
            primary: "",
            remainingRatio: remainingRatio,
            isError: isError
        )
    }

    private var sample: [StatusCacheEntry] {
        [
            entry("Work", .claudeCode, remainingRatio: 0.82),
            entry("Codex", .codex, remainingRatio: 0.005),
            entry("Pi", .pi)
        ]
    }

    func testFilterMatchesProviderRawValue() {
        let filtered = StatusCommand.filteredAccounts(sample, filter: "pi")
        XCTAssertEqual(filtered.map(\.name), ["Pi"])
    }

    func testFilterMatchesDisplayNameCaseInsensitively() {
        // "claude" is only in claudeCode's display name ("Claude Code"), not its rawValue.
        let filtered = StatusCommand.filteredAccounts(sample, filter: "CLAUDE")
        XCTAssertEqual(filtered.map(\.name), ["Work"])
    }

    func testFilterMatchesAccountName() {
        let filtered = StatusCommand.filteredAccounts(sample, filter: "work")
        XCTAssertEqual(filtered.map(\.name), ["Work"])
    }

    func testNilOrEmptyFilterReturnsEverything() {
        XCTAssertEqual(StatusCommand.filteredAccounts(sample, filter: nil).count, 3)
        XCTAssertEqual(StatusCommand.filteredAccounts(sample, filter: "").count, 3)
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertTrue(StatusCommand.filteredAccounts(sample, filter: "gemini").isEmpty)
    }

    func testExhaustionRequiresAllTrackedQuotaEmpty() {
        // Codex alone (0.5%) is exhausted.
        XCTAssertTrue(StatusCommand.allTrackedQuotaExhausted([entry("Codex", .codex, remainingRatio: 0.005)]))
        // Work (82%) is not.
        XCTAssertFalse(StatusCommand.allTrackedQuotaExhausted([entry("Work", .claudeCode, remainingRatio: 0.82)]))
        // Mixed: at least one has quota, so not all exhausted.
        XCTAssertFalse(StatusCommand.allTrackedQuotaExhausted(sample))
    }

    func testCostAndErrorOnlyAccountsAreNotCountedAsExhausted() {
        // Pi has no ratio and errored accounts are excluded, so with no tracked quota at all
        // the result is "not exhausted" rather than a false positive.
        XCTAssertFalse(StatusCommand.allTrackedQuotaExhausted([entry("Pi", .pi)]))
        XCTAssertFalse(StatusCommand.allTrackedQuotaExhausted([entry("Codex", .codex, remainingRatio: 0.0, isError: true)]))
    }
}
